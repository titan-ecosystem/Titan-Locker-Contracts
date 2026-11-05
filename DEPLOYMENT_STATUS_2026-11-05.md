# Titan Locker release status — 5 November 2026

## Robinhood Chain (4663)

The regular `TitanLockerManagerV2_2` is deployed at
[`0x5fa3f3Ca0c497b22ccd360aAe8423738D1825Fe9`](https://robinhoodchain.blockscout.com/address/0x5fa3f3Ca0c497b22ccd360aAe8423738D1825Fe9).
Deployment transaction:
[`0xa92a4346d81a43f95418d480a24ec26b501537fbd1febfa7088620a9ca81a2b7`](https://robinhoodchain.blockscout.com/tx/0xa92a4346d81a43f95418d480a24ec26b501537fbd1febfa7088620a9ca81a2b7).
The 23,404-byte on-chain runtime matches the compiled release artifact exactly after
linking `Util` at `0xFBfa1ce526f98deC2251D44d1DaF7c599223aFe6`.
Runtime hash: `0xacb5a9c6d9bf89969a11091b31ae80415b4a5f5b7e8ffc1b179f35d0ea2b9e83`.

The owner and fee receiver are both
`0x5C773302FBEED11fA59a6939f0354678738B02DB`. The manager has lock creation
enabled, a 0.025 ETH flat fee, and a 300 bps token fee. The following position
managers were checked against live code and allowlisted: Uniswap V3/V4,
SushiSwap V3/V4 CL, and PancakeSwap V3/Infinity CL. The four SushiSwap/PancakeSwap
integrations also passed the local Robinhood fork custody, fee-claim, and
maturity-withdrawal tests before release.

The Robinhood contract is live, but the Titan app and public documentation must
be switched to this new address before app users create V2.2 locks. The older V1
and V2.1 managers still have lock creation enabled on-chain. Their existing locks
remain at their original immutable addresses. Explorer source verification and
a real production lock cycle against V2.2 have not yet been completed; the
bytecode comparison and local fork tests are the verification completed here.

## Kinetiq Elysium (99901)

The parent HyperEVM wallet was funded and the regular-locker preflight passed.
The `Util` creation transaction was posted to the official Inbox
`0xce59f8B65ad41C9DAE4c07A0571a39824bD92cff` on HyperEVM (999):

- Parent transaction (confirmed successfully):
  [`0x114e9e216a9e386890250df4c1f47ceb9a944f130bf8275623bdb5a114856ba7`](https://hyperevmscan.io/tx/0x114e9e216a9e386890250df4c1f47ceb9a944f130bf8275623bdb5a114856ba7)
- Signed child transaction hash (no Elysium receipt as of this report):
  `0x05f8b90cebf86a39abd9073c225699dca63c955fb41ae34b8ab1784a845a5def`

The script stopped after 20 minutes without a child receipt. It did **not** post
the manager deployment or fee/configuration transactions. The confirmed Inbox
message has delayed-message index 610,575, while the SequencerInbox reported
only 561,989 delayed messages read, unchanged across more than 16,000 parent
blocks during the check. The Elysium child RPC was producing current blocks but
did not show the signed creation transaction. The operator needs to restore or
confirm Inbox watcher and delayed-message processing before this deployment
can resume. The local `.elysium-inbox-state.json` (mode 0600, gitignored) retains
both hashes and nonce for safe resumption with
`node scripts/elysium-inbox-deploy.js execute`.

Elysium's approved LP position-manager list remains empty. The supplied official
addresses identify the rollup, Inbox, Bridge, and token gateways; none is a V3
or V4 LP position NFT manager. The regular locker can support ERC-20 locks and
vesting once its manager is deployed, but LP position creation remains disabled
until an actual position-manager contract is verified and allowlisted.

No finite audit or test suite can establish that a contract has zero bugs. This
release status records the checks performed and the remaining deployment gaps.
