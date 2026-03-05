// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/*
    The Official token of OSEAN DAO - https://nautortoken.com - https://osean.online exclusively on Ethereum mainnet
    Nautor (NAU) — Ethereum mainnet Uniswap V2 fee token (auto-swap + auto-distribute)

    Behavior:
    - Charges buyTax (default 2%) on buys and sellTax (default 2%) on sells ONLY when interacting with the Uniswap V2 pair
      (wallet-to-wallet transfers are fee-free).
    - Fees are collected in NAU and held by the token contract.
    - On SELLS (to == uniswapPair), if the contract’s NAU fee balance >= swapTokensAtAmount:
        - swaps NAU -> ETH via Uniswap V2 Router using swapExactTokensForETHSupportingFeeOnTransferTokens
        - swap uses amountOutMin = 0 and is wrapped in try/catch so a swap failure will NOT block user sells
        - swap size is capped by maxSwapTokens (0 = no cap)

    ETH distribution:
    - ETH received from swaps can be auto-distributed after transfers when contract ETH balance exceeds autoDisperseThreshold
      (default 0.05 ether; set to 0 to disable auto-disperse and rely on manual disperse).
    - ETH is split between nautorWalletAddress and daoWalletAddress based on nautorFeePercent and daoFeePercent
      (parts-based split; 1/1 = 50/50, 2/1 = 66/33, etc.).
    - ETH sends use low-level .call and NEVER revert token transfers; failures emit FeeTransferFailed and ETH remains in contract.

    Safety / fixes:
    - Auto-disperse executes AFTER token balance changes (checks-effects-interactions) to reduce reentrancy risk.
    - lockTheSwap prevents recursive swapback calls during router operations.
    - lockDisperse prevents recursive/looping fee distributions during ETH sends.
    - Max tax cap: buyTax and sellTax are individually capped at 5% via setTaxes().

    Owner controls:
    - Can set buy/sell taxes (0–5% each).
    - Can set fee split parts (nautorFeePercent / daoFeePercent).
    - Can set swapTokensAtAmount and maxSwapTokens.
    - Can set autoDisperseThreshold (including disabling it with 0).
    - Can update fee wallets and manage fee exclusions.

    Notes:
    - This contract does not implement a pendingWithdrawals pull-pattern for failed ETH sends (ETH remains in the contract
      if a recipient cannot receive ETH). Manual disperse and/or wallet rotation can be used operationally.
    - No “pause trading” / “disable transfers” functionality is included; transfers remain possible at all times.
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@thirdweb-dev/contracts/extension/PermissionsEnumerable.sol";

// --- Interface ---

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract Nautor is ERC20, Ownable, PermissionsEnumerable {
    // --- Roles (if needed for future extensions) ---
    bytes32 public constant DAO_ROLE = keccak256("DAO_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // Example role-based access control modifiers
    modifier onlyDao() {
        require(hasRole(DAO_ROLE, msg.sender), "NOT_DAO");
        _;
    }

    modifier onlyDaoOrManager() {
        require(
            hasRole(DAO_ROLE, msg.sender) || hasRole(MANAGER_ROLE, msg.sender),
            "NOT_AUTHORIZED"
        );
        _;
    }

    // --- Fee exclusion ---
    mapping(address => bool) public excludedFromFees;

    // stored current manager for easy revoke/replace
    address public manager;

    // --- Fee wallets ---
    address payable public nautorWalletAddress;
    address payable public daoWalletAddress;

    // --- Router / Pair ---
    address public uniswapRouterAddress;
    IUniswapV2Router02 private uniswapRouter;
    address public uniswapPair;

    /// @dev cached WETH (gas optimization)
    address public immutable WETH;

    // --- Timestamps ---
    uint256 public initialTimeStamp;

    // --- Taxes (percent out of 100) ---
    uint256 public buyTax = 2;
    uint256 public sellTax = 2;

    // --- Fee split (parts) ---
    // Example: nautorFeePercent=1, daoFeePercent=1 => 50/50
    uint256 public nautorFeePercent = 1;
    uint256 public daoFeePercent = 1;

    // --- Swap settings ---
    // Threshold (in NAU) before swapping on sells
    uint256 public swapTokensAtAmount;

    // Threshold (in ETH) before auto-dispersing to wallets; set to 0 to disable auto-disperse and rely on manual disperse
    uint256 public autoDisperseThreshold = 0.05 ether;

    // Optional cap to reduce price impact (0 = no cap)
    uint256 public maxSwapTokens;

    bool private inSwap = false;
    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    bool private inDisperse;
    modifier lockDisperse() {
        inDisperse = true;
        _;
        inDisperse = false;
    }

    // --- Events ---
    event ExcludedFromFees(address indexed user, bool excluded);

    event SwapThresholdSet(uint256 amount);
    event MaxSwapTokensSet(uint256 amount);

    event TaxesSet(uint256 buyTax, uint256 sellTax);
    event FeePercentsSet(uint256 nautorFeePercent, uint256 daoFeePercent);

    event FeeWalletsUpdated(
        address indexed oldNautor,
        address indexed newNautor,
        address indexed oldDao,
        address newDao
    );

    event FeesDispersed(uint256 ethTotal, uint256 toNautor, uint256 toDao);

    event SwapBackAttempt(
        uint256 swapAmount,
        uint256 amountOutMin,
        uint256 tokenBalanceBefore,
        uint256 ethBalanceBefore
    );

    event SwapBackFailed(
        uint256 swapAmount,
        uint256 amountOutMin,
        string decodedReason,
        bytes rawReason
    );

    event SwapBackSuccess(uint256 swapAmount, uint256 ethGained);

    event FeeTransferFailed(address indexed wallet, uint256 amount);
    event FeeTransferSuccess(address indexed wallet, uint256 amount);

    event ManagerUpdated(address indexed oldManager, address indexed newManager);

    /**
     * @param initialSupply Total supply (raw units, 18 decimals)
     * @param _nautorWalletAddress Fee wallet 1
     * @param _daoWalletAddress Fee wallet 2
     * @param _uniswapRouterAddress UniswapV2/PancakeV2 router
     * @param _swapTokensAtAmount Threshold tokens before swap on sells (0 => default = supply/10000)
     * @param _maxSwapTokens Max tokens to swap in one go (0 => no cap)
     */
    constructor(
        uint256 initialSupply,
        address payable _nautorWalletAddress,
        address payable _daoWalletAddress,
        address _uniswapRouterAddress,
        uint256 _swapTokensAtAmount,
        uint256 _maxSwapTokens,
        address _daoRoleHolder,
        address _managerRoleHolder
    ) ERC20("Nautor", "NAU") {
        require(_nautorWalletAddress != address(0), "NAUTOR_WALLET_ZERO");
        require(_daoWalletAddress != address(0), "DAO_WALLET_ZERO");
        require(_uniswapRouterAddress != address(0), "ROUTER_ZERO");
        require(initialSupply > 0, "SUPPLY_ZERO");
        require(_daoRoleHolder != address(0), "DAO_ROLE_ZERO");
        require(_managerRoleHolder != address(0), "MANAGER_ROLE_ZERO");

        initialTimeStamp = block.timestamp;

        nautorWalletAddress = _nautorWalletAddress;
        daoWalletAddress = _daoWalletAddress;

        uniswapRouterAddress = _uniswapRouterAddress;
        IUniswapV2Router02 router = IUniswapV2Router02(_uniswapRouterAddress);
        uniswapRouter = router;

        // Cache WETH once
        address weth = router.WETH();
        WETH = weth;

        // Create or fetch pair with WETH
        address factory = router.factory();
        address pair = IUniswapV2Factory(factory).getPair(address(this), weth);
        if (pair == address(0)) {
            pair = IUniswapV2Factory(factory).createPair(address(this), weth);
        }
        uniswapPair = pair;

        // --- Roles ---
        // DAO controls itself + manager going forward
        _setRoleAdmin(DAO_ROLE, DAO_ROLE);
        _setRoleAdmin(MANAGER_ROLE, DAO_ROLE);

        // set initial DAO + manager at launch
        _setupRole(DAO_ROLE, _daoRoleHolder);
        _setupRole(MANAGER_ROLE, _managerRoleHolder);
        manager = _managerRoleHolder;

        // Exclude key addresses from fees
        _setExcludedFromFees(_nautorWalletAddress, true);
        _setExcludedFromFees(_daoWalletAddress, true);
        _setExcludedFromFees(address(this), true);
        _setExcludedFromFees(msg.sender, true);
        _setExcludedFromFees(_daoRoleHolder, true);
        _setExcludedFromFees(_managerRoleHolder, true);

        // Mint supply to nautor wallet
        _mint(_nautorWalletAddress, initialSupply);

        // Swap settings (NOW ACTUALLY USED)
        swapTokensAtAmount = _swapTokensAtAmount > 0 ? _swapTokensAtAmount : (initialSupply / 10_000);
        maxSwapTokens = _maxSwapTokens; // 0 allowed

        emit SwapThresholdSet(swapTokensAtAmount);
        emit MaxSwapTokensSet(maxSwapTokens);
    }

    // --- Role management with DAO revoke protection ---
    function renounceRole(bytes32 role, address account) public override(Permissions, IPermissions) {
        if (role == DAO_ROLE && hasRole(DAO_ROLE, account)) {
            require(_daoMemberCount() >= 2, "DAO_LAST_RENOUNCE");
        }

        super.renounceRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override(Permissions, IPermissions) {
        if (role == DAO_ROLE && hasRole(DAO_ROLE, account)) {
            // Disallow revoking if it would leave 0 DAO members.
            // Require at least 2 DAO_ROLE members before any revoke.
            require(_daoMemberCount() >= 2, "DAO_MIN_1");
        }

        super.revokeRole(role, account);
    }

    function rotateDao(address newDao, address oldDao) external onlyDao {
        require(newDao != address(0), "DAO_ZERO");

        // 1) add new DAO first (if not already)
        if (!hasRole(DAO_ROLE, newDao)) {
            grantRole(DAO_ROLE, newDao);
        }
        
        _setExcludedFromFees(newDao, true);

        // 2) now revoke old DAO (guarded by revokeRole override)
        if (oldDao != address(0) && hasRole(DAO_ROLE, oldDao)) {
            revokeRole(DAO_ROLE, oldDao);
        }
    }

    // --- DAO-only manager rotation ---
    function setManager(address newManager) external onlyDao {
        require(newManager != address(0), "MANAGER_ZERO");

        address old = manager;

        if (old != address(0) && hasRole(MANAGER_ROLE, old)) {
            revokeRole(MANAGER_ROLE, old);
            _setExcludedFromFees(old, false);
        }

        manager = newManager;
        grantRole(MANAGER_ROLE, newManager);

        _setExcludedFromFees(newManager, true);

        emit ManagerUpdated(old, newManager);
    }

    // --- Manager can resign (self only) ---
    function resignManager() external {
        require(hasRole(MANAGER_ROLE, msg.sender), "NOT_MANAGER");
        renounceRole(MANAGER_ROLE, msg.sender);
        if (manager == msg.sender) {
            manager = address(0);
            emit ManagerUpdated(msg.sender, address(0));           
        }

        _setExcludedFromFees(msg.sender, false);
    }

    // --- Owner, DAO, and Manager config setters ---

    /// @dev set buy/sell taxes independently
    function setTaxes(uint256 _buyTax, uint256 _sellTax) external onlyDaoOrManager {
        require(_buyTax <= 5 && _sellTax <= 5, "TAX_TOO_HIGH"); // cannot set tax higher than 5% (hard cap)
        buyTax = _buyTax;
        sellTax = _sellTax;
        emit TaxesSet(_buyTax, _sellTax);
    }

    /// @dev set threshold for auto-dispersing accumulated ETH to fee wallets; set to 0 to disable auto-disperse and rely on manual disperse
    function setAutoDisperseThreshold(uint256 amount) external onlyDaoOrManager {
        autoDisperseThreshold = amount;
    }

    /// @dev set fee split parts; 1/1 => 50/50, 2/1 => 66/33 etc.
    function setFeePercents(uint256 _nautorFeePercent, uint256 _daoFeePercent) external onlyDaoOrManager {
        require(_nautorFeePercent + _daoFeePercent > 0, "SPLIT_ZERO");
        nautorFeePercent = _nautorFeePercent;
        daoFeePercent = _daoFeePercent;
        emit FeePercentsSet(_nautorFeePercent, _daoFeePercent);
    }

    function setSwapTokensAtAmount(uint256 amount) external onlyDaoOrManager {
        require(amount > 0, "THRESHOLD_ZERO");
        swapTokensAtAmount = amount;
        emit SwapThresholdSet(amount);
    }

    function setMaxSwapTokens(uint256 amount) external onlyDaoOrManager {
        // 0 allowed (no cap)
        maxSwapTokens = amount;
        emit MaxSwapTokensSet(amount);
    }

    function setFeeWallets(address payable newNautor, address payable newDao) external onlyDaoOrManager {
        require(newNautor != address(0) && newDao != address(0), "WALLET_ZERO");

        address oldN = nautorWalletAddress;
        address oldD = daoWalletAddress;

        nautorWalletAddress = newNautor;
        daoWalletAddress = newDao;

        // keep them excluded by default (optional but practical)
        _setExcludedFromFees(newNautor, true);
        _setExcludedFromFees(newDao, true);

        emit FeeWalletsUpdated(oldN, newNautor, oldD, newDao);
    }

    // --- Fee exclusion management ---

    function excludeUserFromFees(address user) external onlyDaoOrManager {
        _setExcludedFromFees(user, true);
    }

    function includeUsersInFees(address user) external onlyDaoOrManager {
        _setExcludedFromFees(user, false);
    }

    function _setExcludedFromFees(address user, bool excluded) internal {
        excludedFromFees[user] = excluded;
        emit ExcludedFromFees(user, excluded);
    }

    // --- Utility / testing helpers ---
    function daoMemberCount() public view returns (uint256) {
        return _daoMemberCount();
    }

    function _daoMemberCount() internal view returns (uint256) {
        return IPermissionsEnumerable(address(this)).getRoleMemberCount(DAO_ROLE);
    }

    function getContractAddress() external view returns (address) {
        return address(this);
    }

    function getCurrentTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function burn(uint256 amount) external onlyDaoOrManager {
        _burn(msg.sender, amount);
    }

    // --- Core transfer hook with tax logic ---

    function _transfer(address from, address to, uint256 amount) internal override {
        require(amount > 0, "AMOUNT_ZERO");

        uint256 taxRate = 0;

        // no fees if either side excluded
        if (!(excludedFromFees[from] || excludedFromFees[to])) {
            // BUY (pair -> user)
            if (from == uniswapPair) {
                taxRate = buyTax;
            }
            // SELL (user -> pair)
            else if (to == uniswapPair) {
                taxRate = sellTax;

                // Swap back on sell if threshold met
                if (!inSwap) {
                    uint256 contractTokenBalance = balanceOf(address(this));
                    if (contractTokenBalance >= swapTokensAtAmount && swapTokensAtAmount > 0) {
                        uint256 swapAmount = contractTokenBalance;

                        // cap swap size
                        if (maxSwapTokens > 0 && swapAmount > maxSwapTokens) {
                            swapAmount = maxSwapTokens;
                        }

                        // never let swap revert the user's sell
                        _swapTax(swapAmount);
                    }
                }
            }
        }

        // Apply tax (if any)
        if (taxRate > 0) {
            uint256 feeAmount = (amount * taxRate) / 100;
            if (feeAmount > 0) {
                super._transfer(from, address(this), feeAmount);
                amount -= feeAmount;
            }
        }

        super._transfer(from, to, amount);

        // After transfer logic: optional auto-disperse accumulated ETH to fee wallets if threshold met; this allows fees to be sent to wallets faster without waiting for manual disperse, while still avoiding too frequent dispersals with a reasonable threshold
        // Optional auto-disperse ETH if it accumulates
        uint256 contractETHBalance = address(this).balance;
        if (autoDisperseThreshold > 0 &&
            contractETHBalance > autoDisperseThreshold &&
            !inSwap &&
            !inDisperse
        ) {
            _sendFeesToWallets(contractETHBalance);
        }
    }

    // --- Swap: tokens -> ETH with try/catch so sells won't revert) ---

    function _swapTax(uint256 amount) private lockTheSwap {
        if (amount == 0) return;

        uint256 tokenBalanceBefore = balanceOf(address(this));
        uint256 ethBalanceBefore = address(this).balance;

        emit SwapBackAttempt(amount, 0, tokenBalanceBefore, ethBalanceBefore);

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WETH;

        _approve(address(this), address(uniswapRouter), amount);

        // try to swap and catch errors to prevent sell reverts; if it fails, fees will remain in contract and can be swapped later manually
        try uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp
        ) {
            uint256 ethAfter = address(this).balance;
            uint256 ethGained = ethAfter > ethBalanceBefore ? (ethAfter - ethBalanceBefore) : 0;
            emit SwapBackSuccess(amount, ethGained);
        } catch Error(string memory reason) {
            emit SwapBackFailed(amount, 0, reason, bytes(reason));
        } catch (bytes memory raw) {
            emit SwapBackFailed(amount, 0, "SWAP_FAILED", raw);
        }
    }

    // --- Disperse ETH to wallets ---

    function _sendFeesToWallets(uint256 amount) private lockDisperse {
        if (amount == 0) return;

        // Split denominator MUST be the split parts
        uint256 tf = nautorFeePercent + daoFeePercent;
        if (tf == 0) return;

        uint256 toNautor = (amount * nautorFeePercent) / tf;
        uint256 toDao = amount - toNautor;

        // Send to Nautor wallet
        if (toNautor > 0) {
            (bool ok1, ) = nautorWalletAddress.call{value: toNautor}("");
            if (!ok1) emit FeeTransferFailed(nautorWalletAddress, toNautor);
            else emit FeeTransferSuccess(nautorWalletAddress, toNautor);
        }

        // Send to DAO wallet
        if (toDao > 0) {
            (bool ok2, ) = daoWalletAddress.call{value: toDao}("");
            if (!ok2) emit FeeTransferFailed(daoWalletAddress, toDao);
            else emit FeeTransferSuccess(daoWalletAddress, toDao);
        }

        emit FeesDispersed(amount, toNautor, toDao);
    }

    // --- Manual swap to tax tokens ---

    function swapFeesManually() external onlyDaoOrManager {
        uint256 contractTokenBalance = balanceOf(address(this));
        if (contractTokenBalance > 0) {
            uint256 swapAmount = contractTokenBalance;
            if (maxSwapTokens > 0 && swapAmount > maxSwapTokens) {
                swapAmount = maxSwapTokens;
            }
            _swapTax(swapAmount);
        }
    }

    function disperseFeesManually() external onlyDaoOrManager {
        uint256 contractETHBalance = address(this).balance;
        _sendFeesToWallets(contractETHBalance);
    }

    receive() external payable {}
}