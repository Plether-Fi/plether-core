# Perps Test DRY Refactor — Spec

## Problem
20+ test contracts across 12 files copy-paste the same 50-line setUp() block deploying MockUSDC, CfdEngine, HousePool, MarginClearinghouse, OrderRouter, and running timelock bypasses. Helper functions (_fundTrader, _fundJunior, _open, _close, _warpForward) are duplicated 5-7 times each. AuditFindings.t.sol alone has 7 duplicate setUp() definitions across 5 nested contracts.

## Architecture

### New files
- `test/perps/BasePerpTest.sol` — abstract base contract
- `test/mocks/MockPyth.sol` — extracted from OrderRouter.t.sol inline mock

### Files to refactor (inherit BasePerpTest)
- `test/perps/CfdEngine.t.sol`
- `test/perps/AuditC01C02C03.t.sol`
- `test/perps/TimelockPause.t.sol`
- `test/perps/Liquidation.t.sol`
- `test/perps/PerpInvariant.t.sol`
- `test/perps/AuditFindings.t.sol`
- `test/perps/HousePool.t.sol`
- `test/perps/OrderRouter.t.sol`

### Files left alone (no changes)
- `test/perps/MarginClearinghouse.t.sol` — tests clearinghouse in isolation, no engine/pool
- `test/perps/AuditH01H02.t.sol` — already well-structured with correct 6-dec mock
- `test/perps/CfdMath.t.sol` — pure math, no deployment
- `test/perps/CfdMathFuzz.t.sol` — pure math fuzz, no deployment

---

## BasePerpTest Design

### Maximal default deployment
`setUp()` deploys the full stack by default: usdc, clearinghouse, engine, pool, seniorVault, juniorVault, router. All timelock bypasses are handled automatically. Tests that need different behavior override virtual hooks.

### Contract state variables
```solidity
abstract contract BasePerpTest is Test {
    MockUSDC usdc;
    CfdEngine engine;
    HousePool pool;
    MarginClearinghouse clearinghouse;
    TrancheVault seniorVault;
    TrancheVault juniorVault;
    OrderRouter router;

    /// @dev Monday 2024-03-04 10:00 UTC. Avoids FAD window. All tests start here.
    uint256 constant SETUP_TIMESTAMP = 1_709_532_000;
    uint256 constant CAP_PRICE = 2e8;
}
```

### Virtual hooks for customization
```solidity
function _riskParams() internal pure virtual returns (CfdTypes.RiskParams memory);
// Default: vpiFactor=0, baseApy=0, maxApy=0, maintMarginBps=100, fadMarginBps=300,
// maxSkewRatio=0.4e18, kinkSkewRatio=0.25e18, minBountyUsdc=5e6, bountyBps=15

function _initialJuniorDeposit() internal pure virtual returns (uint256);
// Default: 1_000_000 * 1e6

function _initialSeniorDeposit() internal pure virtual returns (uint256);
// Default: 0 (most tests don't need senior LP)
```

### setUp() flow
1. Deploy usdc (shared MockUSDC from test/mocks/)
2. Deploy clearinghouse
3. Deploy engine with `_riskParams()`
4. Deploy pool, seniorVault, juniorVault
5. Deploy router (always real OrderRouter, with no Pyth / empty feeds)
6. `_bypassAllTimelocks()` — single function handles all propose/warp/finalize sequences for asset config, withdraw guard, engine operator, router operator
7. Warp to `SETUP_TIMESTAMP`
8. Fund junior vault with `_initialJuniorDeposit()` (if > 0)
9. Fund senior vault with `_initialSeniorDeposit()` (if > 0)

### Router strategy
Always deploy the real OrderRouter. Tests that call `engine.processOrder` directly use the `_open` / `_close` helpers which internally `vm.prank(address(router))`. Tests needing raw `processOrder` calls do manual `vm.prank(address(router))`.

### Shared helper functions

**Funding helpers:**
```solidity
function _fundJunior(address lp, uint256 amount) internal;
function _fundSenior(address lp, uint256 amount) internal;
function _fundTrader(address trader, uint256 amount) internal;
// Mints USDC, approves, deposits to clearinghouse via trader's accountId
```

**Trading helpers (auto-prank as router):**
```solidity
// With explicit depth
function _open(bytes32 accountId, CfdTypes.Side side, uint256 size, uint256 margin, uint256 price, uint256 depth) internal;
function _close(bytes32 accountId, CfdTypes.Side side, uint256 size, uint256 price, uint256 depth) internal;

// With auto depth = pool.totalAssets()
function _open(bytes32 accountId, CfdTypes.Side side, uint256 size, uint256 margin, uint256 price) internal;
function _close(bytes32 accountId, CfdTypes.Side side, uint256 size, uint256 price) internal;
```

**Governance helper:**
```solidity
function _setRiskParams(CfdTypes.RiskParams memory params) internal;
// propose + vm.warp(block.timestamp + 48 hours + 1) + finalize
```

**Time helper:**
```solidity
function _warpForward(uint256 delta) internal;
// Uses assembly to read timestamp (avoids Foundry caching)
```

### What does NOT go in the base
- FAD-specific timestamp constants (FRIDAY_18UTC, SATURDAY_NOON, etc.) — stay in tests that use them
- MockPyth deployment — only OrderRouter.t.sol and some AuditFindings tests need it; they deploy it in their own setUp override
- Order construction — the _open/_close helpers cover the common case; exotic orders are constructed inline

---

## MockPyth extraction

Extract the inline `MockPyth` contract (identical in OrderRouter.t.sol and AuditFindings.t.sol) to `test/mocks/MockPyth.sol`. Both files import from there. The mock implements:
- `setPrice(feedId, price, expo, publishTime)`
- `setAllPrices(feedIds, price, expo, publishTime)`
- `getPriceUnsafe(id)` → PythStructs.Price
- `setFee(fee)` / `getUpdateFee(bytes[])` → uint256
- `updatePriceFeeds(bytes[])` — no-op

---

## Time-Travel Cleanup

### Problem
`vm.warp` usage is inconsistent and brittle across the suite:
- **Unrealistic absolute timestamps**: `vm.warp(1000)`, `vm.warp(48 hours + 2)` — these land at Unix epoch 1970, which breaks any code that assumes a post-2024 timestamp (fee calculations, oracle staleness, etc.)
- **Relative jumps off stale base**: `vm.warp(block.timestamp + 48 hours + 1)` during setUp accumulates fragile offsets (48h+2, 96h+3, 144h+4) — adding one more timelock step silently shifts every subsequent warp
- **Mixed paradigms in one file**: some tests use absolute timestamps for FAD, others use relative jumps for funding — makes it hard to reason about the final timestamp state

### Fix
The `_bypassAllTimelocks()` function in BasePerpTest handles all setUp time manipulation internally and lands at `SETUP_TIMESTAMP` (Monday 2024-03-04 10:00 UTC). This eliminates:
- All small absolute warps during setUp (the `vm.warp(48 hours + 2)` / `vm.warp(96 hours + 3)` pattern)
- Any risk of landing at unrealistic timestamps — tests always start at a real-world date

After setUp, tests use:
- `_warpForward(delta)` for relative jumps (reads timestamp via assembly to avoid Foundry caching)
- Local absolute constants for FAD-specific tests (e.g., `FRIDAY_18UTC = 604_951_200`) — these are defined in the test files that need them, not in the base
- `_setRiskParams()` helper which warps forward 48h+1 internally — callers don't manage timelock timing

### What to audit in each file
During refactor, check every `vm.warp` call:
1. **setUp warps** → eliminated by base (absorbed into `_bypassAllTimelocks()`)
2. **Unrealistic timestamps** (`vm.warp(1000)`) → replace with `SETUP_TIMESTAMP + offset` or `_warpForward()`
3. **Relative warps after setUp** → convert to `_warpForward(delta)` where possible
4. **Absolute FAD timestamps** → keep as-is (they're realistic Unix timestamps), but verify they occur AFTER `SETUP_TIMESTAMP`

---

## Per-file refactor notes

### CfdEngine.t.sol
- Inherits BasePerpTest
- Overrides `_riskParams()`: vpiFactor=0.0005, baseApy=0.15, maxApy=3.0
- Remove inline setUp, _depositToClearinghouse → use `_fundTrader`
- Replace `engine.processOrder(order, ...)` calls with `_open`/`_close` or manual `vm.prank(address(router))`
- Remove `engine.setOrderRouter(address(this))`

### AuditC01C02C03.t.sol
- Inherits BasePerpTest
- Overrides `_riskParams()`: vpiFactor=0, baseApy=0.5
- Overrides `_initialJuniorDeposit()`: 5_000_000 * 1e6
- Already has `_open`/`_close`/`_deposit` helpers — remove and use base versions

### TimelockPause.t.sol
- Inherits BasePerpTest
- Overrides `_initialSeniorDeposit()`: 500_000 * 1e6
- Overrides `_initialJuniorDeposit()`: 500_000 * 1e6
- Keeps own `_currentTimestamp` if divergent, or uses base version
- Alice/nonOwner funding stays in setUp override

### Liquidation.t.sol
- Inherits BasePerpTest
- Default params fine (vpiFactor=0, baseApy=0)
- Keeps FAD timestamp constants locally (WEDNESDAY_NOON, FRIDAY_EVENING)
- Replace inline setUp with super.setUp() + alice funding

### PerpInvariant.t.sol
- PerpInvariantTest inherits BasePerpTest
- Overrides `_riskParams()`: vpiFactor=0.0005, baseApy=0.15, maxApy=3.0
- Overrides `_initialSeniorDeposit()`: 200_000 * 1e6
- Overrides `_initialJuniorDeposit()`: 500_000 * 1e6
- setUp creates PerpHandler with deployed contracts, seeds traders
- PerpHandler stays standalone (receives contracts via constructor)

### AuditFindings.t.sol
- All nested test contracts inherit BasePerpTest
- Each overrides `_riskParams()` / `_initialJuniorDeposit()` as needed
- Remove 7 duplicate setUp() blocks
- Remove duplicate _fundJunior/_fundSenior/_fundTrader/_warpPastTimelock
- Replace inline MockPyth with import from test/mocks/MockPyth.sol

### HousePool.t.sol
- Inherits BasePerpTest
- Overrides `_initialJuniorDeposit()`: 0 (lazy-funds per test)
- Overrides `_initialSeniorDeposit()`: 0
- Remove inline setUp, _fundSenior/_fundJunior/_fundTrader → use base versions

### OrderRouter.t.sol
- Inherits BasePerpTest
- Deploys MockPyth (imported from test/mocks/MockPyth.sol) in setUp override
- Creates BasketOracle + OrderRouter with Pyth in setUp override (replaces default router)
- Keeps FAD timestamp constants locally
- FadStalenessTest inherits BasePerpTest separately with its own Pyth setup

---

## Execution plan

- [x] 1. Create `test/mocks/MockPyth.sol` — extract from OrderRouter.t.sol
- [x] 2. Create `test/perps/BasePerpTest.sol` — base contract with all hooks/helpers
- [x] 3. Refactor `CfdEngine.t.sol` — inherit base, remove boilerplate
- [x] 4. Refactor `AuditC01C02C03.t.sol` — inherit base, remove boilerplate
- [x] 5. Refactor `TimelockPause.t.sol` — inherit base, remove boilerplate
- [x] 6. Refactor `Liquidation.t.sol` — inherit base, remove boilerplate
- [x] 7. Refactor `PerpInvariant.t.sol` — inherit base, keep PerpHandler standalone
- [x] 8. Refactor `AuditFindings.t.sol` — inherit base, collapse 7 setUp copies
- [x] 9. Refactor `HousePool.t.sol` — inherit base, remove boilerplate
- [x] 10. Refactor `OrderRouter.t.sol` — inherit base, extract MockPyth import
- [x] 11. Verify: `forge build` passes
- [x] 12. Verify: `forge test --match-path "test/perps/*"` — same 225 pass / 7 pre-existing fail
