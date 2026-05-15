// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface IOrderRouterErrors {

    error OrderRouter__ZeroSize();
    error OrderRouter__QueueState(uint8 code);
    error OrderRouter__CommitValidation(uint8 code);
    error OrderRouter__InsufficientGas();
    error OrderRouter__PredictableOpenInvalid(uint8 code);
    error OrderRouter__ZeroEngineLens();
    error OrderRouter__MarkPriceOutOfOrder();
    error OrderRouter__SameBlockExecution(uint64 commitBlock, uint256 currentBlock);
    error OrderRouter__OraclePublishTimeNotAfterCommit(uint64 publishTime, uint64 commitTime);

}
