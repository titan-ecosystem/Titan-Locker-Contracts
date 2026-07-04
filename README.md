# Titan Locker Contracts

![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)
![Solidity](https://img.shields.io/badge/solidity-0.8.30-363636?logo=solidity)
![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.6.1-4E5EE4)
![Tests](https://img.shields.io/badge/tests-51%20passing-brightgreen)
![Coverage](https://img.shields.io/badge/coverage-93%25%20lines-brightgreen)
![Slither](https://img.shields.io/badge/slither-clean-brightgreen)
![Aderyn](https://img.shields.io/badge/aderyn-clean-brightgreen)
![Mythril](https://img.shields.io/badge/mythril-clean-brightgreen)
![Foundry](https://img.shields.io/badge/foundry%20fuzz%2Finvariant-14%2F14%20passing-brightgreen)
![Echidna](https://img.shields.io/badge/echidna-20K%2B%20runs%2C%200%20failures-brightgreen)
![Halmos](https://img.shields.io/badge/halmos-8%2F8%20proven-brightgreen)
![npm audit](https://img.shields.io/badge/npm%20audit-0%20critical%2Fhigh-brightgreen)

Smart contracts for Titan Locker, an open source EVM token locker. Free to use, modify,
and fork by anyone under the GPL-3.0-or-later license below.

This is the contracts-only counterpart to the Titan Locker frontend. The 5 core locker
contracts (`TitanLockerV1`, `TitanLockerManagerV1`, `ITitanLockerManagerV1`, `Ownable`,
`Util`) are original implementations written for this project. The only third-party code
involved is `@openzeppelin/contracts` (a normal dependency, not vendored) and a small
vendored copy of Uniswap V2's public interfaces in `contracts/library/Dex.sol` - both
MIT-licensed.

## What's here

- **`TitanLockerV1.sol`** - a single token/LP-token lock with an owner-adjustable unlock time
- **`TitanLockerManagerV1.sol`** - deploys and indexes locks, and charges a creation fee
  paid either as a flat ETH amount or as a percentage of the deposited token (both
  owner-adjustable, with a fee-exempt allowlist)
- **`Util.sol`** - shared token/LP inspection helpers
- **`Ownable.sol`** - single-owner access control with an overridable transfer hook
- **`test/TestERC20.sol`**, **`test/MockUniswapV2Pair.sol`** - test-only mocks, not part
  of the locker product itself

## Security

Every contract in this repo has been run through a full stack of independent static
analysis, symbolic execution, and fuzz-testing tools, plus a manual line-by-line review.
Nothing here has been through a paid third-party audit yet - treat these results as a
strong pre-audit baseline.

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

## Development

```bash
yarn install
yarn chain        # local Hardhat node, in one terminal
yarn deploy        # deploy Util + a test token + the locker, in another
yarn test          # Hardhat/Mocha suite
yarn coverage      # solidity-coverage report

forge test         # Foundry fuzz + invariant suite
```

## License

GPL-3.0-or-later - free and open source. Anyone may use, modify, and fork this code,
including for commercial purposes, as long as derivative works distributed to others
stay under the same license. See [LICENSE](./LICENSE) for the full text.
