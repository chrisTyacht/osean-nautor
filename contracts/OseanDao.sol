// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.11;

/**
 * @title OSEAN DAO Governance Contract
 * @author OSEAN DAO LLC - OSEAN, OSEAN DAO and NAUTOR are trademarks or brand assets of OSEAN DAO LLC.
 *
 * @notice
 * Official on-chain governance contract for the OSEAN DAO.
 * THIS IS THE OFFICIAL OSEAN DAO GOVERNANCE CONTRACT - https://osean.online & https://oseandao.com
 *
 * @dev
 * Copyright (c) 2025 OSEAN DAO LLC.
 *
 * This contract is based on OpenZeppelin Governor. Voting power is derived from an external
 * IVotes-compatible governance token, which in the OSEAN ecosystem is the
 * KYC-restricted governance NFT.
 *
 * Main features:
 * - Proposal creation and voting
 * - Quorum-based execution
 * - Governor settings (delay, period, threshold)
 * - Treasury actions controlled only through governance
 *
 * Treasury functions currently include token/ETH swap operations through
 * a Uniswap V2-compatible router. These functions are restricted to
 * governance execution only.
 */

// Base
import "@thirdweb-dev/contracts/infra/interface/IThirdwebContract.sol";

// Governance
import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";

// Interfaces
import "./interfaces/Uniswap.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract OseanDao is
    IThirdwebContract,
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction
{
    bytes32 private constant MODULE_TYPE = bytes32("VoteERC721");
    uint256 private constant VERSION = 1;

    string public contractURI;
    uint256 public proposalIndex;

    struct Proposal {
        uint256 proposalId;
        address proposer;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        uint256 startBlock;
        uint256 endBlock;
        string description;
    }

    mapping(uint256 => uint256) public proposalIdToIndex;
    

    // @dev proposal index => Proposal
    mapping(uint256 => Proposal) public proposals;

    // The Uniswap router address for swapping NAU tokens for WETH.
    address public uniswapRouterAddress;

    // Address of NAU token on ETH chain
    address public nautor;

    // Address of USDT token on ETH chain
    address public usdt;

    // Uniswap router interface.
    IUniswapV2Router02 private uniswapRouter;

    event ContractURIUpdated(string prevURI, string newURI);
    event NautorAddressUpdated(address indexed prevNautor, address indexed newNautor);
    event UsdtAddressUpdated(address indexed prevUsdt, address indexed newUsdt);
    event UniswapRouterUpdated(address indexed prevRouter, address indexed newRouter);

    constructor(
        string memory _name,
        string memory _contractURI,
        address _token,
        address _uniswapRouterAddress,
        address _nautor,
        address _usdt,
        uint256 _initialVotingDelay,
        uint256 _initialVotingPeriod,
        uint256 _initialProposalThreshold,
        uint256 _initialVoteQuorumFraction
    )        
        Governor(_name)
        GovernorSettings(
            _initialVotingDelay,
            _initialVotingPeriod,
            _initialProposalThreshold
        )
        GovernorVotes(IVotes(_token))
        GovernorVotesQuorumFraction(_initialVoteQuorumFraction)
    {
        require(_token != address(0), "token = zero");
        require(_uniswapRouterAddress != address(0), "router = zero");
        require(_nautor != address(0), "nautor = zero");
        require(_usdt != address(0), "usdt = zero");

        contractURI = _contractURI;
        nautor = _nautor;
        usdt = _usdt;
        uniswapRouterAddress = _uniswapRouterAddress;
        uniswapRouter = IUniswapV2Router02(_uniswapRouterAddress);
    }
        
    // @dev Returns the module type of the contract.
    function contractType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    // @dev Returns the version of the contract.
    function contractVersion() public pure override returns (uint8) {
        return uint8(VERSION);
    }

    /*
      @dev See {IGovernor-propose}.
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public virtual override returns (uint256 proposalId) {
        proposalId = super.propose(targets, values, calldatas, description);

        proposals[proposalIndex] = Proposal({
            proposalId: proposalId,
            proposer: _msgSender(),
            targets: targets,
            values: values,
            calldatas: calldatas,
            startBlock: proposalSnapshot(proposalId),
            endBlock: proposalDeadline(proposalId),
            description: description
        });

        proposalIdToIndex[proposalId] = proposalIndex;
        proposalIndex += 1;
    }

    // @dev Returns all proposals made.
    function getAllProposals() external view returns (Proposal[] memory allProposals) {
        uint256 nextProposalIndex = proposalIndex;

        allProposals = new Proposal[](nextProposalIndex);
        for (uint256 i = 0; i < nextProposalIndex; i += 1) {
            allProposals[i] = proposals[i];
        }
    }

    function getProposalById(uint256 proposalId)
        external
        view
        returns (Proposal memory)
    {
        uint256 index = proposalIdToIndex[proposalId];
        require(index < proposalIndex, "invalid proposal id");
        require(proposals[index].proposalId == proposalId, "proposal not found");
        return proposals[index];
    }

    function getProposalCount() external view returns (uint256) {
        return proposalIndex;
    }

    function getProposals(uint256 offset, uint256 limit)
        external
        view
        returns (Proposal[] memory page)
    {
        uint256 total = proposalIndex;

        if (offset >= total) {
            return new Proposal[](0);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 size = end - offset;
        page = new Proposal[](size);

        for (uint256 i = 0; i < size; i++) {
            page[i] = proposals[offset + i];
        }
    }

    function setContractURI(string calldata uri) external onlyGovernance {
        emit ContractURIUpdated(contractURI, uri);
        contractURI = uri;
    }

    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return GovernorSettings.proposalThreshold();
    }

    function votingDelay()
        public
        view
        override(IGovernor, GovernorSettings)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public
        view
        override(IGovernor, GovernorSettings)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(IGovernor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function swapNAUForETH(uint256 amount) private {
        require(amount > 0, "amount = 0");

        IERC20 nautorToken = IERC20(nautor);
        nautorToken.approve(address(uniswapRouter), 0);
        nautorToken.approve(address(uniswapRouter), amount);

        address[] memory path = new address[](2);
        path[0] = address(nautorToken);
        path[1] = uniswapRouter.WETH();

        uniswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp
        );
    } 

    function swapNAU (uint256 amount) external onlyGovernance {
        swapNAUForETH(amount);
    }

    function swapETHForNAU(uint256 amount) private {
        address[] memory path = new address[](2);
        path[0] = uniswapRouter.WETH();
        path[1] = address(nautor);

        uniswapRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function swapETH(uint256 amount) external onlyGovernance {
        swapETHForNAU(amount);
    }

    function swapETHForUSDT(uint256 amount) private {
        address[] memory path = new address[](2);
        path[0] = uniswapRouter.WETH();
        path[1] = address(usdt);

        uniswapRouter.swapExactETHForTokens{value: amount}(
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function swapEforU(uint256 amount) external onlyGovernance {
        swapETHForUSDT(amount);
    }

    function swapUSDTForETH(uint256 amount) private {
        address[] memory path = new address[](2);
        path[0] = usdt;
        path[1] = uniswapRouter.WETH();

        IERC20(usdt).approve(address(uniswapRouter), 0);
        IERC20(usdt).approve(address(uniswapRouter), amount);

        uniswapRouter.swapExactTokensForETH(
            amount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function swapUforE(uint256 amount) external onlyGovernance {
        swapUSDTForETH(amount);
    }


     // Function to change the NAU token address
    function setNautorAddress(address _newNautor) public onlyGovernance {
        require(_newNautor != address(0), "nautor = zero");
        emit NautorAddressUpdated(nautor, _newNautor);
        nautor = _newNautor;
    }

    function setUsdtAddress(address _newUsdt) external onlyGovernance {
        require(_newUsdt != address(0), "usdt = zero");
        emit UsdtAddressUpdated(usdt, _newUsdt);
        usdt = _newUsdt;
    }

    receive() external payable override {}

    fallback() external payable {}
}