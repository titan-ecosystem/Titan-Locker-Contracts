# Position-Manager Allowlist — Titan Locker V2

Titan Locker V2 can lock **Uniswap V3 and V4 liquidity positions** (ERC-721 NFTs) and
let the locker keep claiming the position's trading fees while the principal stays
locked. To do that safely, the lock contract has to **call functions on the position
manager** (`collect` on V3, `modifyLiquidities` on V4) and read the position's
`token0`/`token1`.

Because a chain can contain many contracts that *claim* to be a position manager
(Robinhood Chain alone has several look-alike "NonfungiblePositionManager" clones),
Titan Locker V2 only interacts with position managers the **contract owner has
explicitly allowlisted**. This is the anti-rug guarantee working as intended: the
contract never calls code on an unvetted address.

- **This is per-protocol, not per-user.** Once a protocol's position manager is
  allowlisted, **any** user can lock **any** of their positions from it — no further
  approval needed.
- Plain ERC-20 and Uniswap V2 LP-token locks and vesting do **not** use this list —
  they work with any token, because the contract only does standard `transfer` /
  `transferFrom`.
- The allowlist is controlled by `setPositionManager(address, LockKind, bool)`
  (`onlyOwner`) and is reversible.

```solidity
enum LockKind { ERC20, UNIV3, UNIV4, ERC20_VESTING }

// TitanLockerManagerV2
function setPositionManager(address positionManager, LockKind kind, bool allowed) external onlyOwner;
function positionManagerKind(address positionManager) external view returns (LockKind kind, bool allowed);
```

---

## Allowlisted position managers

### Robinhood Chain — chain id `4663`

Manager: `TitanLockerManagerV2` at
[`0x26b0654a0756dcd036d4e7215324f3d2be34d79e`](https://robinhoodchain.blockscout.com/address/0x26b0654a0756dcd036d4e7215324f3d2be34d79e)

| Protocol | Kind | Position manager | Verification | Status |
|---|---|---|---|---|
| Uniswap **v3** | `UNIV3` | [`0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3`](https://robinhoodchain.blockscout.com/address/0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3) | `symbol() == "UNI-V3-POS"`, 47k+ positions minted (canonical; the look-alike clones have 0–2) | ⏳ pending owner tx |
| Uniswap **v4** | `UNIV4` | [`0x58daec3116aae6d93017baaea7749052e8a04fa7`](https://robinhoodchain.blockscout.com/address/0x58daec3116aae6d93017baaea7749052e8a04fa7) | `poolManager() == 0x8366a39CC670B4001A1121B8F6A443A643e40951` (matches Uniswap's published v4 PoolManager) | ⏳ pending owner tx |

> Source of truth is always the on-chain state: read `positionManagerKind(pm)` on the
> manager. This table is a human-readable mirror. When the owner sends the allowlist
> transaction, flip **Status** to ✅ and link the tx.

Owner command to allowlist an entry:

```bash
RPC="<robinhood-chain-rpc>"
V2=0x26b0654a0756dcd036d4e7215324f3d2be34d79e
# kind: 1 = UNIV3, 2 = UNIV4
cast send "$V2" "setPositionManager(address,uint8,bool)" <POSITION_MANAGER> <KIND> true \
  --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY"
```

---

## Request an addition (open a PR)

Building on another EVM chain, or want a different AMM's position manager supported?
**Anyone can propose an addition** — the owner reviews it and, if it checks out,
allowlists it on-chain and merges your PR.

1. **Fork** this repo and edit the table above: add a row with your protocol, chain
   id, position-manager address, `LockKind` (`UNIV3` or `UNIV4`), and how it can be
   verified.
2. **Prove it's the canonical contract.** Include at least one of:
   - a link to the AMM's **official docs / deployments page** listing that address, and
   - an **on-chain check** — e.g. `symbol()` for a V3-style NFT, or `poolManager()`
     matching the AMM's published pool manager for a V4-style one.
3. **Confirm the interface.** It must expose the Uniswap-**v3** `collect` /
   `positions` interface (`UNIV3`) or the Uniswap-**v4** `modifyLiquidities` /
   `PositionManager` interface (`UNIV4`). Other interfaces aren't supported by the
   fee-claim path and won't be allowlisted.
4. **Open the PR** using the *"Add a position manager to the allowlist"* template.

The owner will verify the address, send the `setPositionManager` transaction, update
the row's **Status** to ✅ with the tx link, and merge. Nothing about the deployed
contracts changes — only the on-chain allowlist mapping and this document.

> ⚠️ Safety note: an allowlisted position manager is **called** by every lock created
> against it. Only contracts whose source is verified and whose behaviour matches the
> Uniswap V3/V4 interface are eligible. Requests for unverified or non-standard
> contracts will be declined.
