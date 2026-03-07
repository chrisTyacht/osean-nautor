// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

/**
 * @title OSEAN DAO Governance NFT
 * @author OSEAN DAO LLC
 *
 * @notice
 * Governance NFT contract used by the OSEAN DAO to represent verified DAO
 * membership and voting power - https://osean.online & https://oseandao.com
 *
 * @dev
 * This contract is based on Thirdweb's DropERC721 implementation with
 * additional governance and compliance features:
 *
 * - ERC721A-based gas-efficient NFT minting
 * - ERC721Votes integration for on-chain governance voting power
 * - Lazy minting support via Thirdweb Drop mechanics
 * - KYC enforcement via an external KYCRegistry contract
 * - Restricted operator approvals (only approved marketplace contracts)
 * - Governance NFTs cannot be burned
 *
 * Compliance Rules:
 * - Only wallets approved in the KYCRegistry may receive or transfer NFTs
 * - Transfers between non-KYC wallets are rejected
 * - Marketplace operators must be explicitly approved by DAO administrators
 *
 * Privacy Design:
 * The contract does not store any personal data on-chain. KYC information is
 * managed off-chain and only a minimal approval flag is verified through the
 * external KYC registry contract.
 *
 * This NFT represents governance rights within the OSEAN DAO ecosystem.
 */

import "@thirdweb-dev/contracts/extension/Multicall.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";

import "./extensions/ERC721AVotesUpgradeable.sol";

//  ==========  Internal imports    ==========

import "@thirdweb-dev/contracts/external-deps/openzeppelin/metatx/ERC2771ContextUpgradeable.sol";
import "@thirdweb-dev/contracts/lib/CurrencyTransferLib.sol";

//  ==========  Features    ==========

import "@thirdweb-dev/contracts/extension/ContractMetadata.sol";
import "@thirdweb-dev/contracts/extension/Royalty.sol";
import "@thirdweb-dev/contracts/extension/PrimarySale.sol";
import "@thirdweb-dev/contracts/extension/LazyMint.sol";
import "@thirdweb-dev/contracts/extension/PermissionsEnumerable.sol";
import "@thirdweb-dev/contracts/extension/Drop.sol";

interface IKYCRegistry {
    function isKYC(address account) external view returns (bool);
}

contract OseanNFT is
    ContractMetadata,
    Royalty,
    PrimarySale,
    LazyMint,
    PermissionsEnumerable,
    Drop,
    ERC2771ContextUpgradeable,
    Multicall,
    ERC721AUpgradeable,
    ERC721VotesUpgradeable
{
    using StringsUpgradeable for uint256;

    /*///////////////////////////////////////////////////////////////
                            State variables
    //////////////////////////////////////////////////////////////*/
    
    /// @dev Only MINTER_ROLE holders can sign off on `MintRequest`s and lazy mint tokens.
    bytes32 private minterRole;
    
    /// @dev Only METADATA_ROLE holders can reveal the URI for a batch of delayed reveal NFTs, and update or freeze batch metadata.
    bytes32 private metadataRole;

    /// @dev Global max total supply of NFTs.
    uint256 public maxTotalSupply;

    /// @dev Emitted when the global max supply of tokens is updated.
    event MaxTotalSupplyUpdated(uint256 maxTotalSupply);
    event KYCRegistryUpdated(address indexed registry);
    event ApprovedOperatorUpdated(address indexed operator, bool approved);

    /// @dev External KYC registry used to validate who may hold / receive governance NFTs.
    IKYCRegistry public kycRegistry;

    /// @dev Approved marketplace / operator contracts that may be granted approvals.
    mapping(address => bool) public approvedOperators;

    /*///////////////////////////////////////////////////////////////
                    Constructor + initializer logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Initializes the contract, like a constructor.
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        address[] memory _trustedForwarders,
        address _saleRecipient,
        address _royaltyRecipient,
        uint128 _royaltyBps,
        address _kycRegistry
    ) initializer {
        require(_saleRecipient != address(0), "saleRecipient = zero");
        require(_royaltyRecipient != address(0), "royaltyRecipient = zero");
        require(_kycRegistry != address(0), "kycRegistry = zero");
        
        bytes32 _minterRole = keccak256("MINTER_ROLE");
        bytes32 _metadataRole = keccak256("METADATA_ROLE");

        __ERC2771Context_init(_trustedForwarders);
        __ERC721A_init(_name, _symbol);
        __ERC721Votes_init();

        _setupContractURI(_contractURI);

        _setupRole(DEFAULT_ADMIN_ROLE,  msg.sender);
        _setupRole(_minterRole, msg.sender);
        _setupRole(_metadataRole, msg.sender);
        _setRoleAdmin(_metadataRole, _metadataRole);

        _setupDefaultRoyaltyInfo(_royaltyRecipient, _royaltyBps);
        _setupPrimarySaleRecipient(_saleRecipient);
        
        minterRole = _minterRole;
        metadataRole = _metadataRole;

        kycRegistry = IKYCRegistry(_kycRegistry);
        emit KYCRegistryUpdated(_kycRegistry);
    }

    /*///////////////////////////////////////////////////////////////
                        ERC 165 / 721 / 2981 logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the URI for a given tokenId.
    /// @dev Returns the URI for a given tokenId.
    function tokenURI(uint256 _tokenId) public view override returns (string memory) {
        string memory batchUri = _getBaseURI(_tokenId);

        return string(abi.encodePacked(batchUri, _tokenId.toString()));
        
    }

    /// @dev See ERC 165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721AUpgradeable, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId) || type(IERC2981Upgradeable).interfaceId == interfaceId;
    }

    /*///////////////////////////////////////////////////////////////
                        Contract identifiers
    //////////////////////////////////////////////////////////////*/

    function contractType() external pure returns (bytes32) {
        return bytes32("DropERC721");
    }

    function contractVersion() external pure returns (uint8) {
        return uint8(4);
    }

    /*///////////////////////////////////////////////////////////////
                    Lazy minting + delayed-reveal logic
    //////////////////////////////////////////////////////////////*/

    /**
     *  @dev Lets an account with `MINTER_ROLE` lazy mint 'n' NFTs.
     *       The URIs for each token is the provided `_baseURIForTokens` + `{tokenId}`.
     */
    function lazyMint(
        uint256 _amount,
        string calldata _baseURIForTokens,
        bytes calldata _data
    ) public override returns (uint256 batchId) {
        
        return super.lazyMint(_amount, _baseURIForTokens, _data);
    }


    /**
     * @notice Freezes the base URI for a batch of tokens.
     *
     * @param _index Index of the desired batch in batchIds array.
     */
    function freezeBatchBaseURI(uint256 _index) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 batchId = getBatchIdAtIndex(_index);
        _freezeBaseURI(batchId);
    }

    /*///////////////////////////////////////////////////////////////
                        Setter functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Lets a contract admin set the global maximum supply for collection's NFTs.
    function setMaxTotalSupply(uint256 _maxTotalSupply) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxTotalSupply == 0 || _maxTotalSupply >= _currentIndex, "!maxSupply");
        maxTotalSupply = _maxTotalSupply;
        emit MaxTotalSupplyUpdated(_maxTotalSupply);
    }

    function addAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
    }

    function setKYCRegistry(address _registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_registry != address(0), "registry=0");
        kycRegistry = IKYCRegistry(_registry);
        emit KYCRegistryUpdated(_registry);
    }

    function setApprovedOperator(address operator, bool approved)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(operator != address(0), "operator=0");
        approvedOperators[operator] = approved;
        emit ApprovedOperatorUpdated(operator, approved);
    }

    function getApproved(uint256 tokenId) public view virtual override returns (address) {
        address operator = super.getApproved(tokenId);
        return approvedOperators[operator] ? operator : address(0);
    }

    function isApprovedForAll(address owner, address operator) public view virtual override returns (bool) {
        if (!approvedOperators[operator]) {
            return false;
        }
        return super.isApprovedForAll(owner, operator);
    }

    /*///////////////////////////////////////////////////////////////
                        Internal functions
    //////////////////////////////////////////////////////////////*/

     function _isKYC(address account) internal view returns (bool) {
        return address(kycRegistry) != address(0) && kycRegistry.isKYC(account);
    }

    function _requireKYC(address account, string memory err) internal view {
        require(_isKYC(account), err);
    }
    
    /// @dev Runs before every `claim` function call.
    function _beforeClaim(
        address,
        uint256 _quantity,
        address,
        uint256,
        AllowlistProof calldata,
        bytes memory
    ) internal view override {
        require(_currentIndex + _quantity <= nextTokenIdToLazyMint, "!Tokens");
        require(maxTotalSupply == 0 || _currentIndex + _quantity <= maxTotalSupply, "!Supply");
    }

    /// @dev Collects and distributes the primary sale value of NFTs being claimed.
    function _collectPriceOnClaim(
        address _primarySaleRecipient,
        uint256 _quantityToClaim,
        address _currency,
        uint256 _pricePerToken
    ) internal override {
        if (_pricePerToken == 0) {
            require(msg.value == 0, "!V");
            return;
        }

        address saleRecipient = _primarySaleRecipient == address(0) ? primarySaleRecipient() : _primarySaleRecipient;

        uint256 totalPrice = _quantityToClaim * _pricePerToken;

        bool validMsgValue;
        if (_currency == CurrencyTransferLib.NATIVE_TOKEN) {
            validMsgValue = msg.value == totalPrice;
        } else {
            validMsgValue = msg.value == 0;
        }
        require(validMsgValue, "!V");

        CurrencyTransferLib.transferCurrency(_currency, _msgSender(), saleRecipient, totalPrice);
    }

    /// @dev Transfers the NFTs being claimed.
    function _transferTokensOnClaim(address _to, uint256 _quantityBeingClaimed)
        internal
        override
        returns (uint256 startTokenId)
    {
        startTokenId = _currentIndex;
        _safeMint(_to, _quantityBeingClaimed);
    }

    /// @dev Checks whether primary sale recipient can be set in the given execution context.
    function _canSetPrimarySaleRecipient() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }
    
    /// @dev Checks whether royalty info can be set in the given execution context.
    function _canSetRoyaltyInfo() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Checks whether contract metadata can be set in the given execution context.
    function _canSetContractURI() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Checks whether platform fee info can be set in the given execution context.
    function _canSetClaimConditions() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Returns whether lazy minting can be done in the given execution context.
    function _canLazyMint() internal view virtual override returns (bool) {
        return hasRole(minterRole, _msgSender());
    }

        /*///////////////////////////////////////////////////////////////
        DEFAULT ADMIN ROLE OVERRIDES & GUARD AGAINST BRICKING
    //////////////////////////////////////////////////////////////*/

    function adminCount() public view returns (uint256) {
        return _adminCount();
    }

    function _adminCount() internal view returns (uint256) {
        return IPermissionsEnumerable(address(this)).getRoleMemberCount(DEFAULT_ADMIN_ROLE);
    }
    
    function renounceRole(bytes32 role, address account)
        public
        override(Permissions, IPermissions)
    {
        if (role == DEFAULT_ADMIN_ROLE && hasRole(DEFAULT_ADMIN_ROLE, account)) {
            require(_adminCount() >= 2, "LAST_ADMIN");
        }

        super.renounceRole(role, account);
    }

    function revokeRole(bytes32 role, address account)
        public
        override(Permissions, IPermissions)
    {
        if (role == DEFAULT_ADMIN_ROLE && hasRole(DEFAULT_ADMIN_ROLE, account)) {
            require(_adminCount() >= 2, "LAST_ADMIN");
        }

        super.revokeRole(role, account);
    }

    /*///////////////////////////////////////////////////////////////
                        Miscellaneous
    //////////////////////////////////////////////////////////////*/

    /**
     * Returns the total amount of tokens minted in the contract.
     */
    function totalMinted() external view returns (uint256) {
        return _totalMinted();
    }

    /// @dev The tokenId of the next NFT that will be minted / lazy minted.
    function nextTokenIdToMint() external view returns (uint256) {
        return nextTokenIdToLazyMint;
    }

    /// @dev The next token ID of the NFT that can be claimed.
    function nextTokenIdToClaim() external view returns (uint256) {
        return _currentIndex;
    }

    
    /// @dev See {ERC721-_beforeTokenTransfer}.
    function _beforeTokenTransfers(
        address from,
        address to,
        uint256 startTokenId,
        uint256 quantity
    ) internal virtual override {
        super._beforeTokenTransfers(from, to, startTokenId, quantity);

        // burn
        if (to == address(0)) {
            revert("BURN_DISABLED");
        }

        // mint
        if (from == address(0)) {
            _requireKYC(to, "RECIPIENT_NOT_KYC");
            return;
        }

        // both sides must be active KYC members
        _requireKYC(from, "SENDER_NOT_KYC");
        _requireKYC(to, "RECIPIENT_NOT_KYC");
    }

    function _afterTokenTransfers(
        address from,
        address to,
        uint256 startTokenId,
        uint256 quantity
    ) internal virtual override(ERC721AUpgradeable, ERC721VotesUpgradeable){
        
        super._afterTokenTransfers(from, to, startTokenId, quantity);
    }

    function approve(address to, uint256 tokenId) public virtual override {
        if (to != address(0)) {
            require(approvedOperators[to], "OPERATOR_NOT_APPROVED");
        }
        super.approve(to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) public virtual override {
        if (approved) {
            require(approvedOperators[operator], "OPERATOR_NOT_APPROVED");
        }
        super.setApprovalForAll(operator, approved);
    }

    function _dropMsgSender() internal view virtual override returns (address) {
        return _msgSender();
    }

    function _msgSender()
        internal
        view
        virtual
        override(Multicall, ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address sender)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

}