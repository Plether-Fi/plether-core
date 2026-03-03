// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.33;

interface ICurveTwocrypto {

    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 min_mint_amount
    ) external returns (uint256);
    function remove_liquidity_one_coin(
        uint256 token_amount,
        uint256 i,
        uint256 min_amount
    ) external returns (uint256);
    function remove_liquidity(
        uint256 amount,
        uint256[2] calldata min_amounts
    ) external returns (uint256[2] memory);
    function get_virtual_price() external view returns (uint256);
    function lp_price() external view returns (uint256);
    function calc_token_amount(
        uint256[2] calldata amounts,
        bool deposit
    ) external view returns (uint256);
    function calc_withdraw_one_coin(
        uint256 token_amount,
        uint256 i
    ) external view returns (uint256);

}
