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
        uint256 index;
        uint256 borrowBase;
        uint256 timestamp;
    }

    struct Account {
        bool initialized;
        bool active;
        uint8 side;
        uint256 maxProfit;
        uint256 pledge;
        uint256 free;
        uint256 protectedFunds;
        uint256 borrowBase;
        uint256 lastIndex;
        uint256 lastTime;
        uint256 arrears;
        uint256 totalNewCarry;
        uint256 totalCollected;
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
    uint256 public poolDepth;
    uint256 public annualBps;
    uint256 public totalNewCarry;
    uint256 public totalCollected;
    uint256 public totalWaived;

    error AlreadyInitialized();
    error UnknownAccount();
    error InvalidSide();
    error CheckpointRequired();
    error InsufficientFree();
    error CarryDelinquency();
    error InsufficientClaimLiquidity();
    error InvalidArrearsSettlement();

    constructor(
        uint256 initialDepth,
        uint256 initialTime,
        uint256 initialAnnualBps
    ) {
        poolDepth = initialDepth;
        annualBps = initialAnnualBps;
        _sides[0].timestamp = initialTime;
        _sides[1].timestamp = initialTime;
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

    /// @notice Initialize a funded actor without a position. Future paid claims are free cash until an input-derived
    ///      open transition activates it. Kept explicit because an active endpoint position can have zero max profit.
    function initializeFlatAccount(
        address account,
        uint256 free,
        uint256 protectedFunds,
        uint256 timestamp
    ) external {
        if (_accounts[account].initialized) {
            revert AlreadyInitialized();
        }
        advance(timestamp);
        _accounts[account].initialized = true;
        _replace(account, 0, 0, 0, free, protectedFunds, false, timestamp);
    }

    /// @notice Both directional clocks advance against the same old depth and old borrow bases.
    function advance(
        uint256 timestamp
    ) public {
        for (uint8 side; side < 2; ++side) {
            Side storage state = _sides[side];
            if (timestamp <= state.timestamp) {
                continue;
            }
            state.index += indexIncrement(state.borrowBase, poolDepth, annualBps, timestamp - state.timestamp);
            state.timestamp = timestamp;
        }
    }

    function changeDepth(
        uint256 newDepth,
        uint256 timestamp
    ) external {
        advance(timestamp);
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
        uint256 endIndex = _sides[state.side].index;
        result.newCarry = amountFromIndex(state.borrowBase, endIndex - state.lastIndex);
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
        _refreshBorrowBase(state);
        poolDepth += paid;
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
        result = checkpoint(account, timestamp);
        if (amount == 0 || poolDepth < allClaims || amount > allClaims) {
            revert InsufficientClaimLiquidity();
        }
        poolDepth -= amount;
        Account storage state = _accounts[account];
        if (state.active) {
            state.pledge += amount;
            _refreshBorrowBase(state);
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
        _refreshBorrowBase(state);
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
    /// @dev Unlike reserveFree, this operation intentionally leaves all clocks and borrow bases untouched. It does
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
        if (state.active && (state.lastTime != timestamp || state.lastIndex != _sides[state.side].index)) {
            revert CheckpointRequired();
        }
        if (!active && state.arrears != 0) {
            revert CarryDelinquency();
        }
        _replace(account, side, maxProfit, pledge, free, protectedFunds, active, timestamp);
    }

    /// @notice Resolve carry using independently calculated terminal action sources, including an explicit waiver.
    function settleActionArrears(
        address account,
        uint256 paid,
        uint256 waived
    ) external {
        Account storage state = _account(account);
        if (paid + waived > state.arrears) {
            revert InvalidArrearsSettlement();
        }
        state.arrears -= paid + waived;
        state.totalCollected += paid;
        state.totalWaived += waived;
        totalCollected += paid;
        totalWaived += waived;
        poolDepth += paid;
    }

    /// @notice Integer bps are floored before annualization; utilization saturates before any multiplication.
    function utilization(
        uint256 borrowBase,
        uint256 depth
    ) public pure returns (uint256) {
        if (borrowBase == 0) {
            return 0;
        }
        if (depth == 0 || borrowBase >= depth) {
            return BPS;
        }
        return _rationalProduct(borrowBase, BPS, 1, depth);
    }

    function indexIncrement(
        uint256 borrowBase,
        uint256 depth,
        uint256 rate,
        uint256 elapsed
    ) public pure returns (uint256) {
        return _rationalProduct(rate * utilization(borrowBase, depth), elapsed, SCALE, YEAR * BPS * BPS);
    }

    function amountFromIndex(
        uint256 borrowBase,
        uint256 delta
    ) public pure returns (uint256) {
        return _rationalProduct(borrowBase, delta, 1, SCALE);
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
        _sides[state.side].borrowBase -= state.borrowBase;
        state.side = side;
        state.active = active;
        state.maxProfit = maxProfit;
        state.pledge = pledge;
        state.free = free;
        state.protectedFunds = protectedFunds;
        state.borrowBase = active && maxProfit > pledge ? maxProfit - pledge : 0;
        state.lastIndex = _sides[side].index;
        state.lastTime = timestamp;
        _sides[side].borrowBase += state.borrowBase;
    }

    function _refreshBorrowBase(
        Account storage state
    ) private {
        uint256 next = state.active && state.maxProfit > state.pledge ? state.maxProfit - state.pledge : 0;
        _sides[state.side].borrowBase = _sides[state.side].borrowBase - state.borrowBase + next;
        state.borrowBase = next;
    }

    function _account(
        address account
    ) private view returns (Account storage state) {
        state = _accounts[account];
        if (!state.initialized) {
            revert UnknownAccount();
        }
    }

    function _min(
        uint256 a,
        uint256 b
    ) private pure returns (uint256) {
        return a < b ? a : b;
    }

}
