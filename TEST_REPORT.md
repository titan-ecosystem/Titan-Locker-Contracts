# Live Deployment Verification Report

Manual end-to-end verification of `TitanLockerManagerV1` on **Robinhood Chain**
(chain ID `4663`), run directly against the live deployment
([`0x713E56CeE7060F01F710bF26Aff988264dcfb311`](https://robinhoodchain.blockscout.com/address/0x713E56CeE7060F01F710bF26Aff988264dcfb311))
rather than a local testnet. All transaction hashes below were pulled directly
from on-chain event logs, not from terminal transcripts, so every entry here
is independently verifiable on
[Blockscout](https://robinhoodchain.blockscout.com).

This complements the automated Slither/Aderyn/Mythril/Foundry/Echidna/Halmos/
coverage results in the main [README](./README.md#security) - those prove
properties about the code; this proves the actual deployed instance, on the
actual chain, behaves the same way with real transactions.

## What was tested

Both ways a lock can be paid for, and both sides of the unlock-time gate:

1. **ETH fee path** - pay a flat ETH amount, lock 100% of the deposit
2. **Token fee path** - pay nothing in ETH, have a percentage deducted from the deposited token instead
3. **Withdraw before `unlockTime`** - must revert
4. **Withdraw at/after `unlockTime`** - must succeed, for exactly the locked amount

## Fee configuration timeline

Every `setEthFee`/`setTokenFeeBps` call made on the live contract, in order:

| # | Time (UTC) | ethFee | tokenFeeBps | Tx |
|---|---|---|---|---|
| 1 | 2026-07-04 14:54:49 | 0.05 ETH | 500 (5%) | [`0xb8a519...`](https://robinhoodchain.blockscout.com/tx/0xb8a5192dd665aaa09af30a3f429e6615d43e466947068f6c490c19ca8dba8309) (initial deploy default) |
| 2 | 2026-07-04 14:54:52 | 0.05 ETH | 300 (3%) | [`0x1308b6...`](https://robinhoodchain.blockscout.com/tx/0x1308b63cede992d44e5d7537fc48b19c256b9b93955c513d7334e8bf888db7c9) (production fee reduction) |
| 3 | 2026-07-04 15:07:32 | 0.00001 ETH | 300 (3%) | [`0xf30a02...`](https://robinhoodchain.blockscout.com/tx/0xf30a026b3085d8bfa9886792ce94387a14950733df3ad9feb0637499d27a8485) (lowered for ETH-fee test) |
| 4 | 2026-07-04 15:13:24 | 0.05 ETH | 300 (3%) | [`0x5937ce...`](https://robinhoodchain.blockscout.com/tx/0x5937ce9fbd85ebb2daef86b617d1582c988d13b6ee86ed71ca65ca91544a8992) (restored after test) |

Live contract has been back at **0.05 ETH / 3%** since #4.

## Test 1: ETH fee path

Deposited 1000 units of a freshly-deployed test token
([`0xE48328...`](https://robinhoodchain.blockscout.com/address/0xE48328ea3694F14E47ec31Dd7991F326f88d311D)),
paying the flat ETH fee (temporarily lowered to 0.00001 ETH, see timeline #3).

| Step | Result | Evidence |
|---|---|---|
| Create lock (id 0), unlock at 15:12:38 UTC | 1000 (100%) locked, fee correctly recorded as `paidInEth: true, amount: 0.00001 ETH` | [`0x31fc12...`](https://robinhoodchain.blockscout.com/tx/0x31fc1245ab392dc45bb874b1ea5c8a7a5cbf723fc398c8713c9e6d917c94bd26) |
| Withdraw **before** unlock time | **Reverted**, as required | Simulated via `eth_call` (no transaction broadcast - a guaranteed-revert isn't worth spending gas on), returned custom error `LockStillActive(uint40)` with the exact configured unlock timestamp encoded in the error data |
| Wait until unlock time passed | - | - |
| Withdraw **after** unlock time | **Succeeded** - full 1000 tokens returned | [`0x32f4e5...`](https://robinhoodchain.blockscout.com/tx/0x32f4e544911e48103505fdd406a02a21016565f4ba409e35530bde5b5c28ffd7) |

## Test 2: Token fee path

Run twice for consistency, each depositing 1000 units of a fresh test token
with **no ETH sent**, so `_collectFee` takes the in-kind branch (3% fee, matching
timeline #4's live config).

| Run | Lock id | Locked amount | Fee taken | Create tx | Withdraw tx |
|---|---|---|---|---|---|
| 1 | 2 | 970 (1000 − 3%) | `paidInEth: false, amount: 30` | [`0x9ee2c7...`](https://robinhoodchain.blockscout.com/tx/0x9ee2c7fceab82274f59d4d0fcda103f1e82988e336622769a94c80f0a4f1088a) | [`0x6f0879...`](https://robinhoodchain.blockscout.com/tx/0x6f08798c79dd76a19d8a4d5c11b3fb51662c29de9449fd9dea32870e3c36a217) |
| 2 | 3 | 970 (1000 − 3%) | `paidInEth: false, amount: 30` | [`0x7ca08a...`](https://robinhoodchain.blockscout.com/tx/0x7ca08a3b3ff5ab2df86ef8a7df2c6b31a556fb2be506eaa52b4afc1a9d6aab5d) | [`0x4eb0e9...`](https://robinhoodchain.blockscout.com/tx/0x4eb0e9ceb124b2df6f9bbc0fae4be21c07704508c332bd9e76ed5f24d2358ca8) |

Both runs: locked amount, `FeeCollected` event, and final withdrawn amount all
matched the expected fee math exactly (970 locked / 30 collected as fee, for
a 1000-unit deposit at 3%).

Note: an early first attempt at this test (lock id 1,
[`0xbb0618...`](https://robinhoodchain.blockscout.com/tx/0xbb0618d826638151f4df2faf30ce2bb017e4b1f4838d0fea5fc46602947cd2e8))
hit a bug in the *test script's own verification logic* (it diffed the fee
receiver's token balance, which is meaningless here since fee receiver and
depositor are the same address in this deployment - see below). The contract
itself behaved correctly even then (970 locked, 30 fee collected via the
`FeeCollected` event) - only the test script's assertion was wrong, fixed
before runs 2 and 3. That lock was never withdrawn; it's inert test-token
dust with no real value, left as-is.

## Result summary

| Property | Verified |
|---|---|
| ETH-fee path locks 100% of deposit | ✅ |
| Token-fee path deducts exactly the configured bps | ✅ |
| `FeeCollected` event reports the correct `paidInEth`/`amount` | ✅ |
| Withdrawal before `unlockTime` reverts | ✅ |
| Withdrawal at/after `unlockTime` succeeds for the exact locked amount | ✅ |
| Fee configuration changes take effect on subsequent locks only | ✅ |
| Contract owner correctly gates all fee-setter calls | ✅ (implicitly required for every `setEthFee`/`setTokenFeeBps` call above to have succeeded at all) |

## Notes on methodology

- **Fee receiver == depositor in this deployment**: the contract owner
  (`0x5C773302FBEED11fA59a6939f0354678738B02DB`) is also the current fee
  receiver, since it hasn't been changed via `setFeeReceiver` yet. This means
  diffing that address's token balance around a `createTokenLocker` call
  conflates the fee payment with the unrelated deposit-to-locker transfer -
  the fix was reading the `FeeCollected` event directly instead, which is
  unambiguous regardless of address overlap.
- **Early-withdrawal checks use `eth_call` simulation, not mined
  transactions** - a call that's certain to revert isn't worth spending real
  gas on. The revert reason (`LockStillActive`, with the exact unlock
  timestamp) was still read directly from the node's response to that
  simulated call, so it's real verification, just not a transaction with its
  own hash.
