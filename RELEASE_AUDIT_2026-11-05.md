# Titan Locker V2.2 release review — 5 November 2026

## Decision

**Do not deploy or announce production readiness yet.** This review found no
unresolved direct drain of a lock in the new code under the tested assumptions,
but that is not a zero-vulnerability guarantee. The new Sushi/Pancake CL adapter
and release scripts still need an independent security review and a final
deployment rehearsal. Existing immutable Robinhood V1/V2.1 locks have separate
legacy risks that a new manager cannot fix.

No live transaction was sent during this review. GitHub PRs #3 and #4 are
merged; [draft PR #5](https://github.com/titan-ecosystem/Titan-Locker-Contracts/pull/5)
contains the handover fix and remains unmerged pending this release review.

## Robinhood position managers (chain 4663)

| Protocol | Position NFT | V2.2 kind | Evidence |
|---|---|---|---|
| Uniswap V3 | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` | `UNIV3` (1) | Existing integration; on-chain code present |
| Uniswap V4 | `0x58daec3116aae6d93017baaea7749052e8a04fa7` | `UNIV4` (2) | Existing integration; on-chain code present |
| SushiSwap V3 | `0x51d0e5188afe12d502e29D982d20C190e7816107` | `UNIV3` (1) | NFT name/factory/code checked; real NFT fork test |
| PancakeSwap V3 | `0x46A15B0b27311cedF172AB29E4f4766fbE7F4364` | `UNIV3` (1) | [Official address list](https://github.com/pancakeswap/pancake-developer/blob/master/docs/pages/contracts/v3/addresses.md), factory/code checked; real NFT fork test |
| SushiSwap V4 CL | `0xd3d35fBc4E44523CA3cD383C1948322Ddb42F644` | `INFINITY_CL` (4) | [Official deployment manifest](https://github.com/sushi-labs/infinity-deployments/blob/main/chains/robinhood-mainnet.json), code/pool-manager checked; real NFT fork test |
| PancakeSwap Infinity CL | `0xeaEA9253A0b75B936a965DbD35B2a3F01831DE74` | `INFINITY_CL` (4) | [Official address list](https://github.com/pancakeswap/pancake-developer/blob/master/docs/pages/contracts/infinity/resources/addresses.mdx), code/pool-manager checked; real NFT fork test |

Only position NFT managers belong on the allowlist. Pool managers, factories,
routers, and the Elysium Inbox are different contracts. Pancake/Sushi CL expose
a six-field pool key; Uniswap V4 uses five fields. Registering either CL manager
as `UNIV4` would break the fee-claim path, so V2.2 adds an explicit
`INFINITY_CL` branch. The enum value is appended, preserving all existing kind
numbers. V2/V2.1 deployed contracts do not gain this feature.

## Custody and adversarial checks

- Each position NFT is held by its own child locker. The immutable NFT address,
  token ID, and lock kind are never chosen by a hook during fee collection.
- Fees can be claimed before maturity, but `withdraw` and `withdrawTo` still
  reject early principal release. After maturity, a failing fee claim is not
  required for NFT withdrawal.
- `collectFeesTo` gives only the lock owner a recipient choice, allowing a
  contract owner that rejects native transfers to claim fees. It does not
  permit a third party to collect fees or transfer the NFT.
- Existing hostile-hook tests show callback attempts to reenter fee collection,
  withdraw, rescue the locked NFT, or steal ownership fail. A hook may still
  veto its own pool's fee collection or affect pool economics; Titan cannot
  guarantee every third-party hook will behave honestly.
- Owner-index handovers no longer scan attacker-grown address buckets. The
  bounded-gas regression fails on the previous implementation and passes with
  the fix. Existing V2.1 child lockers still use their original manager.

## Verification performed

- 69 Foundry tests including fuzz/invariants and fee reproductions: pass.
- 93 Hardhat local end-to-end tests: pass.
- Six Robinhood fork tests with real Sushi V3, Pancake V3, Sushi V4 CL, and
  Pancake Infinity CL NFTs: pass using Cancun EVM. Each verifies NFT custody,
  fee claim, early-withdrawal rejection, and matured withdrawal; a separate
  test verifies redirecting native fees for a contract owner.
- One Elysium chain 99901 read-only fork test: pass for 1 HYPE flat fee,
  5% token fee, vesting, and matured withdrawal.
- Slither: no newly identified actionable High/Medium production-contract
  finding. Its High/Medium items are test mocks, deliberate uninitialized
  dynamic arrays, and ignored tuple fields. Aderyn 0.1.9 crashed while
  resolving this repository (`StripPrefixError`), so it did not provide an
  independent result for this revision.
- Compiled runtime sizes: manager 22,898 bytes; child locker 12,500 bytes,
  both below the EIP-170 24,576-byte limit. JavaScript release scripts pass
  syntax checks; the release action paths have not been used on a live chain.

The fork must use Cancun execution rules. Initial tests under the repository's
London compiler target produced a Pancake token-transfer revert and could not
execute the newer CL managers. Repeating those exact flows under Cancun passed.
The earlier suggestion that low pool token balances caused the revert was not
established and is withdrawn. Compiling Titan to London bytecode is compatible
with executing it on a Cancun chain.

## Remaining release gates and live legacy exposure

1. Obtain independent review of the newly added CL adapter, recipient-choice
   fee claim, and deployment/configuration scripts. The tests establish known
   cases, not absence of all vulnerabilities.
2. Rehearse V2.2 deployment/configuration on a current Robinhood fork, verify
   the resulting manager and child runtime bytecode, fee receiver, 0.025 ETH
   flat fee, 3% token fee, and all six allowlist entries before any live use.
   The new scripts are gated and have not sent transactions.
3. Confirm the product UI and docs accept kind 4 and display the four new
   position managers correctly. The contracts alone do not change the UI.
4. Decide how to handle live legacy managers. Robinhood V1 creation remains
   enabled and permits a 100% owner-set token fee without a caller cap.
   Existing V2.1 contract-owned NFT locks remain subject to the conditional
   handover-index gas grief reported in
   [the addendum](./SECURITY_ADDENDUM_2026-11-05.md). Neither contract is
   upgradeable; a new V2.2 manager does not repair old child lockers.
5. For Elysium, the supplied Rollup and bridge addresses are not LP position
   managers. Keep its LP allowlist empty until official managers are verified.
   Its child chain is 99901 and its parent is HyperEVM 999; actual deployment
   must go through the parent Inbox. The parent wallet balance was below the
   estimated Inbox cost at the last read-only check. Deployment remains paused.

No test suite can honestly establish "zero bugs" or "zero vulnerabilities."
The appropriate release claim is that the listed paths have passed the stated
checks and the remaining gates have been closed.
