// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {CfdTypes} from "@plether/perps/CfdTypes.sol";
import {OrderV3Types} from "@plether/perps/OrderV3Types.sol";
import {OrderValidationLib} from "@plether/perps/libraries/OrderValidationLib.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Independent enumeration checks the feasible integer prices, including fee-floor inversion.
contract OrderAdmissionPriceRangeTest is Test {

    function testFuzz_PriceRangeMatchesEveryPermittedPrice(
        uint8 lotsSeed,
        uint8 capSeed,
        uint8 targetSeed,
        uint16 feeSeed,
        uint8 notionalSeed,
        uint8 feeLimitSeed,
        uint8 actionSeed,
        uint8 grossSeed,
        uint8 bountySeed
    ) public pure {
        uint256 size = (uint256(lotsSeed) % 40 + 1) * CfdTypes.SIZE_QUANTUM;
        uint256 target = uint256(targetSeed) % 40 + 1;
        OrderV3Types.ExecutionBounds memory bounds = _unbounded();
        bounds.maxExecutionNotionalAssets = _allowance(notionalSeed);
        bounds.maxExplicitFeesAssets = _allowance(feeLimitSeed);
        bounds.maxActionChargeAssets = _allowance(actionSeed);
        bounds.maxGrossAccountDebitAssets = _allowance(grossSeed);
        OrderValidationLib.ExecutionDomain memory domain;
        domain.capPrice = uint256(capSeed) % 32 + 1;
        domain.executionBountyAssets = uint256(bountySeed) % 17;
        for (uint256 direction; direction < 4; ++direction) {
            CfdTypes.Side side = CfdTypes.Side(direction % 2);
            bool close = direction >= 2;
            for (uint256 mode; mode < 4; ++mode) {
                domain.vpiDisabled = mode % 2 == 0;
                domain.executionFeeBps = mode < 2 ? 0 : uint256(feeSeed) % 10_001;
                _compareEveryPrice(side, close, size, target, bounds, domain);
            }
        }
    }

    function test_WideLotAndPriceDomainAcceptsUnboundedAllowances() public pure {
        uint256 size = uint256(type(uint112).max) * CfdTypes.SIZE_QUANTUM;
        OrderV3Types.ExecutionBounds memory bounds = _unbounded();
        OrderValidationLib.ExecutionDomain memory domain =
            OrderValidationLib.ExecutionDomain(type(uint32).max, 10_000, true, type(uint96).max);
        for (uint256 direction; direction < 4; ++direction) {
            CfdTypes.Side side = CfdTypes.Side(direction % 2);
            bool close = direction >= 2;
            uint256 target = (direction == 0 || direction == 3) ? 1 : domain.capPrice;
            for (uint256 vpi; vpi < 2; ++vpi) {
                domain.vpiDisabled = vpi == 0;
                (uint256 minimum, uint256 maximum) =
                    OrderValidationLib.executionPriceRange(side, close, size, target, bounds, domain);
                assertEq(minimum, 1);
                assertEq(maximum, domain.capPrice);
                assertTrue(OrderValidationLib.isRequestFeasible(side, close, size, target, bounds, domain));
            }
        }
        bounds.maxExplicitFeesAssets = uint256(type(uint112).max) * (domain.capPrice - 1);
        (, uint256 roundedMaximum) =
            OrderValidationLib.executionPriceRange(CfdTypes.Side.LONG, false, size, 1, bounds, domain);
        assertEq(roundedMaximum, domain.capPrice - 1);
    }

    function test_RequestFeasibilityRejectsStructuralBounds() public pure {
        OrderV3Types.ExecutionBounds memory bounds = _unbounded();
        OrderValidationLib.ExecutionDomain memory domain = OrderValidationLib.ExecutionDomain(32, 0, true, 0);
        assertFalse(OrderValidationLib.isRequestFeasible(CfdTypes.Side.LONG, false, 0, 1, bounds, domain));
        assertFalse(OrderValidationLib.isRequestFeasible(CfdTypes.Side.LONG, false, 1, 1, bounds, domain));
        uint256 oversized = (uint256(type(uint112).max) + 1) * CfdTypes.SIZE_QUANTUM;
        assertFalse(OrderValidationLib.isRequestFeasible(CfdTypes.Side.LONG, false, oversized, 1, bounds, domain));
        bounds.maxPostPositionSize = CfdTypes.SIZE_QUANTUM - 1;
        assertFalse(
            OrderValidationLib.isRequestFeasible(CfdTypes.Side.LONG, false, CfdTypes.SIZE_QUANTUM, 1, bounds, domain)
        );
        bounds.maxPostPositionSize = type(uint256).max;
        bounds.minPostPositionEquityAssets = uint256(type(int256).max) + 1;
        assertFalse(
            OrderValidationLib.isRequestFeasible(CfdTypes.Side.LONG, false, CfdTypes.SIZE_QUANTUM, 1, bounds, domain)
        );
        assertTrue(
            OrderValidationLib.isRequestFeasible(CfdTypes.Side.LONG, true, CfdTypes.SIZE_QUANTUM, 32, bounds, domain)
        );
    }

    function _compareEveryPrice(
        CfdTypes.Side side,
        bool close,
        uint256 size,
        uint256 target,
        OrderV3Types.ExecutionBounds memory bounds,
        OrderValidationLib.ExecutionDomain memory domain
    ) private pure {
        (uint256 minimum, uint256 maximum) =
            OrderValidationLib.executionPriceRange(side, close, size, target, bounds, domain);
        bool any;
        for (uint256 price = 1; price <= domain.capPrice + 1; ++price) {
            bool permitted = _directPredicate(side, close, size, target, price, bounds, domain);
            assertEq(minimum != 0 && price >= minimum && price <= maximum, permitted);
            any = any || permitted;
        }
        assertEq(OrderValidationLib.isRequestFeasible(side, close, size, target, bounds, domain), any);
    }

    function _directPredicate(
        CfdTypes.Side side,
        bool close,
        uint256 size,
        uint256 target,
        uint256 price,
        OrderV3Types.ExecutionBounds memory bounds,
        OrderValidationLib.ExecutionDomain memory domain
    ) private pure returns (bool) {
        if (!close && bounds.allowedExecutionModes & 1 == 0) {
            return false;
        }
        if (price > domain.capPrice) {
            return false;
        }
        if (side == CfdTypes.Side.LONG && (close ? price > target : price < target)) {
            return false;
        }
        if (side == CfdTypes.Side.SHORT && (close ? price < target : price > target)) {
            return false;
        }
        uint256 notional = (size / CfdTypes.SIZE_QUANTUM) * price;
        uint256 fee = (notional * domain.executionFeeBps) / 10_000;
        if (notional > bounds.maxExecutionNotionalAssets || fee > bounds.maxExplicitFeesAssets) {
            return false;
        }
        if (!close && domain.executionBountyAssets > bounds.maxGrossAccountDebitAssets) {
            return false;
        }
        if (!domain.vpiDisabled) {
            return true;
        }
        if (fee > bounds.maxActionChargeAssets) {
            return false;
        }
        return close || fee + domain.executionBountyAssets <= bounds.maxGrossAccountDebitAssets;
    }

    function _allowance(
        uint8 seed
    ) private pure returns (uint256) {
        return seed % 3 == 0 ? 0 : seed % 3 == 1 ? type(uint256).max : seed;
    }

    function _unbounded() private pure returns (OrderV3Types.ExecutionBounds memory bounds) {
        bounds.allowedExecutionModes = 7;
        bounds.maxExecutionNotionalAssets = type(uint256).max;
        bounds.maxExplicitFeesAssets = type(uint256).max;
        bounds.maxActionChargeAssets = type(uint256).max;
        bounds.maxGrossAccountDebitAssets = type(uint256).max;
        bounds.maxPostPositionSize = type(uint256).max;
    }

}
