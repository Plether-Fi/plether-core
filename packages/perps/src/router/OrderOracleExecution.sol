// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ICfdEngineCore} from "@plether/perps/interfaces/ICfdEngineCore.sol";
import {ICfdEngineLens} from "@plether/perps/interfaces/ICfdEngineLens.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";
import {IPletherOracle} from "@plether/perps/interfaces/IPletherOracle.sol";
import {OrderReservationAccounting} from "@plether/perps/router/OrderReservationAccounting.sol";
import {IPyth} from "@plether/shared/interfaces/IPyth.sol";

interface IOrderRouterEngineLensBinding {

    function engineContract() external view returns (address);

}

interface IOrderRouterHousePoolBinding {

    function ENGINE() external view returns (address);

}

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
    /// @dev Requires deployed lens and pool contracts bound to this engine, and a readable pool asset total.
    ///      The oracle is validated for deployed code, nonzero Pyth, and exact engine and HousePool wiring.
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
        if (_engineLens.code.length == 0) {
            revert OrderRouter__InvalidEngineLens();
        }
        engineLens = ICfdEngineLens(_engineLens);
        try engineLens.engine() returns (address lensEngine) {
            if (lensEngine != _engine) {
                revert OrderRouter__InvalidEngineLens();
            }
        } catch {
            revert OrderRouter__InvalidEngineLens();
        }
        try IOrderRouterEngineLensBinding(_engineLens).engineContract() returns (address lensEngine) {
            if (lensEngine != _engine) {
                revert OrderRouter__InvalidEngineLens();
            }
        } catch {
            revert OrderRouter__InvalidEngineLens();
        }
        if (_housePool.code.length == 0) {
            revert OrderRouter__InvalidHousePool();
        }
        housePool = IHousePool(_housePool);
        try IOrderRouterHousePoolBinding(_housePool).ENGINE() returns (address poolEngine) {
            if (poolEngine != _engine) {
                revert OrderRouter__InvalidHousePool();
            }
        } catch {
            revert OrderRouter__InvalidHousePool();
        }
        try housePool.totalAssets() returns (uint256) {}
        catch {
            revert OrderRouter__InvalidHousePool();
        }
        _validateOracleConfig(_pletherOracle);
        pletherOracle = IPletherOracle(_pletherOracle);
    }

    /// @notice Validates a Plether oracle wired to this router's engine and HousePool.
    /// @param newPletherOracle Candidate deployed oracle address.
    function _validateOracleConfig(
        address newPletherOracle
    ) internal view {
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
    }

}
