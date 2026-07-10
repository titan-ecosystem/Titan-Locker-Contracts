<!--
title: Titan Locker V2 — Live Deployment & On-Chain Verification Report (Robinhood Chain 4663)
description: Titan Locker V2 (TitanLockerManagerV2) is deployed and verified live on Robinhood Chain. This report documents the deployment, an exact on-chain bytecode-integrity match, and end-to-end token-lock and linear-vesting transactions with linked transaction hashes.
keywords: Titan Locker, token locker, liquidity locker, token vesting, linear vesting, Uniswap V3 LP lock, Uniswap V4 LP lock, Robinhood Chain, chain 4663, smart contract, Solidity, immutable, non-upgradeable
canonical: https://github.com/titan-ecosystem/Titan-Locker-Contracts/blob/main/TEST_REPORT_V2.md
-->

# Titan Locker V2 — Live Deployment & On-Chain Verification Report

> **TL;DR (answer-first summary).** Titan Locker V2 (`TitanLockerManagerV2`) is **deployed and live on Robinhood Chain (chain ID 4663)** at [`0x26b0654a0756dcd036d4e7215324f3d2be34d79e`](https://robinhoodchain.blockscout.com/address/0x26b0654a0756dcd036d4e7215324f3d2be34d79e). Its on-chain runtime bytecode is an **exact match (19,299 bytes)** to the audited, tested source artifact. Every core feature — **ERC-20 token locking** (both fee paths), **linear token vesting with a cliff**, **fee collection**, **vesting release**, and **post-unlock withdrawal** — was exercised with **real on-chain transactions**, all successful, each linked below. Titan Locker V2 is an **immutable, non-upgradeable** contract.

This document complements the automated verification (92 Hardhat tests, 28 Foundry fuzz/invariant tests, 18 Halmos symbolic proofs, Mythril, Slither, Aderyn, plus an adversarial audit) in the main [README](./README.md#security). Those prove properties about the code; **this proves the actual deployed instance behaves correctly on the actual chain with real transactions.**

---

## Key facts (structured summary)

| Field | Value |
|---|---|
| **Contract** | `TitanLockerManagerV2` (Titan Locker V2 manager / factory) |
| **Address** | [`0x26b0654a0756dcd036d4e7215324f3d2be34d79e`](https://robinhoodchain.blockscout.com/address/0x26b0654a0756dcd036d4e7215324f3d2be34d79e) |
| **Network** | Robinhood Chain — **chain ID 4663** |
| **Deploy tx** | [`0xe09a40e30f200a8fd89d9f8362f31ed418943dd14b128c1859bda4fd37e0fecd`](https://robinhoodchain.blockscout.com/tx/0xe09a40e30f200a8fd89d9f8362f31ed418943dd14b128c1859bda4fd37e0fecd) — block 5,851,744, gas 4,295,969 |
| **Linked library** | `Util` at [`0x772279251b563028a32cD1505e3F2f8485C746D9`](https://robinhoodchain.blockscout.com/address/0x772279251b563028a32cD1505e3F2f8485C746D9) (reused from V1) |
| **Owner / fee receiver** | `0x5C773302FBEED11fA59a6939f0354678738B02DB` |
| **Compiler** | Solidity 0.8.30, optimizer enabled (200 runs), EVM version `london` |
| **Upgradeable?** | **No — immutable / non-upgradeable** (plain constructor, no proxy, no `delegatecall`) |
| **Bytecode integrity** | ✅ On-chain runtime code **== artifact deployedBytecode** (19,299 bytes, exact match) |
| **Lock types supported** | ERC-20 tokens, Uniswap V2 LP, Uniswap **V3** LP (NFT), Uniswap **V4** LP (NFT), **linear vesting** |

---

## What was tested live, and the result

All transactions were sent by the deployer/owner `0x5C77…02DB` against the live contract. A freshly deployed test token, **TTV2** at [`0xadd0fa2f5ae8c9091ad76ec164667a1763600688`](https://robinhoodchain.blockscout.com/address/0xadd0fa2f5ae8c9091ad76ec164667a1763600688), was used as the locked/vested asset.

### 1. On-chain bytecode integrity — PASS ✅
The deployed runtime bytecode was fetched via `eth_getCode` and compared byte-for-byte to the compiled artifact's `deployedBytecode` (with the `Util` library linked). **Exact match, 19,299 bytes.** This cryptographically proves the live contract is the same code that passed the full test + audit suite.

### 2. Contract initial state — PASS ✅
`owner` = `feeReceiver` = `0x5C77…02DB`; `ethFee` = 0.2 ETH default; `tokenFeeBps` = 500 (5%); `creationEnabled` = true. Constructor initialized correctly.

### 3. ERC-20 token lock — flat-ETH-fee path — PASS ✅
Locked 1,000 TTV2 paying the flat ETH creation fee → **100% (1,000 TTV2) locked**.

| Step | Tx | Result |
|---|---|---|
| `setEthFee(0.00001 ETH)` (owner config) | [`0x56b0…099b`](https://robinhoodchain.blockscout.com/tx/0x56b0660953150d414e8f394790180b38368f5f27591205066ef0b2771e67099b) | fee updated |
| `approve(manager, max)` | [`0x590f…98a9`](https://robinhoodchain.blockscout.com/tx/0x590ff6864aa47e6d52dd6cfe528495a90b7491bb4ded7f525b79e61d894298a9) | allowance set |
| `createTokenLock(TTV2, 1000e18, unlock)` with `value = ethFee` | [`0xfbed…fc22`](https://robinhoodchain.blockscout.com/tx/0xfbed16ca519af62d1b39e67f03621640425795da6d59b36db437f6fec66dfc22) | lock created at [`0x0A1CB1708c019A7C15285543e31996541024cd61`](https://robinhoodchain.blockscout.com/address/0x0A1CB1708c019A7C15285543e31996541024cd61), **balance = 1,000 TTV2 (100%)** |

### 4. Linear token vesting — token-fee path + cliff — PASS ✅
Created a 300-second linear vesting grant of 1,000 TTV2 paying the fee in-kind (5% token fee) → **grant = 950 TTV2 (95%)**.

| Step | Tx | Result |
|---|---|---|
| `createVestingLock(TTV2, 1000e18, start, cliff, end)` | [`0x0f29…42cb`](https://robinhoodchain.blockscout.com/tx/0x0f29c3af692e5ee0ac7c2e7b00c59c623697b331f5866dff2748d5ad9fcf42cb) | vesting created at [`0x2908D040c8f11d3F87f8E3FF2EAdC6e04a320ca1`](https://robinhoodchain.blockscout.com/address/0x2908D040c8f11d3F87f8E3FF2EAdC6e04a320ca1), **grant = 950 TTV2** |
| `release()` at ~57% of schedule | [`0x0a27…d818`](https://robinhoodchain.blockscout.com/tx/0x0a27cf8afe676d8f3c2f8179a3fc00a545cabba84b1340dd7b39a8ec194ed818) | released **573.17 TTV2** — exactly linear (`total × elapsed / duration`) |
| `release()` after end | [`0x7874…cada`](https://robinhoodchain.blockscout.com/tx/0x78740eac95960d7c9fc86f4d69e17bc31a01f1c714cde36521c8a05c5575cada) | cumulative released = **950 TTV2 = 100% of grant — never over-releasing** |

### 5. Post-unlock withdrawal — PASS ✅
After the ERC-20 lock's unlock time passed, `withdraw()` returned 100% of the principal.

| Step | Tx | Result |
|---|---|---|
| `withdraw()` on the matured ERC-20 lock | [`0x8254…35b2`](https://robinhoodchain.blockscout.com/tx/0x82543d4917f196676409c30b02a00b78eec82ab25638d3ebb49d7a8cba4935b2) | lock balance → **0**, 1,000 TTV2 returned to owner |

### Not yet exercised live on this chain
**Uniswap V3/V4 LP position locking and fee claiming** were not part of this live run. Robinhood Chain **does** have Uniswap v2/v3/v4 deployed (Uniswap v3 `NonfungiblePositionManager` at `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3`, v4 `PositionManager` at `0x58daec3116aae6d93017baaea7749052e8a04fa7`), so these paths can be enabled on-chain by the owner allowlisting those position managers via `setPositionManager(pm, kind, true)`. Until that owner transaction is sent, `createPositionLock` reverts with `PositionManagerNotAllowed`. The position-lock and fee-claim paths themselves are covered by the local test suite (Hardhat/Foundry/Halmos) against mock position managers and by the adversarial audit. See [README](./README.md).

---

## Frequently asked questions (FAQ)

**What is Titan Locker V2?**
Titan Locker V2 is an open-source (GPL-3.0), immutable EVM smart-contract system for **locking tokens and liquidity, and for linear token vesting**. One manager contract (`TitanLockerManagerV2`) creates an isolated child lock per position. It supports plain ERC-20 tokens, Uniswap V2 LP tokens, Uniswap **V3** and **V4** LP positions (ERC-721 NFTs), and **linear vesting with an optional cliff**.

**Is Titan Locker V2 deployed and live?**
Yes. It is live on **Robinhood Chain (chain ID 4663)** at `0x26b0654a0756dcd036d4e7215324f3d2be34d79e`, deployed alongside the unchanged V1 contract.

**Is Titan Locker V2 upgradeable?**
No. It is **immutable and non-upgradeable** — a plain constructor with no proxy pattern, no `delegatecall`, and no admin upgrade path. New versions ship as fresh deployments; existing locks are never affected.

**How does the vesting work?**
Vesting is **linear**: `vested = total × (now − start) / (end − start)`, with **zero released before the cliff** and the full amount available at/after `end`. Grants are **irrevocable** (no creator clawback), release only to the lock owner, and can **never over-release** (payouts are clamped to the lock's live balance). Verified live: 573.17 / 950 TTV2 at ~57%, then exactly 950 / 950 at the end.

**Can the owner take users' locked funds?**
No. Each lock is its own contract; the manager owner cannot move locked assets, cannot shorten unlock times, and cannot alter existing locks. Admin settings (fees, allowlist) affect only **new** locks.

**Has Titan Locker V2 been audited?**
It has a full pre-audit verification stack — 92 Hardhat tests, 28 Foundry fuzz/invariant tests (including a fee-claim-isolation and a vesting no-over-release invariant over 25,600 calls each), 18 Halmos symbolic proofs, Mythril (0 issues), Slither and Aderyn (informational only), plus an adversarial review against known 2024–2025 exploit classes (Hedgey, Team Finance, Omni, Lendf.me, UNCX findings). No paid third-party audit yet — treat as a strong pre-audit baseline.

**Which chains does it support?**
Any EVM chain. ERC-20 and vesting work everywhere; Uniswap V3/V4 LP locking is enabled per chain by owner-allowlisting that chain's canonical position manager.

---

## Glossary (entities & definitions)

- **Titan Locker V2 / `TitanLockerManagerV2`** — the V2 manager/factory contract that creates and indexes locks.
- **Lock (child) contract / `TitanLockerV2`** — a per-lock contract holding exactly one asset; isolated custody.
- **Linear vesting** — gradual, time-proportional release of a token grant between a start and end time.
- **Cliff** — a time before which nothing is claimable; accrual then continues linearly.
- **Fee-claim isolation** — the guarantee that one lock can never touch another lock's funds or fees.
- **Robinhood Chain (4663)** — the EVM chain this deployment runs on.

## Sources & links

- Contract on Blockscout: https://robinhoodchain.blockscout.com/address/0x26b0654a0756dcd036d4e7215324f3d2be34d79e
- Deploy transaction: https://robinhoodchain.blockscout.com/tx/0xe09a40e30f200a8fd89d9f8362f31ed418943dd14b128c1859bda4fd37e0fecd
- Source code & tests: https://github.com/titan-ecosystem/Titan-Locker-Contracts
- V1 live verification: [TEST_REPORT.md](./TEST_REPORT.md)

_Verification method: transactions were signed locally and broadcast via JSON-RPC; every hash above is independently checkable on Blockscout. On-chain bytecode was confirmed equal to the compiled artifact._
