// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PythStructs} from "../../src/interfaces/IPyth.sol";

contract MockPyth {

    struct MockPrice {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    mapping(bytes32 => MockPrice) public prices;
    uint256 public mockFee;
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
        prices[feedId] = MockPrice(_price, _conf, _expo, _publishTime);
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
            prices[feedIds[i]] = MockPrice(_price, _conf, _expo, _publishTime);
        }
    }

    function setPrice(
        bytes32 feedId,
        int64 _price,
        int32 _expo,
        uint256 _publishTime
    ) external {
        _registerFeed(feedId);
        prices[feedId] = MockPrice(_price, 0, _expo, _publishTime);
    }

    function setAllPrices(
        bytes32[] memory feedIds,
        int64 _price,
        int32 _expo,
        uint256 _publishTime
    ) external {
        for (uint256 i = 0; i < feedIds.length; i++) {
            _registerFeed(feedIds[i]);
            prices[feedIds[i]] = MockPrice(_price, 0, _expo, _publishTime);
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
            prices[registeredFeedIds[i]] = MockPrice(intPrice, 0, int32(-8), block.timestamp);
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
