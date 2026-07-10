<!--
  Use this template to propose adding a position manager to the Titan Locker V2
  allowlist. See ALLOWLIST.md for the full process. Open the PR, fill in every
  field, and the owner will verify + allowlist on-chain before merging.
-->

## Add a position manager to the allowlist

**Protocol / AMM:**
<!-- e.g. Uniswap v3 -->

**Chain:**
<!-- name + chain id, e.g. Robinhood Chain (4663) -->

**Position manager address:**
<!-- 0x... -->

**LockKind:**
<!-- UNIV3 or UNIV4 -->

**Titan Locker V2 manager on this chain:**
<!-- 0x... (the TitanLockerManagerV2 this should be allowlisted on) -->

### Proof this is the canonical contract
<!-- Provide at least one docs link AND one on-chain check. -->

- [ ] Link to the AMM's official docs / deployments page listing this address:
- [ ] Source is **verified** on the chain's block explorer (link):
- [ ] On-chain check:
  - For **UNIV3**: `symbol()` returns a V3-position symbol (e.g. `UNI-V3-POS`) and `factory()` is the AMM's V3 factory:
  - For **UNIV4**: `poolManager()` matches the AMM's published v4 PoolManager:

### Interface confirmation
- [ ] Exposes the Uniswap **v3** `collect` / `positions` interface (for `UNIV3`), **or**
- [ ] Exposes the Uniswap **v4** `modifyLiquidities` / `PositionManager` interface (for `UNIV4`)

### Allowlist table entry
<!-- Paste the row you added to ALLOWLIST.md -->

```
| <protocol> | <UNIV3|UNIV4> | `0x...` | <verification> | ⏳ pending owner tx |
```

---

- [ ] I updated the table in `ALLOWLIST.md`.
- [ ] I understand an allowlisted position manager is **called** by every lock created against it, so only verified, standard-interface contracts are eligible.
