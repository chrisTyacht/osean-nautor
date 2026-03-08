# OSEAN DAO Smart Contracts

![OSEANDAO](https://osean.online/images/oseanone.jpg)

## Overview

This repository contains the core smart contracts powering **OSEAN DAO**, a decentralized governance system built around verified membership NFTs and a treasury managed by on-chain governance.

The system is composed of four main smart contracts:

* **Nautor (NAU)** – Utility token used within the OSEAN ecosystem.
* **OSEAN Governance NFT** – KYC-restricted NFT representing DAO membership and voting power.
* **OSEAN DAO Governor** – On-chain governance system controlling DAO actions and treasury.
* **KYC Registry** – Minimal on-chain registry used to verify which wallets are allowed to hold governance NFTs.

The design ensures that:

* Only **KYC-approved wallets** can hold governance NFTs.
* Governance NFTs represent **voting power in the DAO**.
* DAO proposals control **treasury operations and protocol configuration**.
* All sensitive personal data remains **off-chain**, preserving privacy and GDPR compliance.

---

# Architecture

The system follows the structure below:

```
KYC Registry
     │
     │ verifies
     ▼
OSEAN Governance NFT (ERC721Votes)
     │
     │ provides voting power
     ▼
OSEAN DAO Governor
     │
     │ controls
     ▼
DAO Treasury / Protocol Actions
```

---

# Contracts

## 1. Nautor (NAU) Token

Utility token used throughout the OSEAN ecosystem.

### Purpose

* Ecosystem utility token
* DAO treasury asset
* Used in treasury swap operations
* Liquidity on Uniswap

### Key Characteristics

* ERC20-compatible token
* Used for treasury swaps through the DAO
* Interacts with Uniswap V2 router

---

## 2. OSEAN Governance NFT

The Governance NFT represents **verified DAO membership and voting power**.

### Base Implementation

Based on:

```
Thirdweb DropERC721
ERC721A
OpenZeppelin VotesUpgradeable
```

### Key Features

* **ERC721Votes integration**
  Each NFT provides voting power to the DAO.

* **KYC-enforced transfers**
  Only KYC-approved wallets can hold or transfer NFTs.

* **Restricted operators**
  Only approved marketplaces or operators can be granted approval.

* **Burn disabled**
  Governance NFTs cannot be burned.

* **Lazy minting support**
  Uses Thirdweb lazy minting architecture.

### Compliance Design

Transfers are restricted using the external **KYC Registry**:

```
SENDER must be KYC
RECEIVER must be KYC
```

This ensures governance tokens only circulate between verified participants.

---

## 3. KYC Registry

A minimal on-chain registry used to verify whether a wallet address has passed KYC.

### Privacy Design

The registry stores **no personal data**.
Only a boolean flag is stored:

```
wallet → KYC approved
```

All personal data remains off-chain.

### Features

* KYC approval management
* KYC revocation (for GDPR compliance)
* Access controlled by `KYC_ADMIN_ROLE`

Example:

```
approveKYC(address wallet)
revokeKYC(address wallet)
isKYC(address wallet)
```

If a user exits governance, their wallet can be removed from the registry so their off-chain KYC data may be deleted.

---

## 4. OSEAN DAO Governor

The governance contract responsible for managing DAO proposals and executing treasury actions.

### Base Implementation

Based on:

```
OpenZeppelin GovernorUpgradeable
Thirdweb infrastructure interfaces
ERC2771 meta-transactions
```

### Voting Power

Voting power is derived from the **Governance NFT** using:

```
ERC721VotesUpgradeable
```

### Governance Features

* Proposal creation
* Voting period and voting delay configuration
* Quorum enforcement
* Proposal threshold requirements

### Treasury Controls

Governance proposals may execute treasury actions including:

* Swap NAU ↔ ETH
* Swap ETH ↔ NAU
* Swap ETH ↔ USDT
* Swap USDT ↔ ETH

These swaps are executed through a **Uniswap V2 router** and are restricted by:

```
onlyGovernance
```

Meaning they can only be executed via a successful DAO proposal.

---

# Governance Flow

1. KYC provider approves wallet in **KYC Registry**

2. Wallet claims **Governance NFT**

3. NFT grants **voting power**

4. Holder creates a **DAO proposal**

5. DAO members vote

6. If proposal passes:

```
Governor executes the proposal
```

Possible actions include treasury swaps, parameter changes, and protocol upgrades.

---

# Key Security Design Choices

### KYC Enforcement

Only verified wallets may hold governance NFTs.

This prevents governance attacks from unverified participants.

---

### Restricted Marketplace Operators

Only approved operators may be granted approval to transfer NFTs.

This prevents NFTs from being traded through unauthorized marketplaces.

---

### Burn Protection

Governance NFTs cannot be burned to ensure consistent voting power accounting.

---

### Privacy Protection

The system avoids storing personal data on-chain.

The KYC registry only stores approval flags.

---

# Repository Structure

```
contracts/
│
├─ OseanDao.sol
│   DAO governance contract
│
├─ OseanNFT.sol
│   Governance NFT contract
│
├─ Nautor.sol
│   Utility token
│
├─ KYCRegistry.sol
│   KYC verification registry
│
└─ interfaces/
    └─ Uniswap.sol
```

---

# Getting Started

Create a project using the Thirdweb Hardhat template:

```
npx thirdweb create --contract --template hardhat-javascript-starter
```

---

# Build

Compile contracts:

```
npm run build
```

or

```
yarn build
```

---

# Deploy

Deploy contracts using:

```
npm run deploy
```

or

```
yarn deploy
```

---

# License

The OSEAN DAO smart contracts are licensed under the **Business Source License 1.1 (BUSL-1.1)**.

Copyright (c) 2025 **OSEAN DAO LLC**.

The source code is publicly visible for transparency and auditing purposes, but
commercial use of this software — including deployment of derivative protocols
or competing systems based on this code — requires explicit written permission
from **OSEAN DAO LLC**.

After the Change Date defined in the LICENSE file, the software will convert
to the **GNU General Public License (GPL v2.0 or later)**.

See the `LICENSE` file in this repository for full terms.

---

# Trademark Notice

OSEAN, OSEAN DAO, NAUTOR and NAU are trademarks or brand assets of
**OSEAN DAO LLC**.

Unauthorized use of these marks is prohibited.

# Official Links

Token
[https://nautortoken.com](https://nautortoken.com)

Website
[https://osean.online](https://osean.online)
or
[https://oseandao.com](https://oseandao.com)

