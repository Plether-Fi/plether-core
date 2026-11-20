// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

/// @notice Input-driven reference ledger for the LP-capital carry specification.
/// @dev This test model imports no production contracts or arithmetic. Initialize it from fixture inputs, then
///      advance it from actions, never from observed balances, indexes, previews, or CarryRealized events. It models
///      carry and collateral classification, not price-risk admission, fees, or terminal close/liquidation charges.
///      Those domains must supply independently computed post-action state through applyPosition. Arithmetic uses
///      reduced rational products and is checked against offline Python Fraction vectors in the companion tests.
contract CarryReferenceLedger {

    uint256 internal constant SCALE = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 31_536_000;

    struct Side {
        uint256 maxProfitExposure;
    }

    struct Account {
        bool initialized;
        bool active;
        uint8 side;
        uint256 maxProfit;
        uint256 pledge;
        uint256 free;
        uint256 protectedFunds;
        uint256 lastIndex;
        uint256 lastTime;
        uint256 arrears;
        uint256 totalNewCarry;
        uint256 totalCollected;
        uint256 totalWithheld;
        uint256 totalVpiOffset;
        uint256 totalWaived;
    }

    struct Collection {
        uint256 newCarry;
        uint256 assessed;
        uint256 fromMargin;
        uint256 fromFree;
        uint256 unpaid;
    }

    mapping(address => Account) private _accounts;
    Side[2] private _sides;
    uint256 public carryIndex;
    uint256 public carryTimestamp;
    /// @notice Gross canonical pool assets; claim liabilities never rewrite this cash/accounting quantity.
    uint256 public poolDepth;
    uint256 public totalClaims;
    uint256 public annualBps;
    uint256 public totalNewCarry;
    uint256 public totalCollected;
    uint256 public totalWithheld;
    uint256 public totalVpiOffset;
    uint256 public totalWaived;

    error AlreadyInitialized();
    error UnknownAccount();
    error InvalidSide();
    error CheckpointRequired();
    error InsufficientFree();
    error InsufficientPledge();
    error InsufficientProtected();
    error CarryDelinquency();
    error InsufficientClaimLiquidity();
    error ClaimBalanceMismatch();
    error InvalidArrearsSettlement();

    constructor(
        uint256 initialDepth,
        uint256 initialTime,
        uint256 initialAnnualBps
    ) {
        poolDepth = initialDepth;
        annualBps = initialAnnualBps;
        carryTimestamp = initialTime;
    }

    function accountState(
        address account
    ) external view returns (Account memory) {
        return _accounts[account];
    }

    function sideState(
        uint8 side
    ) external view returns (Side memory) {
        if (side > 1) {
            revert InvalidSide();
        }
        return _sides[side];
    }

    /// @notice One-time initialization from independently calculated fixture inputs, including all protected locks.
    function initializeAccount(
        address account,
        uint8 side,
        uint256 maxProfit,
        uint256 pledge,
        uint256 free,
        uint256 protectedFunds,
        uint256 timestamp
    ) external {
        if (_accounts[account].initialized) {
            revert AlreadyInitialized();
        }
        advance(timestamp);
        _accounts[account].initialized = true;
        _replace(account, side, maxProfit, pledge, free, protectedFunds, true, timestamp);
    }

    /// @notice Initialize a funded actor without a position, without checkpointing the market clock.
    /// @dev Flat-account deposits do not invoke Engine carry collection. Future paid claims are free cash until an
    ///      input-derived open transition activates the actor. An active endpoint position can have zero max profit.
    function initializeFlatAccount(
        address account,
        uint256 free,
        uint256 protectedFunds,
        uint256 timestamp
    ) external {
        if (_accounts[account].initialized) {
            revert AlreadyInitialized();
        }
        _accounts[account].initialized = true;
        _replace(account, 0, 0, 0, free, protectedFunds, false, timestamp);
    }

    /// @notice One clock advances at the flat annual rate while any maximum-profit exposure is active.
    function advance(
        uint256 timestamp
    ) public {
        if (timestamp <= carryTimestamp) {
            return;
        }
        if (_sides[0].maxProfitExposure != 0 || _sides[1].maxProfitExposure != 0) {
            carryIndex += indexIncrement(annualBps, timestamp - carryTimestamp);
        }
        carryTimestamp = timestamp;
    }

    function changeDepth(
        uint256 newDepth,
        uint256 timestamp
    ) external {
        advance(timestamp);
        poolDepth = newDepth;
    }

    /// @notice Claims remain separate from physical pool assets and reserve capital before any payment occurs.
    function economicDepth() public view returns (uint256) {
        return poolDepth > totalClaims ? poolDepth - totalClaims : 0;
    }

    /// @notice Book independently derived claim creation or netting after advancing the flat-rate clock.
    function changeClaims(
        uint256 newClaims,
        uint256 timestamp
    ) external {
        advance(timestamp);
        totalClaims = newClaims;
    }

    /// @notice Replace input-derived effective depth for a passive cash change that does not checkpoint the global index.
    /// @dev LP liquidity changes, external token shocks, and terminal dust transfers do not advance the carry clock.
    ///      Depth changes have no effect on the flat-rate interval assessed at the next Engine checkpoint.
    function changeDepthWithoutCheckpoint(
        uint256 newDepth
    ) external {
        poolDepth = newDepth;
    }

    function changeRate(
        uint256 newAnnualBps,
        uint256 timestamp
    ) external {
        advance(timestamp);
        annualBps = newAnnualBps;
    }

    /// @notice Assesses historical carry once, then collects pledge before free cash; protected locks never pay it.
    function checkpoint(
        address account,
        uint256 timestamp
    ) public returns (Collection memory result) {
        Account storage state = _account(account);
        advance(timestamp);
        if (!state.active) {
            return result;
        }
        uint256 endIndex = carryIndex;
        result.newCarry = amountFromIndex(state.maxProfit, endIndex - state.lastIndex);
        result.assessed = state.arrears + result.newCarry;
        state.lastIndex = endIndex;
        state.lastTime = timestamp;
        state.totalNewCarry += result.newCarry;
        totalNewCarry += result.newCarry;

        result.fromMargin = _min(result.assessed, state.pledge);
        result.fromFree = _min(result.assessed - result.fromMargin, state.free);
        result.unpaid = result.assessed - result.fromMargin - result.fromFree;
        state.pledge -= result.fromMargin;
        state.free -= result.fromFree;
        state.arrears = result.unpaid;
        uint256 paid = result.fromMargin + result.fromFree;
        state.totalCollected += paid;
        totalCollected += paid;
        poolDepth += paid;
    }

    /// @notice Assess old exposure before refunding collateral, retaining all assessed carry as arrears.
    /// @dev Source-position refunds do not alter full max-profit exposure or collect their returned backing.
    function assessWithoutCollection(
        address account,
        uint256 timestamp
    ) external {
        Account storage state = _account(account);
        advance(timestamp);
        if (!state.active) {
            return;
        }
        uint256 endIndex = carryIndex;
        uint256 newlyAssessed = amountFromIndex(state.maxProfit, endIndex - state.lastIndex);
        state.arrears += newlyAssessed;
        state.totalNewCarry += newlyAssessed;
        totalNewCarry += newlyAssessed;
        state.lastIndex = endIndex;
        state.lastTime = timestamp;
    }

    /// @notice Project collection solely from this ledger's submitted action history, without changing any clock.
    /// @dev Stored arrears may have newly credited backing. Eligibility must use unpaid after this projection,
    ///      not arrears alone; claim/bounty credits deliberately do not collect their new backing a second time.
    function previewCheckpoint(
        address account,
        uint256 timestamp
    ) external view returns (Collection memory result) {
        Account storage state = _account(account);
        if (!state.active) {
            return result;
        }
        uint256 projectedIndex = carryIndex;
        if (timestamp > carryTimestamp && (_sides[0].maxProfitExposure != 0 || _sides[1].maxProfitExposure != 0)) {
            projectedIndex += indexIncrement(annualBps, timestamp - carryTimestamp);
        }
        result.newCarry = amountFromIndex(state.maxProfit, projectedIndex - state.lastIndex);
        result.assessed = state.arrears + result.newCarry;
        result.fromMargin = _min(result.assessed, state.pledge);
        result.fromFree = _min(result.assessed - result.fromMargin, state.free);
        result.unpaid = result.assessed - result.fromMargin - result.fromFree;
    }

    /// @notice Ordinary deposits are credited BEFORE collection; the new deposit can pay retained arrears now.
    function deposit(
        address account,
        uint256 amount,
        uint256 timestamp
    ) external returns (Collection memory result) {
        Account storage state = _account(account);
        state.free += amount;
        if (!state.active) {
            return result;
        }
        return checkpoint(account, timestamp);
    }

    /// @notice Nonzero bounty credits collect old backing first and preserve the entire new credit.
    /// @dev A fresh oracle publication advances both clocks separately, even for a flat recipient. The caller must
    ///      model that mark update with advance before creditFree. Zero bounty credits are complete no-ops.
    function creditFree(
        address account,
        uint256 amount,
        uint256 timestamp
    ) external returns (Collection memory result) {
        if (amount == 0) {
            return result;
        }
        if (_account(account).active) {
            result = checkpoint(account, timestamp);
        }
        _accounts[account].free += amount;
    }

    /// @notice Claim payout checks aggregate liquidity AFTER collection and credits pledge for an active position.
    /// @param allClaims Independently modeled total outstanding claims before this payment.
    function creditClaim(
        address account,
        uint256 amount,
        uint256 allClaims,
        uint256 timestamp
    ) external returns (Collection memory result) {
        if (allClaims != totalClaims) {
            revert ClaimBalanceMismatch();
        }
        result = checkpoint(account, timestamp);
        if (amount == 0 || poolDepth < allClaims || amount > allClaims) {
            revert InsufficientClaimLiquidity();
        }
        poolDepth -= amount;
        totalClaims -= amount;
        Account storage state = _accounts[account];
        if (state.active) {
            state.pledge += amount;
        } else {
            state.free += amount;
        }
    }

    function addMargin(
        address account,
        uint256 amount,
        uint256 timestamp
    ) external returns (Collection memory result) {
        result = checkpoint(account, timestamp);
        Account storage state = _accounts[account];
        if (amount > state.free) {
            revert InsufficientFree();
        }
        state.free -= amount;
        state.pledge += amount;
    }

    /// @notice Carry-only withdrawal guard. Price-risk admission is a separate responsibility of the caller's model.
    function withdraw(
        address account,
        uint256 amount,
        uint256 timestamp
    ) external returns (Collection memory result) {
        Account storage state = _account(account);
        if (state.active) {
            result = checkpoint(account, timestamp);
        }
        if (state.arrears != 0) {
            revert CarryDelinquency();
        }
        if (amount > state.free) {
            revert InsufficientFree();
        }
        state.free -= amount;
    }

    function reserveFree(
        address account,
        uint256 amount,
        uint256 timestamp
    ) external returns (Collection memory result) {
        Account storage state = _account(account);
        if (state.active) {
            result = checkpoint(account, timestamp);
        }
        if (amount > state.free) {
            revert InsufficientFree();
        }
        state.free -= amount;
        state.protectedFunds += amount;
    }

    /// @notice Classify a separately modeled reservation after the caller has accounted for its checkpoint.
    /// @dev Unlike reserveFree, this operation intentionally leaves the global clock and maximum-profit exposure untouched. It does
    ///      not imply that the production reservation skips carry: public commits checkpoint before reserving cash.
    function reserveWithoutCheckpoint(
        address account,
        uint256 amount
    ) external {
        Account storage state = _account(account);
        if (amount > state.free) {
            revert InsufficientFree();
        }
        state.free -= amount;
        state.protectedFunds += amount;
    }

    /// @notice Model a hypothetical split close bounty after its commitment checkpoint.
    /// @dev Public close commitment currently requires zero bounty. This reference-only transition shows
    ///      that moving pledge does not affect the full max-profit basis or reset accrued carry or clocks.
    function reserveBountyWithoutCheckpoint(
        address account,
        uint256 freePart,
        uint256 pledgePart
    ) external {
        Account storage state = _account(account);
        if (freePart > state.free) {
            revert InsufficientFree();
        }
        if (pledgePart > state.pledge) {
            revert InsufficientPledge();
        }
        state.free -= freePart;
        state.pledge -= pledgePart;
        state.protectedFunds += freePart + pledgePart;
    }

    /// @notice Release an order's independently tracked remaining reservation without collecting source carry.
    function releaseProtectedWithoutCheckpoint(
        address account,
        uint256 amount
    ) external {
        Account storage state = _account(account);
        _consumeProtected(state, amount);
        state.free += amount;
    }

    /// @notice Restore a model-only pledge-funded refund to the caller-classified active position generation.
    function releaseToPledgeWithoutCheckpoint(
        address account,
        uint256 amount
    ) external {
        Account storage state = _account(account);
        _consumeProtected(state, amount);
        state.pledge += amount;
    }

    /// @notice Debit protected settlement paid or forfeited by an independently modeled terminal order outcome.
    /// @dev This does not credit a recipient or the pool: the action ledger supplies that separate destination flow.
    function consumeProtectedWithoutCheckpoint(
        address account,
        uint256 amount
    ) external {
        _consumeProtected(_account(account), amount);
    }

    /// @notice Apply separately modeled trade/cleanup classifications, after checkpointing an active position.
    /// @dev This is not a synchronization API: all amounts must come from the caller's independent action ledger.
    ///      Existing arrears are preserved. Resolve a terminal action's paid/waived arrears explicitly first.
    function applyPosition(
        address account,
        uint8 side,
        uint256 maxProfit,
        uint256 pledge,
        uint256 free,
        uint256 protectedFunds,
        bool active,
        uint256 timestamp
    ) external {
        Account storage state = _account(account);
        advance(timestamp);
        if (state.active && (state.lastTime != timestamp || state.lastIndex != carryIndex)) {
            revert CheckpointRequired();
        }
        if (!active && state.arrears != 0) {
            revert CarryDelinquency();
        }
        _replace(account, side, maxProfit, pledge, free, protectedFunds, active, timestamp);
    }

    /// @notice Resolve carry paid entirely by physical settlement, retaining the existing caller convention.
    function settleActionArrears(
        address account,
        uint256 paid,
        uint256 waived
    ) external {
        _settleActionArrears(account, paid, 0, 0, waived);
    }

    /// @notice Distinguish physical carry recovery from carry recovered by withholding a newly created gain.
    /// @dev totalCollected includes both economic recoveries, while totalWithheld records its gain-funded portion.
    ///      Only physicalPaid enters the pool. A withheld gain reduces the outgoing payout; adding it to cash would
    ///      count the same value twice. The caller separately debits independently classified settlement sources.
    function settleActionArrears(
        address account,
        uint256 physicalPaid,
        uint256 gainWithheld,
        uint256 waived
    ) external {
        _settleActionArrears(account, physicalPaid, gainWithheld, 0, waived);
    }

    /// @notice Resolve a net action's carry, separating physical cash, withheld price gain, VPI offset and waiver.
    /// @dev A negative VPI credit can economically discharge carry without new price gain or cash entering the pool.
    ///      The independently calculated action ledger supplies that attribution; it must not label the offset a
    ///      cash receipt, gain withholding, or waiver. All three recovery sources contribute to totalCollected.
    function settleActionArrears(
        address account,
        uint256 physicalPaid,
        uint256 gainWithheld,
        uint256 vpiOffset,
        uint256 waived
    ) external {
        _settleActionArrears(account, physicalPaid, gainWithheld, vpiOffset, waived);
    }

    function _settleActionArrears(
        address account,
        uint256 physicalPaid,
        uint256 gainWithheld,
        uint256 vpiOffset,
        uint256 waived
    ) private {
        Account storage state = _account(account);
        uint256 paid = physicalPaid + gainWithheld + vpiOffset;
        if (paid + waived > state.arrears) {
            revert InvalidArrearsSettlement();
        }
        state.arrears -= paid + waived;
        state.totalCollected += paid;
        state.totalWithheld += gainWithheld;
        state.totalVpiOffset += vpiOffset;
        state.totalWaived += waived;
        totalCollected += paid;
        totalWithheld += gainWithheld;
        totalVpiOffset += vpiOffset;
        totalWaived += waived;
        poolDepth += physicalPaid;
    }

    function indexIncrement(
        uint256 rate,
        uint256 elapsed
    ) public pure returns (uint256) {
        return _rationalProduct(rate, elapsed, SCALE, YEAR * BPS);
    }

    function amountFromIndex(
        uint256 maxProfitExposure,
        uint256 delta
    ) public pure returns (uint256) {
        return _rationalProduct(maxProfitExposure, delta, 1, SCALE);
    }

    function _rationalProduct(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 denominator
    ) private pure returns (uint256) {
        // Cancel each denominator factor before multiplication. Unlike the production expression this represents
        // the exact rational first, and performs its sole floor only after cancellation. Fixtures bound the reduced
        // numerator to uint256; arbitrary unbounded financial values are outside this test model's domain.
        uint256 divisor = _gcd(a, denominator);
        a /= divisor;
        denominator /= divisor;
        divisor = _gcd(b, denominator);
        b /= divisor;
        denominator /= divisor;
        divisor = _gcd(c, denominator);
        c /= divisor;
        denominator /= divisor;
        return a * b * c / denominator;
    }

    function _gcd(
        uint256 a,
        uint256 b
    ) private pure returns (uint256) {
        while (b != 0) {
            (a, b) = (b, a % b);
        }
        return a;
    }

    function _replace(
        address account,
        uint8 side,
        uint256 maxProfit,
        uint256 pledge,
        uint256 free,
        uint256 protectedFunds,
        bool active,
        uint256 timestamp
    ) private {
        if (side > 1) {
            revert InvalidSide();
        }
        Account storage state = _accounts[account];
        if (state.active) {
            _sides[state.side].maxProfitExposure -= state.maxProfit;
        }
        state.side = side;
        state.active = active;
        state.maxProfit = active ? maxProfit : 0;
        state.pledge = pledge;
        state.free = free;
        state.protectedFunds = protectedFunds;
        state.lastIndex = carryIndex;
        state.lastTime = timestamp;
        _sides[side].maxProfitExposure += state.maxProfit;
    }

    function _account(
        address account
    ) private view returns (Account storage state) {
        state = _accounts[account];
        if (!state.initialized) {
            revert UnknownAccount();
        }
    }

    function _consumeProtected(
        Account storage state,
        uint256 amount
    ) private {
        if (amount > state.protectedFunds) {
            revert InsufficientProtected();
        }
        state.protectedFunds -= amount;
    }

    function _min(
        uint256 a,
        uint256 b
    ) private pure returns (uint256) {
        return a < b ? a : b;
    }

}
