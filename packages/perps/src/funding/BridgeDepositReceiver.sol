// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IMarginAccount} from "@plether/perps/interfaces/IMarginAccount.sol";

/// @notice Settlement-token binding exposed by the canonical margin clearinghouse.
interface IBridgeDepositClearinghouse {

    function settlementAsset() external view returns (address);

}

/// @title BridgeDepositReceiver
/// @notice Receives bridged USDC and permissionlessly credits one immutable margin beneficiary.
/// @dev No bridge callback, arbitrary execution, owner, or destination setter is required. Tokens may arrive before
///      deployment or in multiple transfers. Only balances still held here can be recovered; after a successful
///      flush, the beneficiary's ordinary clearinghouse withdrawal and carry rules apply. A permissionless flush may
///      execute before a pending recovery transaction. This contract assumes the clearinghouse's standard USDC asset.
/// @custom:security-contact contact@plether.com
contract BridgeDepositReceiver is ReentrancyGuardTransient {

    using SafeERC20 for IERC20;

    error BridgeDepositReceiver__ZeroBeneficiary();
    error BridgeDepositReceiver__InvalidClearinghouse();
    error BridgeDepositReceiver__InvalidToken();
    error BridgeDepositReceiver__SettlementAssetMismatch(address configuredAsset, address suppliedAsset);
    error BridgeDepositReceiver__NotBeneficiary();
    error BridgeDepositReceiver__UseCanonicalRecovery();

    /// @notice Sole margin beneficiary and recovery recipient; may be an EOA or an undeployed smart account.
    address public immutable beneficiary;
    /// @notice Fixed clearinghouse that may pull an exact flush amount into the beneficiary's margin account.
    address public immutable clearinghouse;
    /// @notice Canonical settlement USDC, validated against the clearinghouse at deployment.
    address public immutable usdc;

    event Deposited(address indexed beneficiary, uint256 amount);
    event Recovered(address indexed token, address indexed beneficiary, uint256 amount);

    constructor(
        address beneficiary_,
        address clearinghouse_,
        address usdc_
    ) {
        if (beneficiary_ == address(0)) {
            revert BridgeDepositReceiver__ZeroBeneficiary();
        }
        if (clearinghouse_.code.length == 0) {
            revert BridgeDepositReceiver__InvalidClearinghouse();
        }
        if (usdc_.code.length == 0) {
            revert BridgeDepositReceiver__InvalidToken();
        }
        address configuredAsset = IBridgeDepositClearinghouse(clearinghouse_).settlementAsset();
        if (configuredAsset != usdc_) {
            revert BridgeDepositReceiver__SettlementAssetMismatch(configuredAsset, usdc_);
        }
        beneficiary = beneficiary_;
        clearinghouse = clearinghouse_;
        usdc = usdc_;
    }

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) {
            revert BridgeDepositReceiver__NotBeneficiary();
        }
        _;
    }

    /// @notice Deposits all currently held USDC into the immutable beneficiary's margin account.
    /// @dev Anyone may call, including before or after another arrival. Empty balances are harmless no-ops. Approval
    ///      covers exactly this deposit and is cleared afterward. Any failure atomically restores balance and allowance.
    /// @return deposited USDC amount submitted to the clearinghouse, in the token's native units.
    function flush() external nonReentrant returns (uint256 deposited) {
        IERC20 token = IERC20(usdc);
        deposited = token.balanceOf(address(this));
        if (deposited == 0) {
            return 0;
        }
        token.forceApprove(clearinghouse, deposited);
        IMarginAccount(clearinghouse).depositFor(beneficiary, deposited);
        token.forceApprove(clearinghouse, 0);
        emit Deposited(beneficiary, deposited);
    }

    /// @notice Returns all unflushed canonical USDC to the beneficiary.
    /// @dev Callable only by the beneficiary itself, including through its authenticated smart-account execution.
    function recover() external onlyBeneficiary nonReentrant returns (uint256 recovered) {
        return _recover(IERC20(usdc));
    }

    /// @notice Returns an accidentally received ERC-20 to the beneficiary without permitting redirection.
    /// @dev Canonical USDC uses `recover()`. This contract provides no native-token recovery or arbitrary-call path.
    function recoverToken(
        address token
    ) external onlyBeneficiary nonReentrant returns (uint256 recovered) {
        if (token == usdc) {
            revert BridgeDepositReceiver__UseCanonicalRecovery();
        }
        if (token.code.length == 0) {
            revert BridgeDepositReceiver__InvalidToken();
        }
        return _recover(IERC20(token));
    }

    function _recover(
        IERC20 token
    ) private returns (uint256 recovered) {
        recovered = token.balanceOf(address(this));
        if (recovered != 0) {
            token.safeTransfer(beneficiary, recovered);
            emit Recovered(address(token), beneficiary, recovered);
        }
    }

}
