// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Interface for price oracles.
interface IOracle {

    /// @notice Returns price of 1 collateral unit in loan asset terms.
    function price() external view returns (uint256);

}

/// @title StakedOracle
/// @notice Prices ERC4626 vault shares by combining underlying price with exchange rate.
/// @dev Price = UnderlyingPrice * ExchangeRate. Used for splDXY-BEAR/splDXY-BULL in Morpho.
contract StakedOracle is IOracle {

    /// @notice The staking vault (splDXY-BEAR or splDXY-BULL).
    IERC4626 public immutable VAULT;

    /// @notice Oracle for the underlying plDXY token.
    IOracle public immutable UNDERLYING_ORACLE;

    /// @notice Decimal multiplier for the underlying asset.
    uint256 public immutable UNDERLYING_DECIMALS;

    /// @notice Thrown when underlying oracle returns zero price.
    error StakedOracle__InvalidPrice();

    /// @notice Thrown when zero address provided to constructor.
    error StakedOracle__ZeroAddress();

    /// @notice Creates staked oracle for a vault.
    /// @param _vault ERC4626 staking vault address.
    /// @param _underlyingOracle Price oracle for the underlying plDXY token.
    constructor(
        address _vault,
        address _underlyingOracle
    ) {
        if (_vault == address(0)) revert StakedOracle__ZeroAddress();
        if (_underlyingOracle == address(0)) revert StakedOracle__ZeroAddress();
        VAULT = IERC4626(_vault);
        UNDERLYING_ORACLE = IOracle(_underlyingOracle);
        UNDERLYING_DECIMALS = 10 ** IERC20Metadata(VAULT.asset()).decimals();
    }

    /// @notice Returns price of 1 vault share including accrued yield.
    /// @return Price scaled to 1e36 (underlying price * exchange rate).
    function price() external view override returns (uint256) {
        uint256 rawPrice = UNDERLYING_ORACLE.price();
        if (rawPrice == 0) revert StakedOracle__InvalidPrice();

        uint256 oneShare = 10 ** IERC20Metadata(address(VAULT)).decimals();
        uint256 assetsPerShare = VAULT.convertToAssets(oneShare);

        return (rawPrice * assetsPerShare) / UNDERLYING_DECIMALS;
    }

}
