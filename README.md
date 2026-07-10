<!--
title: Titan Locker Contracts — Token Locker, Liquidity Locker & Token Vesting (Uniswap V2/V3/V4 LP)
description: Titan Locker is an open-source, immutable EVM smart-contract suite for locking ERC-20 tokens and Uniswap V2/V3/V4 LP, and for linear token vesting with a cliff. Deployed and live on Robinhood Chain (4663); non-upgradeable; extensively tested and audited.
keywords: token locker, liquidity locker, LP locker, token vesting, linear vesting, cliff vesting, Uniswap V3 LP lock, Uniswap V4 LP lock, ERC-20 lock, Solidity, immutable smart contract, Robinhood Chain, EVM
-->

# Titan Locker Contracts

**Titan Locker** is an open-source, **immutable (non-upgradeable)** EVM smart-contract suite for **locking tokens and liquidity** and for **linear token vesting with a cliff**. It locks ERC-20 tokens, Uniswap V2 LP tokens, and Uniswap **V3/V4 LP positions** (NFTs), and vests fungible tokens — all through one manager per generation, with each lock isolated in its own child contract. **Live on Robinhood Chain (chain ID 4663).**

![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)
![Solidity](https://img.shields.io/badge/solidity-0.8.30-363636?logo=solidity)
![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.6.1-4E5EE4)
![Tests](https://img.shields.io/badge/tests-90%20passing-brightgreen)
![Slither](https://img.shields.io/badge/slither-clean-brightgreen)
![Aderyn](https://img.shields.io/badge/aderyn-clean-brightgreen)
![Mythril](https://img.shields.io/badge/mythril-clean-brightgreen)
![Foundry](https://img.shields.io/badge/foundry%20fuzz%2Finvariant-28%2F28%20passing-brightgreen)
![Halmos](https://img.shields.io/badge/halmos-18%2F18%20proven-brightgreen)
![npm audit](https://img.shields.io/badge/npm%20audit-0%20critical%2Fhigh-brightgreen)

Smart contracts for Titan Locker, an open source EVM token locker. Free to use, modify,
and fork by anyone under the GPL-3.0-or-later license below.

This is the contracts-only counterpart to the Titan Locker frontend. The core locker
contracts are original implementations written for this project. The only third-party code
involved is `@openzeppelin/contracts` (a normal dependency, not vendored) and a small
vendored copy of Uniswap V2's public interfaces in `contracts/library/Dex.sol` - both
MIT-licensed.

There are two independent generations, deployed side by side (the frontend reads both):

- **V1** locks a single ERC20 (or V2-style LP) balance per lock.
- **V2** is a superset that additionally locks **Uniswap V3 and V4 LP positions** (which
  are ERC721 NFTs, not ERC20) and lets a locker **claim its position's trading fees**
  while the principal stays locked - all through one manager and one universal child
  contract. V1 is unchanged and remains live.

## What's here

**V1**

- **`TitanLockerV1.sol`** - a single token/LP-token lock with an owner-adjustable unlock time
- **`TitanLockerManagerV1.sol`** - deploys and indexes locks, and charges a creation fee
  paid either as a flat ETH amount or as a percentage of the deposited token (both
  owner-adjustable, with a fee-exempt allowlist)

**V2** (tokens + V2/V3/V4 LP, per-lock fee claiming)

- **`TitanLockerV2.sol`** - one universal per-lock child tagged by `LockKind {ERC20, UNIV3,
  UNIV4}`. Holds exactly one asset with an immutable kind/asset/tokenId and `onlyOwner`
  value-moving entry points, so per-lock custody is isolated by construction - one lock can
  never touch another lock's funds or fees. For V3/V4 locks, `collectFees()` sends the
  position's trading fees to the owner while it stays locked.
- **Vesting** - `createVestingLock` locks a fungible token and releases it **linearly with an
  optional cliff** to the lock owner via `release()`, between a `start` and `end`. It's
  **irrevocable** (no creator clawback) and fee-on-transfer safe (payouts are clamped to the
  lock's live balance). A cliff of `start` gives pure linear vesting.
- **`TitanLockerManagerV2.sol`** - factory + registry for all lock kinds. `createTokenLock`
  for ERC20/V2-LP, `createVestingLock` for vesting, `createPositionLock` for V3/V4. Reuses
  V1's fee model (V3/V4 locks pay the flat ETH fee only). V3/V4 position managers must be
  **owner-allowlisted**
  (`setPositionManager`) before use - this is both the per-chain enablement mechanism and a
  kill-switch that keeps any un-validated integration disabled until verified.
- **`ITitanLockerManagerV2.sol`**, **`interfaces/`** - the manager interface plus minimal
  Uniswap V3 NonfungiblePositionManager / V4 PositionManager interfaces.

**Shared**

- **`Util.sol`** - shared token/LP inspection helpers
- **`Ownable.sol`** - single-owner access control with an overridable transfer hook
- **`test/*`** - test-only mocks (`TestERC20`, `MockUniswapV2Pair`, a minimal ERC721 base
  and V3/V4 position-manager mocks), not part of the locker product itself

## Deployments

**Robinhood Chain** (chain ID `4663`)

| Contract | Address | Verified |
|---|---|---|
| `Util` | [`0x772279251b563028a32cD1505e3F2f8485C746D9`](https://robinhoodchain.blockscout.com/address/0x772279251b563028a32cD1505e3F2f8485C746D9) | ✅ [source](https://robinhoodchain.blockscout.com/address/0x772279251b563028a32cD1505e3F2f8485C746D9?tab=contract) |
| `TitanLockerManagerV1` | [`0x713E56CeE7060F01F710bF26Aff988264dcfb311`](https://robinhoodchain.blockscout.com/address/0x713E56CeE7060F01F710bF26Aff988264dcfb311) | ✅ [source](https://robinhoodchain.blockscout.com/address/0x713E56CeE7060F01F710bF26Aff988264dcfb311?tab=contract) |
| `TitanLockerManagerV2` | [`0x26b0654a0756dcd036d4e7215324f3d2be34d79e`](https://robinhoodchain.blockscout.com/address/0x26b0654a0756dcd036d4e7215324f3d2be34d79e) | on-chain bytecode == artifact (19,299 bytes) |

Verified source reflects the code as it was at deploy time (predates the
ASCII banner headers added afterward) - Solidity contracts are immutable, so
the verified source will always match whatever was actually deployed.
Comment-only differences don't affect logic, but do change the embedded
metadata hash, so re-verifying with a newer source snapshot isn't possible
without redeploying.

Owner / fee receiver: `0x5C773302FBEED11fA59a6939f0354678738B02DB`. Current fee schedule:
0.05 ETH flat, or 3% of the deposited token if paid in-kind (both owner-adjustable).

Manually verified end-to-end on this live deployment (both fee paths, both
sides of the unlock-time gate, real transactions) - see
[TEST_REPORT.md](./TEST_REPORT.md) for the full writeup with linked tx hashes.

**Titan Locker V2 is deployed and live** at
[`0x26b0654a0756dcd036d4e7215324f3d2be34d79e`](https://robinhoodchain.blockscout.com/address/0x26b0654a0756dcd036d4e7215324f3d2be34d79e)
(deploy tx [`0xe09a…0fecd`](https://robinhoodchain.blockscout.com/tx/0xe09a40e30f200a8fd89d9f8362f31ed418943dd14b128c1859bda4fd37e0fecd),
block 5,851,744), as a fresh deploy alongside the unchanged V1. Its on-chain
runtime bytecode is an **exact match to the compiled artifact** (19,299 bytes),
and it was **verified end-to-end with real transactions** - ERC-20 locking (both
fee paths), linear vesting create → partial release → full release, and
post-unlock withdrawal. Full writeup with linked tx hashes:
**[TEST_REPORT_V2.md](./TEST_REPORT_V2.md)**.

Uniswap **V3/V4 LP** locking is not exercisable on Robinhood Chain (it has no
Uniswap V3/V4). On chains that do, enable it by owner-allowlisting the position
manager with `scripts/setPositionManagers.js`; the V4 fee-collection path should
be fork-validated against the real `PositionManager` before allowlisting it in
production - the allowlist keeps it disabled until then.

## Security

Every contract in this repo has been run through a full stack of independent static
analysis, symbolic execution, and fuzz-testing tools, plus a manual line-by-line review.
Nothing here has been through a paid third-party audit yet - treat these results as a
strong pre-audit baseline.

The table below is the V1 baseline; the [V2 results](#v2-security-results) follow it.

| Tool | What it does | Result |
|---|---|---|
| **Slither** (Trail of Bits) | Static analysis across 101 detectors | 1 real High finding found and fixed (unchecked ERC20 transfer return values → switched to OpenZeppelin's `SafeERC20` everywhere); re-verified clean afterward - **0 unaddressed High/Medium findings** |
| **Aderyn** (Cyfrin) | Rust-based static analysis, 63 detectors | 4 "High" findings raised, all confirmed false positives on inspection (caller-sourced transfers, an interface stub, an intentional zero-init counter, an already-present `withdrawEth`); 1 real Low finding fixed (zero-address guard added to `Ownable.transferOwnership`) - **0 unaddressed High/Medium findings** |
| **Mythril** (ConsenSys) | Symbolic execution, 17 detectors, 5-minute budget per contract | **0 findings** across every contract that produces bytecode |
| **Foundry** fuzz + invariant tests | Property-based testing with `forge`, 256 runs per test | 11 fuzz tests + 3 invariants (custody safety, fee-cap enforcement, no phantom balances) - **14/14 passing** |
| **Echidna** (Trail of Bits) | Property-based fuzzing campaign | 20,211 calls across fee-math, unlock-time monotonicity, withdrawal timing, and owner-only access control - **zero counterexamples** |
| **Halmos** (a16z) | Symbolic testing - proves properties for *every* possible input, not samples | 8 properties proven across the full input space (fee-cap boundary, exemption logic, owner-only gating, deposit accounting) - **8/8 proven, 0 counterexamples** |
| **Solidity Coverage** | Line/branch/function coverage of the JS/Mocha test suite | 51 tests - **92.6% statements, 97.5% functions, 94.0% lines** |
| **`yarn audit`** | Dependency vulnerability scan | **0 critical, 0 high** (remaining 17 low/moderate findings live entirely in transitive dev-tooling - Solidity compilation/testing infrastructure never reachable from the deployed contracts, not `contracts/` itself) |

**Manual review notes** (a few trust-model properties worth knowing explicitly, not bugs):
- The manager contract never custodies user funds even transiently - both the fee
  portion and the locked portion move directly from the depositor to their final
  destination in the same transaction (confirmed by Foundry's
  `invariant_managerNeverHoldsLockedToken`).
- `TitanLockerManagerV1`'s owner can adjust the token-fee percentage up to 100% and the
  flat ETH fee to any value going forward - this only affects *new* locks created after
  the change, never existing ones, and is a deliberate admin capability rather than an
  oversight.
- If the manager's owner key were ever lost, existing locks are entirely unaffected -
  each lock has its own independent owner and functions (deposit/withdraw/rescue) with
  no dependency on the manager's admin key.
- Deflationary/fee-on-transfer tokens are handled safely: every balance the contracts
  report or act on is a live `balanceOf` read, never a stored nominal amount, so no
  accounting can drift out of sync with reality.

### V2 security results

V2 was put through the same stack. Results:

| Tool | Result |
|---|---|
| **Hardhat/Mocha** | **90 passing** total (V1 parity + V2: ERC20, V3/V4 create→collect→withdraw, allowlist gating, cross-lock fee-claim isolation, stray-NFT rescue, and vesting: cliff/linear release, schedule validation, kind guards) |
| **Foundry** fuzz + invariant | **28/28** total. Adds `invariant_feeClaimIsolation`, `invariant_managerHoldsNothing`, and `invariant_vestingNeverOverReleases` (cumulative released ≤ the grant), plus vesting fuzz (vested is monotonic, bounded by total, and never over-releases) - each invariant exercised over 25,600 calls |
| **Halmos** | **18/18 proven** total (V2 + vesting: fee-math parity, allowlist owner-gating/kind validation, unlock-time gate, owner-only `withdraw`/`collectFees`/`release`, and `vested ≤ total` over the time domain) |
| **Mythril** | **0 findings** on both `TitanLockerManagerV2` and `TitanLockerV2` |
| **Slither / Aderyn** | Only informational findings and the **same false-positive classes as V1** (caller-sourced `from`, an interface stub, an intentional zero-init counter, ETH sent only to the owner-set fee receiver / `onlyOwner`) - 0 unaddressed High/Medium |

**The anti-rug property, stated plainly:** because every lock is its own contract holding
one asset with an immutable tokenId and `onlyOwner` on `collectFees`/`withdraw`, no lock can
ever pull another lock's fees or principal. This is enforced structurally (no shared vault,
no ledger to get wrong) and proven by the `feeClaimIsolation` fuzz test and invariant.

**Not run for V2:** Echidna. In the current toolchain (`crytic-compile` on Python 3.14) its
compile step crashes on a NatSpec-serialization bug unrelated to the contracts; the same
properties are covered by the Foundry invariants and Halmos. It can be re-enabled once the
`crytic-compile` toolchain is pinned/patched.

## Development

```bash
yarn install
yarn chain        # local Hardhat node, in one terminal
yarn deploy        # deploy Util + a test token + the locker(s), in another
yarn test          # Hardhat/Mocha suite (V1 + V2)
yarn coverage      # solidity-coverage report

forge test         # Foundry fuzz + invariant suite (V1 + V2)
FOUNDRY_PROFILE=halmos halmos --forge-build-out out-halmos   # symbolic proofs
```

Deploying V2: `03_deploy_locker_v2.js` deploys the V2 manager. After deploy, run
`scripts/setPositionManagers.js` to allowlist the V3/V4 position managers for the
target chain (it refuses any address with no contract code as a safety check).

## FAQ

**What is Titan Locker?**
Titan Locker is an open-source (GPL-3.0), immutable EVM smart-contract suite for **locking tokens and liquidity** and for **linear token vesting**. It supports ERC-20 tokens, Uniswap V2 LP tokens, Uniswap V3/V4 LP positions (NFTs), and time-based vesting.

**Is Titan Locker V2 deployed and live?**
Yes — `TitanLockerManagerV2` is live on **Robinhood Chain (chain ID 4663)** at [`0x26b0654a0756dcd036d4e7215324f3d2be34d79e`](https://robinhoodchain.blockscout.com/address/0x26b0654a0756dcd036d4e7215324f3d2be34d79e), verified end-to-end on-chain — see [TEST_REPORT_V2.md](./TEST_REPORT_V2.md).

**Is Titan Locker upgradeable?**
No. The contracts are **immutable / non-upgradeable** — plain constructors, no proxy, no `delegatecall`, no admin upgrade path. New versions are separate deployments; existing locks are never affected.

**How does the vesting work?**
Linear vesting: `vested = total × (now − start) / (end − start)`, with nothing released before the optional **cliff** and the full amount at/after `end`. Grants are **irrevocable**, release only to the lock owner, and can **never over-release** (payouts clamp to the live balance).

**Can the contract owner seize locked funds or shorten a lock?**
No. Each lock is an isolated child contract. The manager owner cannot move locked assets, cannot reduce an unlock time (extensions are increase-only), and cannot alter existing locks. Admin settings affect only new locks.

**How is one lock isolated from another?**
Every lock is its own contract holding exactly one asset, with owner-only value-moving functions. One lock can never touch another lock's balance or fees — proven by a Foundry invariant over 25,600 calls and confirmed by adversarial review.

**Which networks are supported?**
Any EVM chain. ERC-20 locking and vesting work everywhere; Uniswap V3/V4 LP locking is enabled per chain by owner-allowlisting that chain's canonical position manager.

## License

GPL-3.0-or-later - free and open source. Anyone may use, modify, and fork this code,
including for commercial purposes, as long as derivative works distributed to others
stay under the same license. See [LICENSE](./LICENSE) for the full text.
