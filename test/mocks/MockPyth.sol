// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PythStructs} from "../../src/interfaces/IPyth.sol";

contract MockPyth {

    struct MockPrice {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
        uint256 prevPublishTime;
    }

    mapping(bytes32 => MockPrice) public prices;
    mapping(bytes32 => MockPrice) public uniquePrices;
    mapping(bytes32 => bool) public hasUniquePrice;
    uint256 public mockFee;
    uint256 public parseUniqueCallCount;
    bytes32[] internal registeredFeedIds;
    mapping(bytes32 => bool) internal registeredFeedId;

    function setPrice(
        bytes32 feedId,
        int64 _price,
        uint64 _conf,
        int32 _expo,
        uint256 _publishTime
    ) external {
        _registerFeed(feedId);
        prices[feedId] = MockPrice(_price, _conf, _expo, _publishTime, prices[feedId].publishTime);
    }

    function setAllPrices(
        bytes32[] memory feedIds,
        int64 _price,
        uint64 _conf,
        int32 _expo,
        uint256 _publishTime
    ) external {
        for (uint256 i = 0; i < feedIds.length; i++) {
            _registerFeed(feedIds[i]);
            prices[feedIds[i]] = MockPrice(_price, _conf, _expo, _publishTime, prices[feedIds[i]].publishTime);
        }
    }

    function setUniquePrice(
        bytes32 feedId,
        int64 _price,
        uint64 _conf,
        int32 _expo,
        uint256 _publishTime,
        uint256 _prevPublishTime
    ) external {
        _registerFeed(feedId);
        uniquePrices[feedId] = MockPrice(_price, _conf, _expo, _publishTime, _prevPublishTime);
        hasUniquePrice[feedId] = true;
    }

    function setAllUniquePrices(
        bytes32[] memory feedIds,
        int64 _price,
        uint64 _conf,
        int32 _expo,
        uint256 _publishTime,
        uint256 _prevPublishTime
    ) external {
        for (uint256 i = 0; i < feedIds.length; i++) {
            _registerFeed(feedIds[i]);
            uniquePrices[feedIds[i]] = MockPrice(_price, _conf, _expo, _publishTime, _prevPublishTime);
            hasUniquePrice[feedIds[i]] = true;
        }
    }

    function setPrice(
        bytes32 feedId,
        int64 _price,
        int32 _expo,
        uint256 _publishTime
    ) external {
        _registerFeed(feedId);
        prices[feedId] = MockPrice(_price, 0, _expo, _publishTime, prices[feedId].publishTime);
    }

    function setAllPrices(
        bytes32[] memory feedIds,
        int64 _price,
        int32 _expo,
        uint256 _publishTime
    ) external {
        for (uint256 i = 0; i < feedIds.length; i++) {
            _registerFeed(feedIds[i]);
            prices[feedIds[i]] = MockPrice(_price, 0, _expo, _publishTime, prices[feedIds[i]].publishTime);
        }
    }

    function getPriceUnsafe(
        bytes32 id
    ) external view returns (PythStructs.Price memory) {
        MockPrice memory p = prices[id];
        return PythStructs.Price({price: p.price, conf: p.conf, expo: p.expo, publishTime: p.publishTime});
    }

    function setFee(
        uint256 _fee
    ) external {
        mockFee = _fee;
    }

    function getUpdateFee(
        bytes[] calldata
    ) external view returns (uint256) {
        return mockFee;
    }

    function updatePriceFeeds(
        bytes[] calldata updateData
    ) external payable {
        if (updateData.length == 0 || updateData[0].length != 32) {
            return;
        }

        uint256 price = abi.decode(updateData[0], (uint256));
        int64 intPrice = int64(uint64(price));
        for (uint256 i = 0; i < registeredFeedIds.length; i++) {
            bytes32 feedId = registeredFeedIds[i];
            prices[feedId] = MockPrice(intPrice, 0, int32(-8), block.timestamp, prices[feedId].publishTime);
        }
    }

    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable returns (PythStructs.PriceFeed[] memory priceFeeds) {
        parseUniqueCallCount++;
        bool hasEncodedUpdate = updateData.length > 0 && updateData[0].length == 32;
        uint256 encodedPrice;
        if (hasEncodedUpdate) {
            encodedPrice = abi.decode(updateData[0], (uint256));
        }

        priceFeeds = new PythStructs.PriceFeed[](priceIds.length);
        for (uint256 i = 0; i < priceIds.length; i++) {
            MockPrice memory p;
            if (hasUniquePrice[priceIds[i]]) {
                p = uniquePrices[priceIds[i]];
            } else if (hasEncodedUpdate) {
                p = MockPrice(
                    int64(uint64(encodedPrice)),
                    0,
                    int32(-8),
                    maxPublishTime,
                    minPublishTime == 0 ? 0 : uint256(minPublishTime) - 1
                );
            } else {
                p = prices[priceIds[i]];
            }
            require(p.prevPublishTime < minPublishTime, "not unique");
            require(p.publishTime >= minPublishTime && p.publishTime <= maxPublishTime, "outside range");
            PythStructs.Price memory price =
                PythStructs.Price({price: p.price, conf: p.conf, expo: p.expo, publishTime: p.publishTime});
            priceFeeds[i] = PythStructs.PriceFeed({id: priceIds[i], price: price, emaPrice: price});
        }
    }

    function _registerFeed(
        bytes32 feedId
    ) internal {
        if (registeredFeedId[feedId]) {
            return;
        }
        registeredFeedId[feedId] = true;
        registeredFeedIds.push(feedId);
    }

}
