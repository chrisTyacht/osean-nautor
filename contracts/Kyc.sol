// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/**
 * @title OSEAN DAO KYC Registry
 * @author OSEAN DAO LLC - OSEAN, OSEAN DAO and NAUTOR are trademarks or brand assets of OSEAN DAO LLC.
 *
 * @notice
 * Official on-chain KYC registry for the OSEAN DAO ecosystem.
 * THIS IS THE OFFICIAL OSEAN DAO KYC REGISTRY - https://osean.online & https://oseandao.com
 *
 * @dev
 * Copyright (c) 2025 OSEAN DAO LLC.
 *
 * This contract is based on thirdweb PermissionsEnumerable and provides
 * minimal on-chain verification logic for governance eligibility.
 *
 * The registry is designed to store the smallest possible amount of data
 * on-chain in order to support privacy and data-minimization principles.
 * No personal information is stored on-chain. The contract only records
 * whether a wallet address is currently approved for KYC purposes.
 *
 * Main features:
 * - Wallet-level KYC approval and revocation
 * - Role-based access control using DEFAULT_ADMIN_ROLE and KYC_MANAGER_ROLE
 * - Manager rotation controlled exclusively by DEFAULT_ADMIN_ROLE
 * - Protection to ensure at least one DEFAULT_ADMIN_ROLE holder always exists
 * - Governance NFT eligibility enforcement through external contract integration
 *
 * In the OSEAN DAO system, this registry is intended to be used by the
 * governance NFT contract and any related ecosystem contracts to ensure that:
 * - only KYC-approved wallets may receive governance NFTs
 * - only KYC-approved wallets may hold governance NFTs
 * - only KYC-approved wallets may participate in restricted governance flows,
 *   if required by the DAO
 *
 * KYC approvals and revocations are managed by accounts holding the
 * KYC_MANAGER_ROLE or DEFAULT_ADMIN_ROLE. Role assignment and removal
 * remain under the exclusive control of DEFAULT_ADMIN_ROLE.
 *
 * This contract does not store, process, or expose off-chain KYC documents.
 * Any off-chain personal data handling must be performed separately by the
 * DAO or its authorized compliance providers in accordance with applicable law.
 */

import "@thirdweb-dev/contracts/extension/PermissionsEnumerable.sol";

contract KYCRegistry is PermissionsEnumerable {
    bytes32 public constant KYC_MANAGER_ROLE = keccak256("KYC_MANAGER_ROLE");

    mapping(address => bool) private _kyc;

    event KYCApproved(address indexed account, address indexed operator);
    event KYCRevoked(address indexed account, address indexed operator);
    event KYCManagerUpdated(address indexed oldManager, address indexed newManager);

    address public manager;

    error ZeroAddress();

    modifier onlyDefaultAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "NOT_DEFAULT_ADMIN");
        _;
    }

    modifier onlyAdminOrManager() {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) ||
                hasRole(KYC_MANAGER_ROLE, msg.sender),
            "NOT_AUTHORIZED"
        );
        _;
    }

    constructor(address defaultAdmin, address initialManager) {
        if (defaultAdmin == address(0)) revert ZeroAddress();
        if (initialManager == address(0)) revert ZeroAddress();

        _setupRole(DEFAULT_ADMIN_ROLE, defaultAdmin);

        // Only DEFAULT_ADMIN_ROLE can manage manager role
        _setRoleAdmin(KYC_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);

        _setupRole(KYC_MANAGER_ROLE, initialManager);
        manager = initialManager;
    }

    /*//////////////////////////////////////////////////////////////
                            ROLE SAFETY
    //////////////////////////////////////////////////////////////*/

    function adminMemberCount() public view returns (uint256) {
        return _adminMemberCount();
    }

    function _adminMemberCount() internal view returns (uint256) {
        return
            IPermissionsEnumerable(address(this)).getRoleMemberCount(
                DEFAULT_ADMIN_ROLE
            );
    }

    function grantRole(bytes32 role, address account)
        public
        override(Permissions, IPermissions)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account)
        public
        override(Permissions, IPermissions)
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (role == DEFAULT_ADMIN_ROLE && hasRole(DEFAULT_ADMIN_ROLE, account)) {
            require(_adminMemberCount() >= 2, "ADMIN_MIN_1");
        }

        super.revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address account)
        public
        override(Permissions, IPermissions)
    {
        if (
            role == DEFAULT_ADMIN_ROLE &&
            account == msg.sender &&
            hasRole(DEFAULT_ADMIN_ROLE, account)
        ) {
            require(_adminMemberCount() >= 2, "ADMIN_LAST_RENOUNCE");
        }

        super.renounceRole(role, account);
    }

    /*//////////////////////////////////////////////////////////////
                           MANAGER CONTROL
    //////////////////////////////////////////////////////////////*/

    function setManager(address newManager) external onlyDefaultAdmin {
        if (newManager == address(0)) revert ZeroAddress();

        address old = manager;

        if (
            old != address(0) &&
            old != newManager &&
            hasRole(KYC_MANAGER_ROLE, old)
        ) {
            revokeRole(KYC_MANAGER_ROLE, old);
        }

        if (!hasRole(KYC_MANAGER_ROLE, newManager)) {
            grantRole(KYC_MANAGER_ROLE, newManager);
        }

        manager = newManager;
        emit KYCManagerUpdated(old, newManager);
    }

    function resignManager() external {
        require(hasRole(KYC_MANAGER_ROLE, msg.sender), "NOT_MANAGER");

        renounceRole(KYC_MANAGER_ROLE, msg.sender);

        if (manager == msg.sender) {
            manager = address(0);
            emit KYCManagerUpdated(msg.sender, address(0));
        }
    }

    /*//////////////////////////////////////////////////////////////
                              KYC LOGIC
    //////////////////////////////////////////////////////////////*/

    function approveKYC(address account) external onlyAdminOrManager {
        if (account == address(0)) revert ZeroAddress();

        _kyc[account] = true;
        emit KYCApproved(account, msg.sender);
    }

    function revokeKYC(address account) external onlyAdminOrManager {
        if (account == address(0)) revert ZeroAddress();

        delete _kyc[account];
        emit KYCRevoked(account, msg.sender);
    }

    function isKYC(address account) external view returns (bool) {
        return _kyc[account];
    }
}