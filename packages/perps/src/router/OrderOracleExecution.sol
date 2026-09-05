// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {OrderReservationAccounting} from "@plether/perps/router/OrderReservationAccounting.sol";
import {IPyth} from "@plether/shared/interfaces/IPyth.sol";

/// @title OrderOracleExecution
/// @notice Owns and validates the Router oracle, engine lens, and HousePool bindings.
abstract contract OrderOracleExecution is OrderReservationAccounting {

    /// @notice House pool used for execution depth and oracle wiring validation.
    IHousePool internal immutable housePool;
    /// @notice Engine lens used for commit-time open-order preflight classification.
    ICfdEngineLens internal immutable engineLens;
    /// @notice Active Plether oracle used for all router price paths.
    IPletherOracle public pletherOracle;

    /// @notice Binds the router oracle layer to its engine, lens, pool, and initial Plether oracle.
    /// @dev Reverts for a zero engine lens. The oracle is validated for deployed code, nonzero Pyth,
    ///      and exact engine and HousePool wiring; `_housePool` itself is not independently code-checked.
    /// @param _engine Engine used for mark updates and oracle identity validation.
    /// @param _engineLens Engine lens used for open preflight reads.
    /// @param _housePool House pool used for depth and oracle identity validation.
    /// @param _pletherOracle Initial Plether oracle contract.
    constructor(
        address _engine,
        address _engineLens,
        address _housePool,
        address _pletherOracle
    ) OrderReservationAccounting(_engine) {
        if (_engineLens == address(0)) {
            revert OrderRouter__InvalidEngineLens();
        }
        housePool = IHousePool(_housePool);
        engineLens = ICfdEngineLens(_engineLens);
        _setOracleConfig(_pletherOracle);
    }

    /// @notice Validates and installs a Plether oracle wired to this router's engine and HousePool.
    /// @param newPletherOracle Candidate deployed oracle address.
    function _setOracleConfig(
        address newPletherOracle
    ) internal {
        if (newPletherOracle == address(0) || newPletherOracle.code.length == 0) {
            revert OrderRouter__InvalidPletherOracle();
        }
        IPletherOracle oracle = IPletherOracle(newPletherOracle);
        try oracle.pyth() returns (IPyth pyth_) {
            if (address(pyth_) == address(0)) {
                revert OrderRouter__InvalidPletherOracle();
            }
        } catch {
            revert OrderRouter__InvalidPletherOracle();
        }
        try oracle.engine() returns (ICfdEngineCore oracleEngine) {
            if (address(oracleEngine) != address(engine)) {
                revert OrderRouter__InvalidPletherOracle();
            }
        } catch {
            revert OrderRouter__InvalidPletherOracle();
        }
        try oracle.housePool() returns (IHousePool oracleHousePool) {
            if (address(oracleHousePool) != address(housePool)) {
                revert OrderRouter__InvalidPletherOracle();
            }
        } catch {
            revert OrderRouter__InvalidPletherOracle();
        }
        pletherOracle = oracle;
    }

}
