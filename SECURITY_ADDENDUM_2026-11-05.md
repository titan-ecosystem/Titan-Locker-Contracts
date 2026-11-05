# Titan Locker finding review — 5 November 2026

This records the initial M-01 through M-04 review. The later Sushi/Pancake
integration and current release decision are in
[RELEASE_AUDIT_2026-11-05.md](./RELEASE_AUDIT_2026-11-05.md).

This review covers the four claims in the supplied M-01 through M-04 note. It
also records the read-only Elysium deployment checks. No live transaction was
sent during this review.

## M-01: owner handover can be priced out by a third party — confirmed, conditional

`TitanLockerManagerV2.notifyLockerOwnerChange` searched both owner index arrays
linearly. Anyone could create dust locks and transfer them to a known handover
destination, growing its index without consent. A lock owned by a contract that
cannot receive ERC-721 tokens and can hand over only to that destination could
then be unable to return a matured V3/V4 position NFT. The exploit needs such a
restricted owner contract and enough attacker transactions to exceed the gas
available for its handover. We have **not** verified the note's claimed
mainnet-scale attack cost or found an already frozen live position.

The regression test creates 300 attacker-owned dust locks, transfers them to a
fixed project address, and invokes a restricted owner's handover under a
120,000-gas cap. It fails on the previous code and passes with this change.
Both removal from the old owner's bucket and insertion into the new bucket now
use one-based index-position mappings with constant-time swap removal.
Creator, asset, locker, and underlying-token search roles remain permanent.
`TitanLockerV2.withdrawTo` additionally lets an owner choose the recipient of
a matured ERC-20 or V3/V4 NFT. It preserves the existing ownership, lock-kind,
unlock-time, and reentrancy checks.

**Scope limit:** A newly deployed manager only protects locks created by that
manager. Existing Robinhood V2.1 child lockers still call the old manager and
cannot gain `withdrawTo`; a contract owner of one of those locks needs its own
working handover path. Neither the current manager nor its children are
upgradeable.

## M-02: legacy V1 can take 100% of a pending token lock — confirmed

V1 accepts a live `tokenFeeBps` of 10,000 without a caller-side maximum. A
local reproduction charges all 1,000 test units and creates a zero-balance
locker. Exploitation requires the V1 owner or a compromised owner key to change
the fee before the user's transaction is mined. The live Robinhood V1 manager
at `0x713E56CeE7060F01F710bF26Aff988264dcfb311` still reports
`creationEnabled=true` (read-only check), while the public contracts page calls
it read-only. Disabling creation on that **existing** manager would close new
exposure without altering old lockers; it is a separate live owner transaction.

## M-03: zero flat fee routes token locks to the percentage fee — confirmed

For V2, `_ethFee == 0` makes position creation free, but an ERC-20 or vesting
creator sending zero native currency takes the in-kind fee path. A local test
confirms a free V3 position lock and a 3% token-lock deduction under the same
fee settings. The retired Stable V2.1 manager at
`0x102a70bDA2C833b3483A2eE55C14c7ea0fb7A01B` reports `ethFee=0`,
`tokenFeeBps=300`, and `creationEnabled=true` (read-only checks). This is a fee
configuration and user-expectation issue, not a principal-drain path. New
deployments should set a nonzero flat fee if they intend to offer both payment
paths. The deployed Stable manager's code cannot be changed.

## M-04: tiny opening then fee-free top-up — confirmed behavior, documented policy

The supplied one-unit example no longer works on the patched V2.2 code: its
opening would leave zero locked and revert. A two-unit opening still pays one
token unit, locks one, and permits a 998-unit top-up without another fee. A
local reproduction confirms this. The published fee schedule explicitly says
top-ups cost gas only and the fee applies only to new locks. Charging for
top-ups would therefore be a product fee-policy change that also requires a
docs/UI update; the hardening patch does not change it.

## Elysium read-only deployment checks

The supplied parent RPC reports HyperEVM chain 999. The child RPC and the
HyperEVM Rollup `chainId()` both report Elysium chain 99901. The Inbox at
`0xce59f8B65ad41C9DAE4c07A0571a39824bD92cff` references the supplied
Bridge and SequencerInbox; it reports `paused=false` and
`allowListEnabled=false`. Its EIP-1967 implementation has code. The deployment
wallet had nonzero native balances on both chains at the time of the check.
The child RPC is suitable for reads and simulation; actual Elysium transactions
must be signed for chain 99901 and posted through HyperEVM's Inbox
`sendL2Message`, then confirmed on the child chain. No Inbox message was sent.
The updated read-only release preflight passed at Elysium block 646,848.
An Inbox deployment script has also passed its read-only preflight; its
transaction-sending mode has not been used. It must run from the merged clean
release branch and confirm each child receipt before advancing.
At the latest balance check the parent wallet held about 0.000027 HYPE, down
from about 0.00324 HYPE earlier in this review. An unsigned, all-nonzero
calldata simulation estimated about 149,694 parent gas for Util and 666,774
for the manager, before configuration transactions. The parent wallet needs
more HYPE before any Inbox deployment. The child wallet held 0.025 HYPE at
the same check. These are time-sensitive balances and gas estimates.

The Robinhood flat/token fee settings are 0.025 ETH / 3%. The owner selected
1 HYPE / 5% for Elysium. The supplied Elysium addresses are Rollup and bridge
contracts, not V3/V4 LP position managers. Uniswap's official V3 and V4
deployment lists do not currently include Elysium, so no position manager is
approved for the Elysium allowlist in this review. Any LP manager chosen later
must be verified against its deployed code and an authoritative source.

## Verification

- Focused M-01 test fails before the patch and passes after it.
- 65 Foundry tests tracked in draft PR #5, three additional local fee-finding
  reproductions, 93 Hardhat tests, and six integrations using the real
  Uniswap V4 position-manager source pass on the hardened code.
- One read-only Elysium mainnet fork test passes with 1 HYPE flat and 5% token
  fees across token, vesting, and maturity exits. This is local simulation,
  not an on-chain deployment.
- Runtime sizes remain under the EIP-170 24,576-byte limit: manager 20,834
  bytes; child locker 10,571 bytes.

The custody patch and release preflight are in
[draft PR #5](https://github.com/titan-ecosystem/Titan-Locker-Contracts/pull/5).
The fee finding reproductions and this report are retained locally for review.

Sources: Titan's [fee schedule](https://titanlocker.com/docs/fees-and-security),
[contracts page](https://titanlocker.com/docs/contracts), and Arbitrum's
[delayed Inbox documentation](https://docs.arbitrum.io/how-arbitrum-works/deep-dives/forced-transactions).
