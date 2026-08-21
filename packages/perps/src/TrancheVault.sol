// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAsyncTrancheVault} from "@plether/perps/interfaces/IAsyncTrancheVault.sol";
import {IHousePool} from "@plether/perps/interfaces/IHousePool.sol";

/// @title TrancheVault
/// @notice Fully asynchronous ERC-7540-style entry point for one HousePool tranche.
/// @dev The vault escrows request tokens and claim tokens. HousePool alone moves epochs into claimable state.
contract TrancheVault is ERC4626 {

    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant VIRTUAL_SHARES = 1000;

    uint256 public constant DEPOSIT_COOLDOWN = 1 hours;
    uint256 public constant DEPOSIT_EPOCH_DURATION = 1 hours;
    uint256 public constant DEPOSIT_ACTIVATION_EPOCH_DELAY = 2;
    uint256 public constant REDEEM_ACTIVATION_EPOCH_DELAY = 1;

    bytes4 internal constant INTERFACE_ID_ERC165 = 0x01ffc9a7;
    bytes4 internal constant INTERFACE_ID_ERC7575 = 0x2f0a18c5;
    bytes4 internal constant INTERFACE_ID_ERC7575_SHARE = 0xf815c03d;
    bytes4 internal constant INTERFACE_ID_ERC7540_OPERATOR = 0xe3bc4e65;
    bytes4 internal constant INTERFACE_ID_ERC7540_DEPOSIT = 0xce3bbe50;
    bytes4 internal constant INTERFACE_ID_ERC7540_REDEEM = 0x620ee8e4;

    IHousePool public immutable POOL;
    bool public immutable IS_SENIOR;

    /// @dev Kept at its legacy five-field shape so the generated getter remains source-compatible.
    struct DepositEpoch {
        uint256 assets;
        uint256 shares;
        uint256 claimedAssets;
        uint256 claimedShares;
        bool finalized;
    }

    struct EpochQueueState {
        uint256 previousEpoch;
        uint256 nextEpoch;
        bool queued;
        bool rejected;
    }

    struct RedeemEpoch {
        uint256 shares;
        uint256 fundedShares;
        uint256 fundedAssets;
        uint256 claimedShares;
        uint256 claimedAssets;
        uint256 refundableShares;
        uint256 refundedShares;
        uint256 fundingBasisClaimed;
        uint256 refundBasisClaimed;
        bool refundEnabled;
    }

    struct DepositPosition {
        uint256 assets;
        uint256 claimedAssets;
        uint256 claimedShares;
        uint256 previousRequestId;
        uint256 nextRequestId;
        bool queued;
    }

    struct RedeemPosition {
        uint256 shares;
        uint256 claimedShares;
        uint256 claimedAssets;
        uint256 refundedShares;
        uint256 previousRequestId;
        uint256 nextRequestId;
        bool queued;
        bool fundingClaimed;
        bool refundClaimed;
    }

    /// @dev Helpers retained for exact overflow-safe frozen mint estimates.
    struct Uint768 {
        uint256 high;
        uint256 middle;
        uint256 low;
    }

    mapping(address => uint256) public lastDepositTime;
    mapping(address controller => mapping(address operator => bool approved)) public isOperator;
    mapping(uint256 => DepositEpoch) public depositEpochs;
    mapping(uint256 => EpochQueueState) public depositEpochQueueState;
    mapping(uint256 => RedeemEpoch) public redeemEpochs;
    mapping(uint256 => EpochQueueState) public redeemEpochQueueState;
    mapping(address => mapping(uint256 => DepositPosition)) public depositRequests;
    mapping(address => mapping(uint256 => RedeemPosition)) public redeemRequests;

    /// @notice Legacy contribution-basis getter, cleared only by claim or refund.
    mapping(address => mapping(uint256 => uint256)) public pendingDepositAssets;

    uint256 public depositQueueHead;
    uint256 public depositQueueTail;
    uint256 public redeemQueueHead;
    uint256 public redeemQueueTail;
    mapping(address => uint256) public controllerDepositHead;
    mapping(address => uint256) public controllerDepositTail;
    mapping(address => uint256) public controllerRedeemHead;
    mapping(address => uint256) public controllerRedeemTail;

    uint256 public pendingDepositEscrowAssets;
    uint256 public pendingRedeemEscrowShares;
    uint256 public depositClaimEscrowShares;
    uint256 public withdrawalEscrowAssets;

    address public seedReceiver;
    uint256 public seedShareFloor;

    error TrancheVault__AsyncOnly();
    error TrancheVault__AsyncPreviewUnavailable();
    error TrancheVault__DepositCooldown();
    error TrancheVault__TransferDuringCooldown();
    error TrancheVault__NotPool();
    error TrancheVault__NotControllerOrOperator();
    error TrancheVault__SeedFloorBreached();
    error TrancheVault__InvalidSeedPosition();
    error TrancheVault__TerminallyWiped();
    error TrancheVault__TradingNotActive();
    error TrancheVault__DepositTooSmall();
    error TrancheVault__WithdrawalTooSmall();
    error TrancheVault__DepositsUnavailable();
    error TrancheVault__ExceededMaxRequestDeposit(address controller, uint256 assets, uint256 maxAssets);
    error TrancheVault__ExceededMaxRequestRedeem(address owner, uint256 shares, uint256 maxShares);
    error TrancheVault__DepositEpochNotActive();
    error TrancheVault__DepositEpochAlreadyActive();
    error TrancheVault__DepositEpochFinalized();
    error TrancheVault__DepositEpochNotFinalized();
    error TrancheVault__DepositEpochEmpty();
    error TrancheVault__NoPendingDeposit();
    error TrancheVault__NoPendingRedeem();
    error TrancheVault__ClaimSharesZero();
    error TrancheVault__ZeroAddress();
    error TrancheVault__InvalidEpochHead();
    error TrancheVault__InvalidEpochFunding();
    error TrancheVault__RedeemCancellationUnavailable();
    error TrancheVault__RedeemRefundUnavailable();
    error TrancheVault__EscrowInvariant();
    error TrancheVault__InvalidFee();
    // Compatibility error declarations retained for downstream source references.
    error TrancheVault__TrancheImpaired();
    /// @dev Prevents an unapproved sender from resetting an existing holder's whole-balance cooldown with dust shares.
    error TrancheVault__ThirdPartyDepositForExistingHolder();

    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event DepositRequested(address indexed caller, address indexed owner, uint256 indexed epochId, uint256 assets);
    event DepositRequestCancelled(address indexed owner, uint256 indexed epochId, uint256 assets);
    event AsyncDepositRequestCancelled(
        address indexed controller, address indexed receiver, uint256 indexed epochId, uint256 assets
    );
    event RedeemRequestCancelled(
        address indexed controller, address indexed receiver, uint256 indexed epochId, uint256 shares
    );
    event DepositEpochFinalized(uint256 indexed epochId, bool indexed isSenior, uint256 assets, uint256 shares);
    event DepositEpochRejected(uint256 indexed epochId, bool indexed isSenior, uint256 assets);
    event RedeemEpochFunded(uint256 indexed epochId, bool indexed isSenior, uint256 shares, uint256 assets);
    event RedeemEpochRefundable(uint256 indexed epochId, bool indexed isSenior, uint256 shares);
    event DepositSharesClaimed(address indexed owner, uint256 indexed epochId, uint256 assets, uint256 shares);
    event AsyncDepositSharesClaimed(
        address indexed controller, address indexed receiver, uint256 indexed epochId, uint256 assets, uint256 shares
    );
    event RedeemAssetsClaimed(
        address indexed controller, address indexed receiver, uint256 indexed epochId, uint256 shares, uint256 assets
    );
    event RedeemSharesRefunded(
        address indexed controller, address indexed receiver, uint256 indexed epochId, uint256 shares
    );

    modifier onlyPool() {
        if (msg.sender != address(POOL)) {
            revert TrancheVault__NotPool();
        }
        _;
    }

    constructor(
        IERC20 _usdc,
        address _pool,
        bool _isSenior,
        string memory _name,
        string memory _symbol
    ) ERC4626(_usdc) ERC20(_name, _symbol) {
        POOL = IHousePool(_pool);
        IS_SENIOR = _isSenior;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    function share() external view returns (address) {
        return address(this);
    }

    /// @notice ERC-7575 share-token lookup. This vault is its own share token.
    function vault(
        address asset_
    ) external view returns (address) {
        return asset_ == asset() ? address(this) : address(0);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) external pure returns (bool) {
        return interfaceId == INTERFACE_ID_ERC165 || interfaceId == INTERFACE_ID_ERC7575
            || interfaceId == INTERFACE_ID_ERC7575_SHARE || interfaceId == INTERFACE_ID_ERC7540_OPERATOR
            || interfaceId == INTERFACE_ID_ERC7540_DEPOSIT || interfaceId == INTERFACE_ID_ERC7540_REDEEM
            || interfaceId == type(IAsyncTrancheVault).interfaceId;
    }

    function setOperator(
        address operator,
        bool approved
    ) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (from == seedReceiver && from != address(0) && balanceOf(from) - amount < seedShareFloor) {
            revert TrancheVault__SeedFloorBreached();
        }
        if (from != address(0) && to != address(0) && from != address(this)) {
            if (block.timestamp < lastDepositTime[from] + DEPOSIT_COOLDOWN) {
                revert TrancheVault__TransferDuringCooldown();
            }
            if (lastDepositTime[to] < lastDepositTime[from]) {
                lastDepositTime[to] = lastDepositTime[from];
            }
        }
        super._update(from, to, amount);
    }

    function totalAssets() public view override returns (uint256) {
        (uint256 seniorPrincipalUsdc, uint256 juniorPrincipalUsdc,,) = POOL.getPendingTrancheState();
        return IS_SENIOR ? seniorPrincipalUsdc : juniorPrincipalUsdc;
    }

    function convertToShares(
        uint256 assets
    ) public view override returns (uint256) {
        return _convertToSharesUsingAssets(assets, _depositPricingAssets(), Math.Rounding.Floor);
    }

    function currentLpEpoch() public view returns (uint256) {
        return POOL.currentLpEpoch();
    }

    function currentDepositEpoch() public view returns (uint256) {
        return currentLpEpoch();
    }

    function depositEpochStart(
        uint256 epochId
    ) public view returns (uint256) {
        return POOL.lpEpochStart(epochId);
    }

    // ---------------------------------------------------------------------
    // Requests and status views
    // ---------------------------------------------------------------------

    function requestDeposit(
        uint256 assets,
        address receiver
    ) external returns (uint256 requestId) {
        return _requestDeposit(assets, receiver, msg.sender);
    }

    function requestDeposit(
        uint256 assets,
        address controller,
        address owner
    ) public returns (uint256 requestId) {
        return _requestDeposit(assets, controller, owner);
    }

    function _requestDeposit(
        uint256 assets,
        address controller,
        address owner
    ) internal returns (uint256 requestId) {
        _requireRequestDepositPreflight(assets, controller, owner);
        if (IS_SENIOR) {
            POOL.reserveSeniorDeposit(assets);
        }
        IERC20(asset()).safeTransferFrom(owner, address(this), assets);

        requestId = currentLpEpoch() + DEPOSIT_ACTIVATION_EPOCH_DELAY;
        DepositEpoch storage epoch = depositEpochs[requestId];
        if (!depositEpochQueueState[requestId].queued) {
            _appendDepositEpoch(requestId);
        }
        DepositPosition storage position = depositRequests[controller][requestId];
        if (!position.queued) {
            _appendControllerDeposit(controller, requestId);
        }
        epoch.assets += assets;
        position.assets += assets;
        pendingDepositAssets[controller][requestId] += assets;
        pendingDepositEscrowAssets += assets;

        emit DepositRequest(controller, owner, requestId, msg.sender, assets);
        emit DepositRequested(msg.sender, controller, requestId, assets);
    }

    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) external returns (uint256 requestId) {
        if (controller == address(0) || owner == address(0)) {
            revert TrancheVault__ZeroAddress();
        }
        if (shares == 0) {
            revert TrancheVault__WithdrawalTooSmall();
        }
        if (block.timestamp < lastDepositTime[owner] + DEPOSIT_COOLDOWN) {
            revert TrancheVault__DepositCooldown();
        }
        uint256 maxShares = maxRequestRedeem(owner);
        if (shares > maxShares) {
            revert TrancheVault__ExceededMaxRequestRedeem(owner, shares, maxShares);
        }
        if (estimateRedeemAssets(shares) < POOL.minTrancheDepositUsdc() && shares < maxShares) {
            revert TrancheVault__WithdrawalTooSmall();
        }
        if (msg.sender != owner && !isOperator[owner][msg.sender]) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _transfer(owner, address(this), shares);

        requestId = currentLpEpoch() + REDEEM_ACTIVATION_EPOCH_DELAY;
        RedeemEpoch storage epoch = redeemEpochs[requestId];
        if (!redeemEpochQueueState[requestId].queued) {
            _appendRedeemEpoch(requestId);
        }
        RedeemPosition storage position = redeemRequests[controller][requestId];
        if (!position.queued) {
            _appendControllerRedeem(controller, requestId);
        }
        epoch.shares += shares;
        position.shares += shares;
        pendingRedeemEscrowShares += shares;
        emit RedeemRequest(controller, owner, requestId, msg.sender, shares);
    }

    function pendingDepositRequest(
        uint256 requestId,
        address controller
    ) public view returns (uint256) {
        if (depositEpochs[requestId].finalized || depositEpochQueueState[requestId].rejected) {
            return 0;
        }
        return depositRequests[controller][requestId].assets;
    }

    function refundableDepositRequest(
        uint256 requestId,
        address controller
    ) public view returns (uint256) {
        if (!depositEpochQueueState[requestId].rejected) {
            return 0;
        }
        DepositPosition storage position = depositRequests[controller][requestId];
        return position.assets - position.claimedAssets;
    }

    function claimableDepositRequest(
        uint256 requestId,
        address controller
    ) public view returns (uint256) {
        if (!depositEpochs[requestId].finalized) {
            return 0;
        }
        DepositPosition storage position = depositRequests[controller][requestId];
        return position.assets > position.claimedAssets ? position.assets - position.claimedAssets : 0;
    }

    function claimableDepositShares(
        uint256 requestId,
        address controller
    ) public view returns (uint256) {
        DepositEpoch storage epoch = depositEpochs[requestId];
        if (!epoch.finalized || epoch.assets == 0) {
            return 0;
        }
        DepositPosition storage position = depositRequests[controller][requestId];
        uint256 entitled = Math.mulDiv(position.assets, epoch.shares, epoch.assets, Math.Rounding.Floor);
        return entitled > position.claimedShares ? entitled - position.claimedShares : 0;
    }

    function pendingRedeemRequest(
        uint256 requestId,
        address controller
    ) public view returns (uint256) {
        RedeemEpoch storage epoch = redeemEpochs[requestId];
        if (epoch.refundEnabled) {
            return 0;
        }
        RedeemPosition storage position = redeemRequests[controller][requestId];
        if (position.shares == 0 || epoch.shares == 0) {
            return 0;
        }
        uint256 entitled = Math.mulDiv(position.shares, epoch.fundedShares, epoch.shares, Math.Rounding.Floor);
        return position.shares > entitled ? position.shares - entitled : 0;
    }

    function claimableRedeemRequest(
        uint256 requestId,
        address controller
    ) public view returns (uint256) {
        RedeemEpoch storage epoch = redeemEpochs[requestId];
        RedeemPosition storage position = redeemRequests[controller][requestId];
        if (position.shares == 0 || epoch.shares == 0) {
            return 0;
        }
        uint256 entitled = Math.mulDiv(position.shares, epoch.fundedShares, epoch.shares, Math.Rounding.Floor);
        return entitled > position.claimedShares ? entitled - position.claimedShares : 0;
    }

    function claimableRedeemAssets(
        uint256 requestId,
        address controller
    ) public view returns (uint256) {
        RedeemEpoch storage epoch = redeemEpochs[requestId];
        RedeemPosition storage position = redeemRequests[controller][requestId];
        if (position.shares == 0 || epoch.shares == 0) {
            return 0;
        }
        uint256 entitledShares = Math.mulDiv(position.shares, epoch.fundedShares, epoch.shares, Math.Rounding.Floor);
        if (entitledShares == 0) {
            return 0;
        }
        uint256 entitled = Math.mulDiv(position.shares, epoch.fundedAssets, epoch.shares, Math.Rounding.Floor);
        return entitled > position.claimedAssets ? entitled - position.claimedAssets : 0;
    }

    function refundableRedeemRequest(
        uint256 requestId,
        address controller
    ) public view returns (uint256 shares) {
        RedeemEpoch storage epoch = redeemEpochs[requestId];
        RedeemPosition storage position = redeemRequests[controller][requestId];
        if (!epoch.refundEnabled || position.refundClaimed || position.shares == 0) {
            return 0;
        }
        shares = Math.mulDiv(position.shares, epoch.refundableShares, epoch.shares, Math.Rounding.Floor);
        return shares > position.refundedShares ? shares - position.refundedShares : 0;
    }

    function redeemRefundPending(
        uint256 requestId,
        address controller
    ) public view returns (bool) {
        RedeemPosition storage position = redeemRequests[controller][requestId];
        return redeemEpochs[requestId].refundEnabled && position.shares != 0 && !position.refundClaimed;
    }

    // ---------------------------------------------------------------------
    // Cancellation and zero-value refunds
    // ---------------------------------------------------------------------

    function cancelPendingDeposit(
        uint256 requestId
    ) external returns (uint256 assets) {
        return cancelPendingDeposit(requestId, msg.sender, msg.sender);
    }

    function cancelPendingDeposit(
        uint256 requestId,
        address receiver,
        address controller
    ) public returns (uint256 assets) {
        _requireControllerAuth(controller);
        if (receiver == address(0)) {
            revert TrancheVault__ZeroAddress();
        }
        DepositEpoch storage epoch = depositEpochs[requestId];
        EpochQueueState storage queueState = depositEpochQueueState[requestId];
        if (epoch.finalized) {
            revert TrancheVault__DepositEpochFinalized();
        }
        if (currentLpEpoch() >= requestId && !queueState.rejected) {
            bool reservationsWithinLimits = !IS_SENIOR || POOL.areSeniorDepositReservationsWithinLimits();
            if (!POOL.isSeniorImpairedAfterPendingDepositReconcile() && reservationsWithinLimits) {
                revert TrancheVault__DepositEpochAlreadyActive();
            }
        }
        DepositPosition storage position = depositRequests[controller][requestId];
        assets = position.assets;
        if (assets == 0) {
            revert TrancheVault__NoPendingDeposit();
        }
        _removeControllerDeposit(controller, requestId);
        position.assets = 0;
        pendingDepositAssets[controller][requestId] = 0;
        epoch.assets -= assets;
        pendingDepositEscrowAssets -= assets;
        if (epoch.assets == 0 && queueState.queued) {
            _removeDepositEpoch(requestId);
        }
        if (IS_SENIOR && !queueState.rejected) {
            POOL.releaseSeniorDepositReservation(assets);
        }
        IERC20(asset()).safeTransfer(receiver, assets);
        emit DepositRequestCancelled(controller, requestId, assets);
        emit AsyncDepositRequestCancelled(controller, receiver, requestId, assets);
    }

    function cancelRedeemRequest(
        uint256 requestId,
        address receiver
    ) external returns (uint256 shares) {
        return cancelRedeemRequest(requestId, receiver, msg.sender);
    }

    function cancelRedeemRequest(
        uint256 requestId,
        address receiver,
        address controller
    ) public returns (uint256 shares) {
        _requireControllerAuth(controller);
        if (receiver == address(0)) {
            revert TrancheVault__ZeroAddress();
        }
        RedeemEpoch storage epoch = redeemEpochs[requestId];
        if (currentLpEpoch() >= requestId || epoch.fundedShares != 0 || epoch.fundedAssets != 0 || epoch.refundEnabled)
        {
            revert TrancheVault__RedeemCancellationUnavailable();
        }
        RedeemPosition storage position = redeemRequests[controller][requestId];
        shares = position.shares;
        if (shares == 0) {
            revert TrancheVault__NoPendingRedeem();
        }
        _requireShareReceiver(controller, receiver);
        _removeControllerRedeem(controller, requestId);
        position.shares = 0;
        epoch.shares -= shares;
        pendingRedeemEscrowShares -= shares;
        if (epoch.shares == 0) {
            _removeRedeemEpoch(requestId);
        }
        lastDepositTime[receiver] = block.timestamp;
        _transfer(address(this), receiver, shares);
        emit RedeemRequestCancelled(controller, receiver, requestId, shares);
    }

    function claimRedeemRefund(
        uint256 requestId,
        address receiver,
        address controller
    ) external returns (uint256 shares) {
        _requireControllerAuth(controller);
        if (receiver == address(0)) {
            revert TrancheVault__ZeroAddress();
        }
        RedeemEpoch storage epoch = redeemEpochs[requestId];
        RedeemPosition storage position = redeemRequests[controller][requestId];
        if (!epoch.refundEnabled || position.refundClaimed || position.shares == 0) {
            revert TrancheVault__RedeemRefundUnavailable();
        }
        shares = refundableRedeemRequest(requestId, controller);
        position.refundClaimed = true;
        epoch.refundBasisClaimed += position.shares;
        if (shares != 0) {
            _requireShareReceiver(controller, receiver);
            position.refundedShares += shares;
            epoch.refundedShares += shares;
            pendingRedeemEscrowShares -= shares;
        }
        _maybeProcessRedeemFunding(controller, requestId);
        _sweepRedeemRefundDust(epoch);
        _maybeCloseRedeemPosition(controller, requestId);
        if (shares != 0) {
            lastDepositTime[receiver] = block.timestamp;
            _transfer(address(this), receiver, shares);
        }
        emit RedeemSharesRefunded(controller, receiver, requestId, shares);
    }

    // ---------------------------------------------------------------------
    // Claim functions
    // ---------------------------------------------------------------------

    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256 shares) {
        return _claimDeposit(controllerDepositHead[msg.sender], assets, receiver, msg.sender);
    }

    function deposit(
        uint256 assets,
        address receiver,
        address controller
    ) external returns (uint256 shares) {
        return _claimDeposit(controllerDepositHead[controller], assets, receiver, controller);
    }

    function claimDeposit(
        uint256 requestId,
        uint256 assets,
        address receiver,
        address controller
    ) public returns (uint256 shares) {
        return _claimDeposit(requestId, assets, receiver, controller);
    }

    function claimDepositShares(
        uint256 requestId
    ) external returns (uint256 shares) {
        return _claimDeposit(requestId, claimableDepositRequest(requestId, msg.sender), msg.sender, msg.sender);
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256 assets) {
        return _claimMint(controllerDepositHead[msg.sender], shares, receiver, msg.sender);
    }

    function mint(
        uint256 shares,
        address receiver,
        address controller
    ) external returns (uint256 assets) {
        return _claimMint(controllerDepositHead[controller], shares, receiver, controller);
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address controller
    ) public override returns (uint256 shares) {
        return _claimWithdraw(controllerRedeemHead[controller], assets, receiver, controller);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address controller
    ) public override returns (uint256 assets) {
        return _claimRedeem(controllerRedeemHead[controller], shares, receiver, controller);
    }

    function claimRedeem(
        uint256 requestId,
        uint256 shares,
        address receiver,
        address controller
    ) public returns (uint256 assets) {
        return _claimRedeem(requestId, shares, receiver, controller);
    }

    function _claimDeposit(
        uint256 requestId,
        uint256 assets,
        address receiver,
        address controller
    ) internal returns (uint256 shares) {
        _requireControllerAuth(controller);
        if (receiver == address(0)) {
            revert TrancheVault__ZeroAddress();
        }
        DepositEpoch storage epoch = depositEpochs[requestId];
        if (!epoch.finalized) {
            revert TrancheVault__DepositEpochNotFinalized();
        }
        DepositPosition storage position = depositRequests[controller][requestId];
        uint256 remainingAssets = position.assets - position.claimedAssets;
        uint256 remainingShares = claimableDepositShares(requestId, controller);
        if (assets == 0 || assets > remainingAssets) {
            revert ERC4626ExceededMaxDeposit(controller, assets, remainingAssets);
        }
        if (assets == remainingAssets) {
            shares = remainingShares;
        } else {
            shares = Math.mulDiv(assets, epoch.shares, epoch.assets, Math.Rounding.Floor);
            if (shares > remainingShares) {
                shares = remainingShares;
            }
        }
        if (shares == 0 && assets != remainingAssets) {
            revert TrancheVault__ClaimSharesZero();
        }
        if (shares != 0) {
            _requireShareReceiver(controller, receiver);
        }
        _consumeDepositClaim(requestId, assets, shares, receiver, controller);
    }

    function _claimMint(
        uint256 requestId,
        uint256 shares,
        address receiver,
        address controller
    ) internal returns (uint256 assets) {
        _requireControllerAuth(controller);
        if (receiver == address(0)) {
            revert TrancheVault__ZeroAddress();
        }
        DepositEpoch storage epoch = depositEpochs[requestId];
        if (!epoch.finalized) {
            revert TrancheVault__DepositEpochNotFinalized();
        }
        DepositPosition storage position = depositRequests[controller][requestId];
        uint256 remainingShares = claimableDepositShares(requestId, controller);
        uint256 remainingAssets = position.assets - position.claimedAssets;
        if (shares == 0 || shares > remainingShares) {
            revert ERC4626ExceededMaxMint(controller, shares, remainingShares);
        }
        if (shares == remainingShares) {
            assets = remainingAssets;
        } else {
            assets = Math.mulDiv(shares, epoch.assets, epoch.shares, Math.Rounding.Ceil);
            if (assets >= remainingAssets) {
                revert ERC4626ExceededMaxMint(controller, shares, remainingShares);
            }
        }
        if (assets > remainingAssets) {
            revert ERC4626ExceededMaxMint(controller, shares, remainingShares);
        }
        _requireShareReceiver(controller, receiver);
        _consumeDepositClaim(requestId, assets, shares, receiver, controller);
    }

    function _consumeDepositClaim(
        uint256 requestId,
        uint256 assets,
        uint256 shares,
        address receiver,
        address controller
    ) internal {
        DepositEpoch storage epoch = depositEpochs[requestId];
        DepositPosition storage position = depositRequests[controller][requestId];
        position.claimedAssets += assets;
        position.claimedShares += shares;
        epoch.claimedAssets += assets;
        epoch.claimedShares += shares;
        depositClaimEscrowShares -= shares;
        pendingDepositAssets[controller][requestId] = position.assets - position.claimedAssets;
        uint256 positionEntitlement = Math.mulDiv(position.assets, epoch.shares, epoch.assets, Math.Rounding.Floor);
        if (position.claimedAssets == position.assets && position.claimedShares == positionEntitlement) {
            _removeControllerDeposit(controller, requestId);
        }
        if (epoch.claimedAssets == epoch.assets) {
            uint256 shareDust = epoch.shares - epoch.claimedShares;
            if (shareDust != 0) {
                epoch.claimedShares += shareDust;
                depositClaimEscrowShares -= shareDust;
                _burn(address(this), shareDust);
            }
        }
        if (shares != 0) {
            lastDepositTime[receiver] = block.timestamp;
            _transfer(address(this), receiver, shares);
        }
        // ERC-7540 reinterprets the first ERC-4626 Deposit field as the request controller, including operator claims.
        emit Deposit(controller, receiver, assets, shares);
        emit DepositSharesClaimed(controller, requestId, assets, shares);
        emit AsyncDepositSharesClaimed(controller, receiver, requestId, assets, shares);
    }

    function _claimRedeem(
        uint256 requestId,
        uint256 shares,
        address receiver,
        address controller
    ) internal returns (uint256 assets) {
        _requireControllerAuth(controller);
        if (receiver == address(0)) {
            revert TrancheVault__ZeroAddress();
        }
        uint256 remainingShares = claimableRedeemRequest(requestId, controller);
        uint256 remainingAssets = claimableRedeemAssets(requestId, controller);
        if (shares == 0 || shares > remainingShares) {
            revert ERC4626ExceededMaxRedeem(controller, shares, remainingShares);
        }
        assets = shares == remainingShares
            ? remainingAssets
            : Math.mulDiv(shares, remainingAssets, remainingShares, Math.Rounding.Floor);
        _consumeRedeemClaim(requestId, shares, assets, receiver, controller);
    }

    function _claimWithdraw(
        uint256 requestId,
        uint256 assets,
        address receiver,
        address controller
    ) internal returns (uint256 shares) {
        _requireControllerAuth(controller);
        if (receiver == address(0)) {
            revert TrancheVault__ZeroAddress();
        }
        uint256 remainingShares = claimableRedeemRequest(requestId, controller);
        uint256 remainingAssets = claimableRedeemAssets(requestId, controller);
        if (assets == 0 || assets > remainingAssets) {
            revert ERC4626ExceededMaxWithdraw(controller, assets, remainingAssets);
        }
        if (assets == remainingAssets) {
            shares = remainingShares;
        } else {
            shares = Math.mulDiv(assets, remainingShares, remainingAssets, Math.Rounding.Ceil);
            if (shares >= remainingShares) {
                revert ERC4626ExceededMaxWithdraw(controller, assets, remainingAssets);
            }
        }
        _consumeRedeemClaim(requestId, shares, assets, receiver, controller);
    }

    function _consumeRedeemClaim(
        uint256 requestId,
        uint256 shares,
        uint256 assets,
        address receiver,
        address controller
    ) internal {
        RedeemEpoch storage epoch = redeemEpochs[requestId];
        RedeemPosition storage position = redeemRequests[controller][requestId];
        position.claimedShares += shares;
        position.claimedAssets += assets;
        epoch.claimedShares += shares;
        epoch.claimedAssets += assets;
        withdrawalEscrowAssets -= assets;
        _maybeProcessRedeemFunding(controller, requestId);
        _maybeCloseRedeemPosition(controller, requestId);
        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
        emit RedeemAssetsClaimed(controller, receiver, requestId, shares, assets);
    }

    function _maybeCloseRedeemPosition(
        address controller,
        uint256 requestId
    ) internal {
        RedeemEpoch storage epoch = redeemEpochs[requestId];
        RedeemPosition storage position = redeemRequests[controller][requestId];
        bool terminal = epoch.refundEnabled || epoch.fundedShares == epoch.shares;
        bool refundProcessed = !epoch.refundEnabled || position.refundClaimed;
        if (position.queued && terminal && position.fundingClaimed && refundProcessed) {
            _removeControllerRedeem(controller, requestId);
        }
    }

    function _maybeProcessRedeemFunding(
        address controller,
        uint256 requestId
    ) internal {
        RedeemEpoch storage epoch = redeemEpochs[requestId];
        RedeemPosition storage position = redeemRequests[controller][requestId];
        if (position.fundingClaimed || (!epoch.refundEnabled && epoch.fundedShares != epoch.shares)) {
            return;
        }

        uint256 entitledShares = Math.mulDiv(position.shares, epoch.fundedShares, epoch.shares, Math.Rounding.Floor);
        uint256 entitledAssets = entitledShares == 0
            ? 0
            : Math.mulDiv(position.shares, epoch.fundedAssets, epoch.shares, Math.Rounding.Floor);
        if (position.claimedShares != entitledShares || position.claimedAssets != entitledAssets) {
            return;
        }

        position.fundingClaimed = true;
        epoch.fundingBasisClaimed += position.shares;
        if (epoch.fundingBasisClaimed == epoch.shares) {
            uint256 shareDust = epoch.fundedShares - epoch.claimedShares;
            if (shareDust != 0) {
                epoch.claimedShares += shareDust;
            }
            uint256 assetDust = epoch.fundedAssets - epoch.claimedAssets;
            if (assetDust != 0) {
                epoch.claimedAssets += assetDust;
                withdrawalEscrowAssets -= assetDust;
                IERC20(asset()).safeTransfer(address(POOL), assetDust);
            }
        }
    }

    function _sweepRedeemRefundDust(
        RedeemEpoch storage epoch
    ) internal {
        if (epoch.refundBasisClaimed != epoch.shares) {
            return;
        }
        uint256 shareDust = epoch.refundableShares - epoch.refundedShares;
        if (shareDust == 0) {
            return;
        }
        if (seedReceiver == address(0)) {
            revert TrancheVault__InvalidSeedPosition();
        }
        epoch.refundedShares += shareDust;
        pendingRedeemEscrowShares -= shareDust;
        _transfer(address(this), seedReceiver, shareDust);
    }

    // ---------------------------------------------------------------------
    // ERC-4626 claim limits and explicit estimates
    // ---------------------------------------------------------------------

    function maxDeposit(
        address controller
    ) public view override returns (uint256) {
        uint256 requestId = controllerDepositHead[controller];
        return requestId == 0 ? 0 : claimableDepositRequest(requestId, controller);
    }

    function maxMint(
        address controller
    ) public view override returns (uint256) {
        uint256 requestId = controllerDepositHead[controller];
        return requestId == 0 ? 0 : claimableDepositShares(requestId, controller);
    }

    function maxWithdraw(
        address controller
    ) public view override returns (uint256) {
        uint256 requestId = controllerRedeemHead[controller];
        return requestId == 0 ? 0 : claimableRedeemAssets(requestId, controller);
    }

    function maxRedeem(
        address controller
    ) public view override returns (uint256) {
        uint256 requestId = controllerRedeemHead[controller];
        return requestId == 0 ? 0 : claimableRedeemRequest(requestId, controller);
    }

    function maxRequestDeposit(
        address controller
    ) public view returns (uint256) {
        controller;
        if (_isTerminallyWiped() || !POOL.canAcceptTrancheDeposits(IS_SENIOR)) {
            return 0;
        }
        if (IS_SENIOR) {
            return _seniorDepositCapacity();
        }
        return type(uint256).max;
    }

    function maxRequestRedeem(
        address owner
    ) public view returns (uint256) {
        if (block.timestamp < lastDepositTime[owner] + DEPOSIT_COOLDOWN) {
            return 0;
        }
        return _unlockedOwnerShares(owner);
    }

    function previewDeposit(
        uint256
    ) public pure override returns (uint256) {
        revert TrancheVault__AsyncPreviewUnavailable();
    }

    function previewMint(
        uint256
    ) public pure override returns (uint256) {
        revert TrancheVault__AsyncPreviewUnavailable();
    }

    function previewWithdraw(
        uint256
    ) public pure override returns (uint256) {
        revert TrancheVault__AsyncPreviewUnavailable();
    }

    function previewRedeem(
        uint256
    ) public pure override returns (uint256) {
        revert TrancheVault__AsyncPreviewUnavailable();
    }

    function estimateDepositShares(
        uint256 assets
    ) public view returns (uint256) {
        return quoteDepositFromState(assets, _depositPricingAssets(), totalSupply(), _frozenLpFeeBps());
    }

    function estimateMintAssets(
        uint256 shares
    ) external view returns (uint256) {
        uint256 feeBps = _frozenLpFeeBps();
        return feeBps == 0 ? _previewMintAssets(shares) : _previewFrozenMintAssets(shares, feeBps);
    }

    function estimateWithdrawShares(
        uint256 assets
    ) external view returns (uint256) {
        uint256 grossAssets = _grossUpForFee(assets, _frozenLpFeeBps());
        return _convertToSharesUsingAssets(grossAssets, totalAssets(), Math.Rounding.Ceil);
    }

    function estimateRedeemAssets(
        uint256 shares
    ) public view returns (uint256) {
        uint256 grossAssets = _convertToAssetsUsingAssets(shares, totalAssets(), Math.Rounding.Floor);
        return _applyFee(grossAssets, _frozenLpFeeBps());
    }

    function quoteBootstrapDeposit(
        uint256 assets
    ) external view returns (uint256) {
        return _convertToSharesUsingAssets(assets, _depositPricingAssets(), Math.Rounding.Floor);
    }

    function quoteDepositFromState(
        uint256 assets,
        uint256 pricingAssets,
        uint256 pricingSupply,
        uint256 feeBps
    ) public pure returns (uint256 shares) {
        if (feeBps > BPS) {
            revert TrancheVault__InvalidFee();
        }
        uint256 netAssets = feeBps == 0 ? assets : Math.mulDiv(assets, BPS - feeBps, BPS, Math.Rounding.Floor);
        uint256 denominator = pricingAssets + assets + 1 - netAssets;
        shares = Math.mulDiv(netAssets, pricingSupply + VIRTUAL_SHARES, denominator, Math.Rounding.Floor);
    }

    // ---------------------------------------------------------------------
    // HousePool settlement hooks
    // ---------------------------------------------------------------------

    function getMaturedDepositHead(
        uint256 cutoffEpoch
    ) external view returns (uint256 epochId, uint256 assets) {
        epochId = depositQueueHead;
        if (epochId == 0 || epochId > cutoffEpoch) {
            return (0, 0);
        }
        EpochQueueState storage queueState = depositEpochQueueState[epochId];
        DepositEpoch storage epoch = depositEpochs[epochId];
        if (!queueState.queued || epoch.assets == 0 || epoch.finalized || queueState.rejected) {
            return (0, 0);
        }
        assets = epoch.assets;
    }

    function getMaturedRedeemHead(
        uint256 cutoffEpoch
    ) external view returns (uint256 epochId, uint256 remainingShares) {
        epochId = redeemQueueHead;
        if (epochId == 0 || epochId > cutoffEpoch) {
            return (0, 0);
        }
        RedeemEpoch storage epoch = redeemEpochs[epochId];
        if (!redeemEpochQueueState[epochId].queued || epoch.refundEnabled || epoch.shares <= epoch.fundedShares) {
            return (0, 0);
        }
        remainingShares = epoch.shares - epoch.fundedShares;
    }

    function finalizeDepositEpochFromPool(
        uint256 epochId,
        uint256 shares
    ) external onlyPool returns (uint256 assets) {
        if (epochId != depositQueueHead) {
            revert TrancheVault__InvalidEpochHead();
        }
        DepositEpoch storage epoch = depositEpochs[epochId];
        EpochQueueState storage queueState = depositEpochQueueState[epochId];
        if (currentLpEpoch() < epochId) {
            revert TrancheVault__DepositEpochNotActive();
        }
        if (!queueState.queued || epoch.finalized || queueState.rejected || epoch.assets == 0) {
            revert TrancheVault__DepositEpochEmpty();
        }
        assets = epoch.assets;
        _removeDepositEpoch(epochId);
        if (shares == 0) {
            queueState.rejected = true;
            emit DepositEpochRejected(epochId, IS_SENIOR, assets);
            return assets;
        }

        epoch.finalized = true;
        epoch.shares = shares;
        pendingDepositEscrowAssets -= assets;
        depositClaimEscrowShares += shares;
        IERC20(asset()).safeTransfer(address(POOL), assets);
        _mint(address(this), shares);
        emit DepositEpochFinalized(epochId, IS_SENIOR, assets, shares);
    }

    function fundRedeemEpoch(
        uint256 epochId,
        uint256 shares,
        uint256 assets
    ) external onlyPool {
        if (epochId != redeemQueueHead) {
            revert TrancheVault__InvalidEpochHead();
        }
        RedeemEpoch storage epoch = redeemEpochs[epochId];
        uint256 remaining = epoch.shares - epoch.fundedShares;
        if (currentLpEpoch() < epochId || epoch.refundEnabled || shares == 0 || assets == 0 || shares > remaining) {
            revert TrancheVault__InvalidEpochFunding();
        }
        epoch.fundedShares += shares;
        epoch.fundedAssets += assets;
        pendingRedeemEscrowShares -= shares;
        withdrawalEscrowAssets += assets;
        if (IERC20(asset()).balanceOf(address(this)) < pendingDepositEscrowAssets + withdrawalEscrowAssets) {
            revert TrancheVault__EscrowInvariant();
        }
        _burn(address(this), shares);
        if (shares == remaining) {
            _removeRedeemEpoch(epochId);
        }
        emit RedeemEpochFunded(epochId, IS_SENIOR, shares, assets);
    }

    function refundRedeemEpochRemainder(
        uint256 epochId,
        uint256 expectedShares
    ) external onlyPool returns (uint256 shares) {
        if (epochId != redeemQueueHead) {
            revert TrancheVault__InvalidEpochHead();
        }
        RedeemEpoch storage epoch = redeemEpochs[epochId];
        shares = epoch.shares - epoch.fundedShares;
        if (
            currentLpEpoch() < epochId || epoch.refundEnabled || shares == 0 || shares != expectedShares
                || !redeemEpochQueueState[epochId].queued
        ) {
            revert TrancheVault__InvalidEpochFunding();
        }
        epoch.refundEnabled = true;
        epoch.refundableShares = shares;
        _removeRedeemEpoch(epochId);
        emit RedeemEpochRefundable(epochId, IS_SENIOR, shares);
    }

    /// @notice Compatibility wrapper; it invokes the global coordinator and never finalizes independently.
    function finalizeDepositEpoch(
        uint256 epochId
    ) external returns (uint256 shares) {
        POOL.settleLpEpoch();
        DepositEpoch storage epoch = depositEpochs[epochId];
        if (!epoch.finalized) {
            revert TrancheVault__DepositEpochNotFinalized();
        }
        return epoch.shares;
    }

    function _deposit(
        address,
        address,
        uint256,
        uint256
    ) internal pure override {
        revert TrancheVault__AsyncOnly();
    }

    function _withdraw(
        address,
        address,
        address,
        uint256,
        uint256
    ) internal pure override {
        revert TrancheVault__AsyncOnly();
    }

    // ---------------------------------------------------------------------
    // Bootstrap and request validation
    // ---------------------------------------------------------------------

    function bootstrapMint(
        uint256 shares,
        address receiver
    ) external onlyPool {
        _mint(receiver, shares);
        lastDepositTime[receiver] = block.timestamp;
    }

    function configureSeedPosition(
        address receiver,
        uint256 floorShares
    ) external onlyPool {
        if (receiver == address(0) || floorShares == 0) {
            revert TrancheVault__InvalidSeedPosition();
        }
        if (seedReceiver != address(0) && seedReceiver != receiver) {
            revert TrancheVault__InvalidSeedPosition();
        }
        if (balanceOf(receiver) < floorShares || floorShares < seedShareFloor) {
            revert TrancheVault__InvalidSeedPosition();
        }
        seedReceiver = receiver;
        seedShareFloor = floorShares;
    }

    function _requireRequestDepositPreflight(
        uint256 assets,
        address controller,
        address owner
    ) internal view {
        if (controller == address(0) || owner == address(0)) {
            revert TrancheVault__ZeroAddress();
        }
        if (msg.sender != owner && !isOperator[owner][msg.sender]) {
            revert TrancheVault__NotControllerOrOperator();
        }
        if (_isTerminallyWiped()) {
            revert TrancheVault__TerminallyWiped();
        }
        if (!POOL.canAcceptOrdinaryDeposits()) {
            revert TrancheVault__TradingNotActive();
        }
        if (assets < POOL.minTrancheDepositUsdc()) {
            revert TrancheVault__DepositTooSmall();
        }
        uint256 maxAssets = maxRequestDeposit(controller);
        if (maxAssets == 0) {
            revert TrancheVault__DepositsUnavailable();
        }
        if (assets > maxAssets) {
            revert TrancheVault__ExceededMaxRequestDeposit(controller, assets, maxAssets);
        }
    }

    function _requireControllerAuth(
        address controller
    ) internal view {
        if (msg.sender != controller && !isOperator[controller][msg.sender]) {
            revert TrancheVault__NotControllerOrOperator();
        }
    }

    function _requireShareReceiver(
        address controller,
        address receiver
    ) internal view {
        // With one cooldown timestamp per account, accepting unsolicited dust into an existing balance would let any
        // controller repeatedly lock that receiver's entire pre-existing balance. New receivers and self-claims are safe.
        if (receiver != controller && balanceOf(receiver) != 0) {
            revert TrancheVault__ThirdPartyDepositForExistingHolder();
        }
    }

    function _unlockedOwnerShares(
        address owner
    ) internal view returns (uint256 ownerShares) {
        ownerShares = balanceOf(owner);
        if (owner == seedReceiver && seedReceiver != address(0)) {
            ownerShares = ownerShares > seedShareFloor ? ownerShares - seedShareFloor : 0;
        }
    }

    function _isTerminallyWiped() internal view returns (bool) {
        return totalSupply() > 0 && totalAssets() == 0;
    }

    function _frozenLpFeeBps() internal view returns (uint256) {
        return POOL.frozenLpFeeBps(IS_SENIOR);
    }

    function _seniorDepositCapacity() internal view returns (uint256 capacity) {
        capacity = POOL.getSeniorDepositCapacity();
        if (capacity < POOL.minTrancheDepositUsdc()) {
            return 0;
        }
    }

    // ---------------------------------------------------------------------
    // O(1) doubly linked epoch and controller queues
    // ---------------------------------------------------------------------

    function _appendDepositEpoch(
        uint256 epochId
    ) internal {
        EpochQueueState storage state = depositEpochQueueState[epochId];
        state.queued = true;
        uint256 tail = depositQueueTail;
        if (tail == 0) {
            depositQueueHead = epochId;
        } else {
            depositEpochQueueState[tail].nextEpoch = epochId;
            state.previousEpoch = tail;
        }
        depositQueueTail = epochId;
    }

    function _removeDepositEpoch(
        uint256 epochId
    ) internal {
        EpochQueueState storage state = depositEpochQueueState[epochId];
        if (!state.queued) {
            return;
        }
        uint256 previous = state.previousEpoch;
        uint256 next = state.nextEpoch;
        if (previous == 0) {
            depositQueueHead = next;
        } else {
            depositEpochQueueState[previous].nextEpoch = next;
        }
        if (next == 0) {
            depositQueueTail = previous;
        } else {
            depositEpochQueueState[next].previousEpoch = previous;
        }
        state.previousEpoch = 0;
        state.nextEpoch = 0;
        state.queued = false;
    }

    function _appendRedeemEpoch(
        uint256 epochId
    ) internal {
        EpochQueueState storage state = redeemEpochQueueState[epochId];
        state.queued = true;
        uint256 tail = redeemQueueTail;
        if (tail == 0) {
            redeemQueueHead = epochId;
        } else {
            redeemEpochQueueState[tail].nextEpoch = epochId;
            state.previousEpoch = tail;
        }
        redeemQueueTail = epochId;
    }

    function _removeRedeemEpoch(
        uint256 epochId
    ) internal {
        EpochQueueState storage state = redeemEpochQueueState[epochId];
        if (!state.queued) {
            return;
        }
        uint256 previous = state.previousEpoch;
        uint256 next = state.nextEpoch;
        if (previous == 0) {
            redeemQueueHead = next;
        } else {
            redeemEpochQueueState[previous].nextEpoch = next;
        }
        if (next == 0) {
            redeemQueueTail = previous;
        } else {
            redeemEpochQueueState[next].previousEpoch = previous;
        }
        state.previousEpoch = 0;
        state.nextEpoch = 0;
        state.queued = false;
    }

    function _appendControllerDeposit(
        address controller,
        uint256 requestId
    ) internal {
        DepositPosition storage position = depositRequests[controller][requestId];
        position.queued = true;
        uint256 tail = controllerDepositTail[controller];
        if (tail == 0) {
            controllerDepositHead[controller] = requestId;
        } else {
            depositRequests[controller][tail].nextRequestId = requestId;
            position.previousRequestId = tail;
        }
        controllerDepositTail[controller] = requestId;
    }

    function _removeControllerDeposit(
        address controller,
        uint256 requestId
    ) internal {
        DepositPosition storage position = depositRequests[controller][requestId];
        if (!position.queued) {
            return;
        }
        uint256 previous = position.previousRequestId;
        uint256 next = position.nextRequestId;
        if (previous == 0) {
            controllerDepositHead[controller] = next;
        } else {
            depositRequests[controller][previous].nextRequestId = next;
        }
        if (next == 0) {
            controllerDepositTail[controller] = previous;
        } else {
            depositRequests[controller][next].previousRequestId = previous;
        }
        position.previousRequestId = 0;
        position.nextRequestId = 0;
        position.queued = false;
    }

    function _appendControllerRedeem(
        address controller,
        uint256 requestId
    ) internal {
        RedeemPosition storage position = redeemRequests[controller][requestId];
        position.queued = true;
        uint256 tail = controllerRedeemTail[controller];
        if (tail == 0) {
            controllerRedeemHead[controller] = requestId;
        } else {
            redeemRequests[controller][tail].nextRequestId = requestId;
            position.previousRequestId = tail;
        }
        controllerRedeemTail[controller] = requestId;
    }

    function _removeControllerRedeem(
        address controller,
        uint256 requestId
    ) internal {
        RedeemPosition storage position = redeemRequests[controller][requestId];
        if (!position.queued) {
            return;
        }
        uint256 previous = position.previousRequestId;
        uint256 next = position.nextRequestId;
        if (previous == 0) {
            controllerRedeemHead[controller] = next;
        } else {
            redeemRequests[controller][previous].nextRequestId = next;
        }
        if (next == 0) {
            controllerRedeemTail[controller] = previous;
        } else {
            redeemRequests[controller][next].previousRequestId = previous;
        }
        position.previousRequestId = 0;
        position.nextRequestId = 0;
        position.queued = false;
    }

    // ---------------------------------------------------------------------
    // Pricing helpers
    // ---------------------------------------------------------------------

    function _applyFee(
        uint256 grossAssets,
        uint256 feeBps
    ) internal pure returns (uint256) {
        if (feeBps == 0) {
            return grossAssets;
        }
        return Math.mulDiv(grossAssets, BPS - feeBps, BPS, Math.Rounding.Floor);
    }

    function _grossUpForFee(
        uint256 netAssets,
        uint256 feeBps
    ) internal pure returns (uint256) {
        if (feeBps == 0) {
            return netAssets;
        }
        return Math.mulDiv(netAssets, BPS, BPS - feeBps, Math.Rounding.Ceil);
    }

    function _depositPricingAssets() internal view returns (uint256 assets) {
        (uint256 seniorPrincipalUsdc, uint256 juniorPrincipalUsdc) = POOL.getPendingDepositTrancheState();
        return IS_SENIOR ? seniorPrincipalUsdc : juniorPrincipalUsdc;
    }

    function _convertToSharesUsingAssets(
        uint256 assets,
        uint256 totalAssets_,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + VIRTUAL_SHARES, totalAssets_ + 1, rounding);
    }

    function _convertToAssetsUsingAssets(
        uint256 shares,
        uint256 totalAssets_,
        Math.Rounding rounding
    ) internal view returns (uint256) {
        return Math.mulDiv(shares, totalAssets_ + 1, totalSupply() + VIRTUAL_SHARES, rounding);
    }

    function _previewMintAssets(
        uint256 shares
    ) internal view returns (uint256) {
        return _convertToAssetsUsingAssets(shares, _depositPricingAssets(), Math.Rounding.Ceil);
    }

    function _previewFrozenMintAssets(
        uint256 shares,
        uint256 feeBps
    ) internal view returns (uint256) {
        if (shares > _maxFrozenMintShares(feeBps)) {
            return type(uint256).max;
        }
        uint256 adjustedShares = totalSupply() + VIRTUAL_SHARES;
        uint256 adjustedAssets = _depositPricingAssets() + 1;
        (bool aFits, uint256 aProduct) = Math.tryMul(BPS - feeBps, adjustedShares);
        (bool bFits, uint256 bProduct) = Math.tryMul(feeBps, shares);
        (bool cFits, uint256 cProduct) = Math.tryMul(BPS, shares);
        if (aFits && bFits && cFits && aProduct > bProduct) {
            uint256 denominator = aProduct - bProduct;
            (uint256 productHigh,) = Math.mul512(cProduct, adjustedAssets);
            if (productHigh >= denominator) {
                return type(uint256).max;
            }
            uint256 assets = Math.mulDiv(cProduct, adjustedAssets, denominator, Math.Rounding.Floor);
            if (mulmod(cProduct, adjustedAssets, denominator) == 0) {
                return assets;
            }
            return assets == type(uint256).max ? assets : assets + 1;
        }
        return _minimumFrozenMintAssets(shares, feeBps, adjustedShares, adjustedAssets);
    }

    /// @dev Retained for source compatibility with tranche-capacity integrations and harnesses.
    function _maxMintSharesForAssetCapacity(
        uint256 assetCapacity,
        uint256 feeBps
    ) internal view returns (uint256) {
        if (assetCapacity == 0) {
            return 0;
        }
        if (assetCapacity == type(uint256).max) {
            return feeBps == 0 ? type(uint256).max : _maxFrozenMintShares(feeBps);
        }

        uint256 adjustedShares = totalSupply() + VIRTUAL_SHARES;
        uint256 adjustedAssets = _depositPricingAssets() + 1;
        if (feeBps == 0) {
            (uint256 normalProductHigh,) = Math.mul512(assetCapacity, adjustedShares);
            if (normalProductHigh >= adjustedAssets) {
                return type(uint256).max;
            }
            return Math.mulDiv(assetCapacity, adjustedShares, adjustedAssets, Math.Rounding.Floor);
        }

        uint256 feeAdjustedBps = BPS - feeBps;
        uint256 feeLimitShares = _maxFrozenMintShares(feeBps);
        (uint256 denominatorHigh, uint256 denominator) = _add512Products(BPS, adjustedAssets, feeBps, assetCapacity);
        if (denominatorHigh != 0) {
            return
                _maximumFrozenMintSharesForAssets(assetCapacity, feeBps, adjustedShares, adjustedAssets, feeLimitShares);
        }

        (uint256 frozenProductHigh,) = Math.mul512(assetCapacity, adjustedShares);
        if (frozenProductHigh >= denominator) {
            return feeLimitShares;
        }
        uint256 quotient = Math.mulDiv(assetCapacity, adjustedShares, denominator, Math.Rounding.Floor);
        uint256 remainder = mulmod(assetCapacity, adjustedShares, denominator);
        if (quotient > feeLimitShares / feeAdjustedBps) {
            return feeLimitShares;
        }
        uint256 capacityShares = quotient * feeAdjustedBps;
        uint256 fractionalShares = Math.mulDiv(remainder, feeAdjustedBps, denominator, Math.Rounding.Floor);
        if (fractionalShares >= feeLimitShares - capacityShares) {
            return feeLimitShares;
        }
        return capacityShares + fractionalShares;
    }

    function _maxFrozenMintShares(
        uint256 feeBps
    ) internal view returns (uint256) {
        if (feeBps == 0) {
            return type(uint256).max;
        }
        uint256 adjustedShares = totalSupply() + VIRTUAL_SHARES;
        uint256 adjustedBps = BPS - feeBps;
        if (adjustedBps > feeBps) {
            uint256 maxSafe = Math.mulDiv(type(uint256).max, feeBps, adjustedBps);
            if (adjustedShares > maxSafe) {
                return type(uint256).max;
            }
        }
        uint256 quotient = Math.mulDiv(adjustedShares, adjustedBps, feeBps, Math.Rounding.Floor);
        if (mulmod(adjustedShares, adjustedBps, feeBps) == 0) {
            return quotient == 0 ? 0 : quotient - 1;
        }
        return quotient;
    }

    function _minimumFrozenMintAssets(
        uint256 shares,
        uint256 feeBps,
        uint256 adjustedShares,
        uint256 adjustedAssets
    ) private pure returns (uint256) {
        uint256 high = type(uint256).max;
        if (!_frozenMintFits(shares, high, feeBps, adjustedShares, adjustedAssets)) {
            return high;
        }
        uint256 low;
        while (low < high) {
            uint256 midpoint = low + ((high - low) / 2);
            if (_frozenMintFits(shares, midpoint, feeBps, adjustedShares, adjustedAssets)) {
                high = midpoint;
            } else {
                low = midpoint + 1;
            }
        }
        return low;
    }

    function _maximumFrozenMintSharesForAssets(
        uint256 assets,
        uint256 feeBps,
        uint256 adjustedShares,
        uint256 adjustedAssets,
        uint256 upperBound
    ) private pure returns (uint256) {
        uint256 low;
        uint256 high = upperBound;
        while (low < high) {
            uint256 midpoint = low + ((high - low) / 2) + 1;
            if (_frozenMintFits(midpoint, assets, feeBps, adjustedShares, adjustedAssets)) {
                low = midpoint;
            } else {
                high = midpoint - 1;
            }
        }
        return low;
    }

    function _frozenMintFits(
        uint256 shares,
        uint256 assets,
        uint256 feeBps,
        uint256 adjustedShares,
        uint256 adjustedAssets
    ) private pure returns (bool) {
        Uint768 memory right = _mul768Value(assets, BPS - feeBps, adjustedShares);
        Uint768 memory fee = _mul768Value(assets, feeBps, shares);
        if (_compare768(right.high, right.middle, right.low, fee.high, fee.middle, fee.low) < 0) {
            return false;
        }
        (right.high, right.middle, right.low) =
            _subtract768(right.high, right.middle, right.low, fee.high, fee.middle, fee.low);
        Uint768 memory cost = _mul768Value(BPS, shares, adjustedAssets);
        return _compare768(cost.high, cost.middle, cost.low, right.high, right.middle, right.low) <= 0;
    }

    function _mul768Value(
        uint256 x,
        uint256 y,
        uint256 z
    ) private pure returns (Uint768 memory value) {
        (value.high, value.middle, value.low) = _mul768(x, y, z);
    }

    function _mul768(
        uint256 x,
        uint256 y,
        uint256 z
    ) private pure returns (uint256 high, uint256 middle, uint256 low) {
        (uint256 xyHigh, uint256 xyLow) = Math.mul512(x, y);
        (uint256 lowHigh, uint256 lowLow) = Math.mul512(xyLow, z);
        (uint256 highHigh, uint256 highLow) = Math.mul512(xyHigh, z);
        unchecked {
            middle = lowHigh + highLow;
            high = highHigh + (middle < lowHigh ? 1 : 0);
        }
        low = lowLow;
    }

    function _add512Products(
        uint256 x,
        uint256 y,
        uint256 a,
        uint256 b
    ) private pure returns (uint256 high, uint256 low) {
        (uint256 xyHigh, uint256 xyLow) = Math.mul512(x, y);
        (uint256 abHigh, uint256 abLow) = Math.mul512(a, b);
        unchecked {
            low = xyLow + abLow;
            high = xyHigh + abHigh + (low < xyLow ? 1 : 0);
        }
    }

    function _subtract768(
        uint256 xHigh,
        uint256 xMiddle,
        uint256 xLow,
        uint256 yHigh,
        uint256 yMiddle,
        uint256 yLow
    ) private pure returns (uint256 high, uint256 middle, uint256 low) {
        unchecked {
            low = xLow - yLow;
            uint256 lowBorrow = xLow < yLow ? 1 : 0;
            middle = xMiddle - yMiddle;
            uint256 middleBorrow = xMiddle < yMiddle ? 1 : 0;
            uint256 middleBeforeBorrow = middle;
            middle -= lowBorrow;
            if (middleBeforeBorrow < lowBorrow) {
                middleBorrow = 1;
            }
            high = xHigh - yHigh - middleBorrow;
        }
    }

    function _compare768(
        uint256 xHigh,
        uint256 xMiddle,
        uint256 xLow,
        uint256 yHigh,
        uint256 yMiddle,
        uint256 yLow
    ) private pure returns (int256) {
        if (xHigh != yHigh) {
            return xHigh < yHigh ? int256(-1) : int256(1);
        }
        if (xMiddle != yMiddle) {
            return xMiddle < yMiddle ? int256(-1) : int256(1);
        }
        if (xLow == yLow) {
            return 0;
        }
        return xLow < yLow ? int256(-1) : int256(1);
    }

}
