// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {OrderRouter} from "@plether/perps/OrderRouter.sol";
import {PletherOracle} from "@plether/perps/PletherOracle.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {IPyth, PythStructs} from "@plether/shared/interfaces/IPyth.sol";
import {DecimalConstants} from "@plether/shared/libraries/DecimalConstants.sol";
import {BasketOracle} from "@plether/spot/oracles/BasketOracle.sol";
import {MockOracle} from "@plether/test-utils/MockOracle.sol";
import {MockPyth} from "@plether/test-utils/MockPyth.sol";
import {Test} from "forge-std/Test.sol";

contract OracleParityBasketPriceHarness is OrderRouter {

    IPyth internal localPyth;
    bytes32[] internal localPythFeedIds;
    uint256[] internal localQuantities;
    uint256[] internal localBasePrices;
    bool[] internal localInversions;

    constructor(
        address pyth,
        bytes32[] memory feedIds,
        uint256[] memory quantities,
        uint256[] memory basePrices,
        bool[] memory inversions
    )
        OrderRouter(
            address(1),
            address(1),
            address(1),
            address(new PletherOracle(address(1), address(1), pyth, feedIds, quantities, basePrices, inversions))
        )
    {
        localPyth = IPyth(pyth);
        localPythFeedIds = feedIds;
        localQuantities = quantities;
        localBasePrices = basePrices;
        localInversions = inversions;
    }

    function computeBasketPrice(
        uint256 maxStaleness,
        uint256 maxPublishTimeDivergence
    ) external view returns (uint256, uint256) {
        uint256 minPublishTime = type(uint256).max;
        uint256 maxPublishTime;
        uint256 basketPrice;

        for (uint256 i = 0; i < localPythFeedIds.length; i++) {
            PythStructs.Price memory price = localPyth.getPriceUnsafe(localPythFeedIds[i]);
            if (price.publishTime > block.timestamp || block.timestamp - price.publishTime > maxStaleness) {
                revert IPletherOracle.PletherOracle__StalePrice(
                    IPletherOracle.PriceMode.OrderExecution,
                    localPythFeedIds[i],
                    price.publishTime,
                    maxStaleness,
                    block.timestamp
                );
            }

            uint256 normalized = localInversions[i]
                ? _invertPythPrice(price.price, price.expo)
                : _normalizePythPrice(price.price, price.expo);
            basketPrice += (normalized * localQuantities[i])
                / (localBasePrices[i] * DecimalConstants.CHAINLINK_TO_TOKEN_SCALE);

            if (price.publishTime < minPublishTime) {
                minPublishTime = price.publishTime;
            }
            if (price.publishTime > maxPublishTime) {
                maxPublishTime = price.publishTime;
            }
        }

        if (maxPublishTime > minPublishTime + maxPublishTimeDivergence) {
            revert IPletherOracle.PletherOracle__PublishTimeDivergence(
                IPletherOracle.PriceMode.OrderExecution, minPublishTime, maxPublishTime, maxPublishTimeDivergence
            );
        }
        if (basketPrice == 0) {
            revert IPletherOracle.PletherOracle__ZeroBasketPrice();
        }

        return (basketPrice, minPublishTime);
    }

    function _invertPythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256) {
        if (price <= 0) {
            revert IPletherOracle.PletherOracle__InvalidPrice(bytes32(0), price);
        }
        uint256 positivePrice = uint256(uint64(price));
        uint256 scaledPrecision = 10 ** uint256(uint32(26 - expo));
        uint256 scaledInverse = (scaledPrecision + (positivePrice / 2)) / positivePrice;
        return scaledInverse / 1e18;
    }

    function _normalizePythPrice(
        int64 price,
        int32 expo
    ) internal pure returns (uint256) {
        if (price <= 0) {
            revert IPletherOracle.PletherOracle__InvalidPrice(bytes32(0), price);
        }

        uint256 rawPrice = uint256(uint64(price));
        if (expo == -8) {
            return rawPrice;
        }
        if (expo > -8) {
            return rawPrice * (10 ** uint256(uint32(expo + 8)));
        }
        return rawPrice / (10 ** uint256(uint32(-8 - expo)));
    }

}

contract OracleParityIntegrationTest is Test {

    MockPyth internal mockPyth;

    function setUp() public {
        mockPyth = new MockPyth();
        vm.warp(1001);
    }

    function test_OracleEquivalence_SamePricesSameBasket() public {
        uint256[] memory weights = new uint256[](4);
        weights[0] = 0.4e18;
        weights[1] = 0.2e18;
        weights[2] = 0.25e18;
        weights[3] = 0.15e18;

        int256 eurUsd8 = 108_000_000;
        int256 jpyUsd8 = 638_163;
        int256 gbpUsd8 = 126_000_000;
        int256 chfUsd8 = 113_636_363;

        uint256[] memory basePrices = new uint256[](4);
        basePrices[0] = uint256(eurUsd8);
        basePrices[1] = uint256(jpyUsd8);
        basePrices[2] = uint256(gbpUsd8);
        basePrices[3] = uint256(chfUsd8);

        address[] memory feeds = new address[](4);
        feeds[0] = address(new MockOracle(eurUsd8, "EUR/USD"));
        feeds[1] = address(new MockOracle(jpyUsd8, "JPY/USD"));
        feeds[2] = address(new MockOracle(gbpUsd8, "GBP/USD"));
        feeds[3] = address(new MockOracle(chfUsd8, "CHF/USD"));

        BasketOracle basket = new BasketOracle(feeds, weights, basePrices, 500, 2e8, address(this));
        (, int256 chainlinkPrice,,,) = basket.latestRoundData();

        bytes32[] memory pythIds = new bytes32[](4);
        pythIds[0] = bytes32(uint256(0x01));
        pythIds[1] = bytes32(uint256(0x02));
        pythIds[2] = bytes32(uint256(0x03));
        pythIds[3] = bytes32(uint256(0x04));

        bool[] memory inversions = new bool[](4);
        inversions[1] = true;
        inversions[3] = true;

        OracleParityBasketPriceHarness harness =
            new OracleParityBasketPriceHarness(address(mockPyth), pythIds, weights, basePrices, inversions);

        mockPyth.setPrice(pythIds[0], int64(108_000_000), int32(-8), 1001);
        mockPyth.setPrice(pythIds[1], int64(15_670), int32(-2), 1001);
        mockPyth.setPrice(pythIds[2], int64(126_000_000), int32(-8), 1001);
        mockPyth.setPrice(pythIds[3], int64(8800), int32(-4), 1001);

        (uint256 pythPrice,) = harness.computeBasketPrice(60, 60);

        assertApproxEqAbs(
            uint256(chainlinkPrice), pythPrice, 100, "BasketOracle and OrderRouter must agree within rounding"
        );
    }

}
