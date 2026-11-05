# Titan Locker V2.2 release candidate

This branch starts from public commit `d880ce0f8e7ffd723ec845b182bebdcf3fc379c5` and patches four findings in the V2.1 manager and child. The deployed Robinhood manager and existing immutable locks are unchanged.

| Finding | Patch |
| --- | --- |
| TITAN-00 | NFT rescue rejects the locked asset's own collection for token and vesting locks, blocking the linked NFT/ERC20 early-withdrawal path. |
| TITAN-01 | The owner can recover only vesting surplus after the schedule ends, with an unpaid-grant reserve check. |
| TITAN-02 | V4 fee claims can carry owner-supplied hook data while the locker fixes the action, token ID, and payout recipient. The original no-argument call remains available. |
| TITAN-03 | Token and vesting creation revert if a rounded in-kind fee would leave no deposit. |

Run `forge test --summary` and `npx hardhat test --network hardhat` for local regressions. To run the read-only Kinetiq Elysium testnet fork cases, set `FOUNDRY_PROFILE=elysium` and run `forge test --fork-url https://testnet-rpc.elysium.kinetiq.xyz --match-contract ElysiumForkSmoke -vv`. The separate real Uniswap V4 integration harness and full audit details remain in the sibling `titan-audit` directory.

The [mainnet release manifest](deployments/elysium-mainnet.release.json) now pins chain 99901 after both the child RPC and HyperEVM Rollup reported that ID. It records the user-selected 1 HYPE flat fee and 500 bps token fee, with the supplied deployment wallet as owner and receiver. `node scripts/elysium-mainnet-preflight.js predeploy` checks the parent/child relationship, Inbox state, compiler build, and release values without signing or broadcasting. Run its `postdeploy` stage only after the deployed Util and manager addresses are recorded. A new manager starts with creation enabled and 0.2 HYPE / 500 bps fees until its owner changes them; configure and verify the 1 HYPE fee before exposing the new address to users. Elysium V3/V4 position managers remain unallowlisted because the supplied addresses are bridge contracts and gateways, not LP position managers. Verify a manager's deployed code and source before allowing LP locks.

The [custody and hook review](CUSTODY_REVIEW.md) covers the unlock boundary, rescue paths, actual V4 callback attacks, and the remaining hooked-pool fee-claim limitation. Allowlisting a V4 PositionManager does not restrict its pools or hooks.
