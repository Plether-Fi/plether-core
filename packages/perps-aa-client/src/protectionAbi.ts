// Generated from perps v1.2.1 source c3f60f58bcd5dc1b85a28739a5de7ec4a2ee114c. Do not edit.
export const positionProtectionBookAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "router",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "engine",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "ENGINE",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IPositionProtectionEngine"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "ROUTER",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "activate",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "markPrice",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "publishTime",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "linkedOrderId",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "outputs": [
      {
        "name": "plan",
        "type": "tuple",
        "internalType": "struct IPositionProtectionBook.TriggerPlan",
        "components": [
          {
            "name": "account",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "side",
            "type": "uint8",
            "internalType": "enum CfdTypes.Side"
          },
          {
            "name": "size",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "triggerBountyUsdc",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "executionBountyUsdc",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "activePositionProtectionId",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "afterOrderTerminal",
    "inputs": [
      {
        "name": "orderId",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "terminalStatus",
        "type": "uint8",
        "internalType": "enum IOrderRouterAccounting.OrderStatus"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "cancelPositionProtection",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "commitOpenOrderWithProtection",
    "inputs": [
      {
        "name": "request",
        "type": "tuple",
        "internalType": "struct OrderV2Types.OrderRequest",
        "components": [
          {
            "name": "clientOrderId",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "side",
            "type": "uint8",
            "internalType": "enum CfdTypes.Side"
          },
          {
            "name": "sizeDelta",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "marginDelta",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "targetPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "isClose",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "bounds",
            "type": "tuple",
            "internalType": "struct OrderV2Types.ExecutionBounds",
            "components": [
              {
                "name": "validUntil",
                "type": "uint64",
                "internalType": "uint64"
              },
              {
                "name": "allowedExecutionModes",
                "type": "uint8",
                "internalType": "uint8"
              },
              {
                "name": "expectedConfigHash",
                "type": "bytes32",
                "internalType": "bytes32"
              },
              {
                "name": "maxExecutionBountyUsdc",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "maxExecutionNotionalUsdc",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "maxGrossAccountDebitUsdc",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "maxActionChargeUsdc",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "maxExplicitFeesUsdc",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "maxPostPositionSize",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "minPostSettlementBalanceUsdc",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "minPostPositionEquityUsdc",
                "type": "uint256",
                "internalType": "uint256"
              },
              {
                "name": "maxPostLeverageBps",
                "type": "uint32",
                "internalType": "uint32"
              }
            ]
          }
        ]
      },
      {
        "name": "params",
        "type": "tuple",
        "internalType": "struct PositionProtectionTypes.PositionProtectionParams",
        "components": [
          {
            "name": "takeProfitTriggerPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "stopLossTriggerPrice",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "parentOrderId",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "protectionId",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "createPositionProtection",
    "inputs": [
      {
        "name": "params",
        "type": "tuple",
        "internalType": "struct PositionProtectionTypes.PositionProtectionParams",
        "components": [
          {
            "name": "takeProfitTriggerPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "stopLossTriggerPrice",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "failPendingOpenForRiskOff",
    "inputs": [
      {
        "name": "parentOrderId",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "refundableProtectionBountyUsdc",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "forfeitOnLiquidation",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "forfeitedUsdc",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getPositionProtection",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "outputs": [
      {
        "name": "protection",
        "type": "tuple",
        "internalType": "struct PositionProtectionTypes.PositionProtectionView",
        "components": [
          {
            "name": "protectionId",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "parentOrderId",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "linkedOrderId",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "account",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "side",
            "type": "uint8",
            "internalType": "enum CfdTypes.Side"
          },
          {
            "name": "size",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "takeProfitTriggerPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "stopLossTriggerPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "triggerBountyUsdc",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "executionBountyUsdc",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "armedAt",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "armedBlock",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "triggerMarkPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "triggerPublishTime",
            "type": "uint64",
            "internalType": "uint64"
          },
          {
            "name": "triggeredLeg",
            "type": "uint8",
            "internalType": "enum PositionProtectionTypes.PositionProtectionTriggerLeg"
          },
          {
            "name": "status",
            "type": "uint8",
            "internalType": "enum PositionProtectionTypes.PositionProtectionStatus"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "handleFailedProtectionAttempt",
    "inputs": [
      {
        "name": "orderId",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "reason",
        "type": "uint8",
        "internalType": "enum OrderV2Types.TerminalReason"
      },
      {
        "name": "executionBountyUsdc",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "retained",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "nextPositionProtectionId",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "replacePositionProtection",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "params",
        "type": "tuple",
        "internalType": "struct PositionProtectionTypes.PositionProtectionParams",
        "components": [
          {
            "name": "takeProfitTriggerPrice",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "stopLossTriggerPrice",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "retryPositionProtectionClose",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "outputs": [
      {
        "name": "linkedOrderId",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "triggerPositionProtection",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "internalType": "uint64"
      },
      {
        "name": "pythUpdateData",
        "type": "bytes[]",
        "internalType": "bytes[]"
      }
    ],
    "outputs": [
      {
        "name": "linkedOrderId",
        "type": "uint64",
        "internalType": "uint64"
      }
    ],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "unpaidBounties",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "unpaidBountyUsdc",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "LiquidationBatchItem",
    "inputs": [
      {
        "name": "index",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "result",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum IOrderRouterErrors.LiquidationBatchResult"
      },
      {
        "name": "keeperBountyUsdc",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "errorSelector",
        "type": "bytes4",
        "indexed": false,
        "internalType": "bytes4"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "LiquidationBatchStopped",
    "inputs": [
      {
        "name": "nextIndex",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "OrderCommitted",
    "inputs": [
      {
        "name": "orderId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "side",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum CfdTypes.Side"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PositionProtectionArmed",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "side",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum CfdTypes.Side"
      },
      {
        "name": "size",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "armedAt",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      },
      {
        "name": "armedBlock",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PositionProtectionCancelled",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PositionProtectionCloseAttemptFailed",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "linkedOrderId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "reason",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum OrderV2Types.TerminalReason"
      },
      {
        "name": "relatched",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PositionProtectionCloseAttemptQueued",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "linkedOrderId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "previousLinkedOrderId",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PositionProtectionCreated",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "parentOrderId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "takeProfitTriggerPrice",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "stopLossTriggerPrice",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "triggerBountyUsdc",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "executionBountyUsdc",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PositionProtectionReplaced",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "takeProfitTriggerPrice",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "stopLossTriggerPrice",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PositionProtectionTerminal",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "linkedOrderId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "status",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum PositionProtectionTypes.PositionProtectionStatus"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "PositionProtectionTriggered",
    "inputs": [
      {
        "name": "protectionId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "linkedOrderId",
        "type": "uint64",
        "indexed": true,
        "internalType": "uint64"
      },
      {
        "name": "leg",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum PositionProtectionTypes.PositionProtectionTriggerLeg"
      },
      {
        "name": "triggerMarkPrice",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "triggerPublishTime",
        "type": "uint64",
        "indexed": false,
        "internalType": "uint64"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "EnforcedPause",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__AccountQueueCorrupt",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__BatchBeforeQueueHead",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__BatchOrderNotCommitted",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__CloseOnlyWindow",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__CloseWithPositiveMargin",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__CommitValidation",
    "inputs": [
      {
        "name": "code",
        "type": "uint8",
        "internalType": "uint8"
      }
    ]
  },
  {
    "type": "error",
    "name": "OrderRouter__ConditionalTriggerFrozen",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__DegradedMode",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__EmptyFeeds",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__EmptyPythUpdateData",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ExecutionBountyAboveGrossDebit",
    "inputs": [
      {
        "name": "executionBountyUsdc",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "maximumGrossDebitUsdc",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "OrderRouter__ExecutionConfigMismatch",
    "inputs": [
      {
        "name": "expectedConfigHash",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "currentConfigHash",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "OrderRouter__GlobalQueueCorrupt",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InsufficientFreeEquity",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InsufficientGas",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InsufficientPythFee",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidBasePrice",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidEngineLens",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidExecutionModeMask",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidExecutionSidecar",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidKeeperSidecar",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidLifecycleBook",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidLiquidationBatchSize",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidOraclePrice",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidPletherOracle",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidPolicyEvaluator",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidProtectionPrices",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidSizeQuantum",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidValidUntil",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__InvalidWeights",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__LengthMismatch",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__LiquidationOraclePriceTooStale",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__MarginQueueCorrupt",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__MarkPriceOutOfOrder",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__MevDetected",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__MockOracleUnavailable",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__NoOpenPosition",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__NoOrdersToExecute",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__NoQueuedPosition",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__NotInSeedLifecycle",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__OracleConfidenceTooWide",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__OraclePriceTooStale",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__OraclePublishTimesDiverged",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__OrderNotPending",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__OrderNotQueueHead",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__OrderNotRiskOff",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__PendingOrdersExist",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__PositionChanged",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__PredictableOpenInvalid",
    "inputs": [
      {
        "name": "code",
        "type": "uint8",
        "internalType": "uint8"
      }
    ]
  },
  {
    "type": "error",
    "name": "OrderRouter__ProtectionActive",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ProtectionAlreadyActive",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ProtectionDisabled",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ProtectionMarkTooStale",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ProtectionNotArmed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ProtectionNotFound",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ProtectionNotLatched",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ProtectionTriggerAlreadyMet",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__SameBlockTrigger",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__SideMismatch",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__SizeExceedsQueued",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__TooManyPendingOrders",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__TriggerNotMet",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__Unauthorized",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__VaultRiskBlocked",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ZeroClientOrderId",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ZeroPostLeverageBound",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ZeroSize",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OrderRouter__ZeroTargetPrice",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PositionProtectionBook__BountyMismatch",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PositionProtectionBook__InvalidHostResponse",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PositionProtectionBook__InvalidLinkedOrder",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PositionProtectionBook__InvalidTerminalReason",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PositionProtectionBook__ZeroAddress",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  }
] as const;
