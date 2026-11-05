# Titan Locker V2.2 release candidate

This branch starts from public commit `d880ce0f8e7ffd723ec845b182bebdcf3fc379c5` and patches four findings in the V2.1 manager and child. The deployed Robinhood manager and existing immutable locks are unchanged.

| Finding | Patch |
| --- | --- |
| TITAN-00 | NFT rescue rejects the locked asset's own collection for token and vesting locks, blocking the linked NFT/ERC20 early-withdrawal path. |
| TITAN-01 | The owner can recover only vesting surplus after the schedule ends, with an unpaid-grant reserve check. |
| TITAN-02 | V4 fee claims can carry owner-supplied hook data while the locker fixes the action, token ID, and payout recipient. The original no-argument call remains available. |
| TITAN-03 | Token and vesting creation revert if a rounded in-kind fee would leave no deposit. |

Run `forge test --summary` and `npx hardhat test --network hardhat` for local regressions. To run the read-only Kinetiq Elysium testnet fork cases, set `FOUNDRY_PROFILE=elysium` and run `forge test --fork-url https://testnet-rpc.elysium.kinetiq.xyz --match-contract ElysiumForkSmoke -vv`. The separate real Uniswap V4 integration harness and full audit details remain in the sibling `titan-audit` directory.

The [mainnet release manifest](deployments/elysium-mainnet.release.json) intentionally has no chain ID, owner, receiver, fees, or deployed manager. Once Kinetiq publishes its official mainnet details and the release values are reviewed, run `node scripts/elysium-mainnet-preflight.js predeploy`, then its `postdeploy` stage after deployment and configuration. The script is read-only; it cannot establish production readiness by itself. A new manager starts with creation enabled and 0.2 HYPE / 500 bps fees until its owner changes them. Verify the exact deployed child runtime and complete mainnet end-to-end checks before enabling public use. Do not allowlist a V3/V4 position manager until its Elysium deployment and compatibility are confirmed.

The [custody and hook review](CUSTODY_REVIEW.md) covers the unlock boundary, rescue paths, actual V4 callback attacks, and the remaining hooked-pool fee-claim limitation. Allowlisting a V4 PositionManager does not restrict its pools or hooks.
