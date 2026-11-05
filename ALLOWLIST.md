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
enum LockKind { ERC20, UNIV3, UNIV4, ERC20_VESTING, INFINITY_CL }

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
| Uniswap **v3** | `UNIV3` | [`0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3`](https://robinhoodchain.blockscout.com/address/0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3) | `symbol() == "UNI-V3-POS"`, 47k+ positions minted (canonical; the look-alike clones have 0–2) | ✅ allowlisted ([tx](https://robinhoodchain.blockscout.com/tx/0xf6d51162aab0236332d2c517ce03d6414a7bed3085355696cff5a8db3afd5b69)) |
| Uniswap **v4** | `UNIV4` | [`0x58daec3116aae6d93017baaea7749052e8a04fa7`](https://robinhoodchain.blockscout.com/address/0x58daec3116aae6d93017baaea7749052e8a04fa7) | `poolManager() == 0x8366a39CC670B4001A1121B8F6A443A643e40951` (matches Uniswap's published v4 PoolManager) | ✅ allowlisted ([tx](https://robinhoodchain.blockscout.com/tx/0x5a1d65ae1616023f5d647a5058afd7ad604ff6b73eea293d04c402668953f1a0)) |

### Robinhood V2.2 additions

The existing V2/V2.1 managers do not support `INFINITY_CL`. These rows describe
the live V2.2 manager at
[`0x5fa3f3Ca0c497b22ccd360aAe8423738D1825Fe9`](https://robinhoodchain.blockscout.com/address/0x5fa3f3Ca0c497b22ccd360aAe8423738D1825Fe9) only. The release script is
`scripts/setPositionManagersV2_2.js` and targets its separate deployment record.

| Protocol | Kind | Position manager | Status |
|---|---|---|---|
| SushiSwap V3 | `UNIV3` | [`0x51d0e5188afe12d502e29D982d20C190e7816107`](https://robinhoodchain.blockscout.com/address/0x51d0e5188afe12d502e29D982d20C190e7816107) | Allowlisted on V2.2; fork tested |
| PancakeSwap V3 | `UNIV3` | [`0x46A15B0b27311cedF172AB29E4f4766fbE7F4364`](https://robinhoodchain.blockscout.com/address/0x46A15B0b27311cedF172AB29E4f4766fbE7F4364) | Allowlisted on V2.2; fork tested |
| SushiSwap V4 CL | `INFINITY_CL` | [`0xd3d35fBc4E44523CA3cD383C1948322Ddb42F644`](https://robinhoodchain.blockscout.com/address/0xd3d35fBc4E44523CA3cD383C1948322Ddb42F644) | Allowlisted on V2.2; fork tested |
| PancakeSwap Infinity CL | `INFINITY_CL` | [`0xeaEA9253A0b75B936a965DbD35B2a3F01831DE74`](https://robinhoodchain.blockscout.com/address/0xeaEA9253A0b75B936a965DbD35B2a3F01831DE74) | Allowlisted on V2.2; fork tested |

SushiSwap's official [V3 configuration](https://github.com/sushi-labs/sushi/blob/3f6938e2970c3f930b9dfd522a0846258eed0ba8/src/evm/config/features/sushiswap-v3.ts) and [V4 CL deployment manifest](https://github.com/sushi-labs/infinity-deployments/blob/main/chains/robinhood-mainnet.json), and PancakeSwap's official [V3](https://github.com/pancakeswap/pancake-developer/blob/master/docs/pages/contracts/v3/addresses.md) and [Infinity](https://github.com/pancakeswap/pancake-developer/blob/master/docs/pages/contracts/infinity/resources/addresses.mdx) tables identify these position managers.

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
