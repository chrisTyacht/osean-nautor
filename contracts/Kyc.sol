// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title OSEAN DAO KYC Registry
 * @author OSEAN DAO LLC - OSEAN, OSEAN DAO and NAUTOR are trademarks or brand assets of OSEAN DAO LLC.
 *
 * @notice
 * Minimal on-chain registry used to verify whether a wallet address has
 * passed KYC and is allowed to hold governance NFTs.
 *
 * @dev
 * Copyright (c) 2025 OSEAN DAO LLC.
 *
 * This contract intentionally stores the smallest possible amount of data
 * to respect privacy and GDPR principles. No personal information is stored
 * on-chain. Only a boolean flag indicating whether a wallet is KYC-approved
 * is recorded.
 *
 * The registry is used by the OseanNFT governance contract to enforce that:
 * - Only KYC-approved wallets can receive governance NFTs
 * - Only KYC-approved wallets can transfer governance NFTs
 *
 * KYC approvals and revocations are managed by accounts with the
 * KYC_ADMIN_ROLE.
 *
 * The registry may revoke a wallet's KYC status after the wallet has exited
 * governance (for example after selling all governance NFTs) in order to
 * allow off-chain deletion of personal KYC records for privacy compliance.
 */
contract KYCRegistry is AccessControl {

    /// @notice Role allowed to manage KYC approvals
    bytes32 public constant KYC_ADMIN_ROLE = keccak256("KYC_ADMIN_ROLE");

    /// @dev Mapping of wallet address => KYC approval status
    mapping(address => bool) private _kyc;

    /// @notice Emitted when a wallet is granted KYC approval
    event KYCApproved(address indexed account);

    /// @notice Emitted when a wallet's KYC approval is revoked
    event KYCRevoked(address indexed account);

    /**
     * @notice Deploys the KYC registry
     *
     * @param admin Address that will receive both DEFAULT_ADMIN_ROLE
     * and KYC_ADMIN_ROLE permissions.
     */
    constructor(address admin) {
        require(admin != address(0), "admin=0");

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KYC_ADMIN_ROLE, admin);
    }

    /**
     * @notice Approves a wallet as KYC verified
     *
     * @dev Can only be called by an account with KYC_ADMIN_ROLE.
     *
     * @param account Wallet address to approve.
     */
    function approveKYC(address account) external onlyRole(KYC_ADMIN_ROLE) {
        require(account != address(0), "account=0");

        _kyc[account] = true;

        emit KYCApproved(account);
    }

    /**
     * @notice Revokes a wallet's KYC approval
     *
     * @dev
     * This function should only be used after the wallet has exited
     * governance (i.e. no longer holds governance NFTs).
     *
     * Removing the wallet from the registry allows off-chain KYC data
     * associated with the user to be deleted for privacy compliance.
     *
     * @param account Wallet address to revoke.
     */
    function revokeKYC(address account) external onlyRole(KYC_ADMIN_ROLE) {
        require(account != address(0), "account=0");

        delete _kyc[account];

        emit KYCRevoked(account);
    }

    /**
     * @notice Returns whether a wallet is currently KYC-approved
     *
     * @param account Wallet address to check.
     *
     * @return bool True if the wallet is approved.
     */
    function isKYC(address account) external view returns (bool) {
        return _kyc[account];
    }
}