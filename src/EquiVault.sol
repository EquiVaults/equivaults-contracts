// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AssetRegistry} from "./AssetRegistry.sol";
import {ExitLib} from "./ExitLib.sol";
import {InitLib} from "./InitLib.sol";
import {MigrationLib} from "./MigrationLib.sol";
import {RebalanceLib} from "./RebalanceLib.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @notice Stablecoin-settled basket vault holding registered assets, with a configurable trust
/// mode and a reallocation proposal mechanism.
/// @dev Deposits buy the basket immediately through each asset's liquidity route; redemptions
/// withdraw the exact proportional share of every asset and let the user pick, per asset, between
/// receiving the token and selling it to the settlement asset. Shares are non-transferable. A performance fee on
/// realized gain (0-20 %, immutable) is charged only at withdrawal, 90 % to the manager and 10 %
/// to the protocol treasury. If both price sources of any basket asset fail, this vault pauses.
/// The trust mode (instant, delayed 1-7 days, or immutable) is chosen at creation and frozen: it
/// gates single reallocation proposals that change the basket assets/weights, executed by anyone after the delay with
/// positions migrated through the registered liquidity routes. The vault intentionally does not
/// implement ERC-4626: entries and exits perform several swaps and therefore require explicit
/// execution constraints rather than ERC-4626's single-asset preview semantics.
contract EquiVault is ERC20, ReentrancyGuard {
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_BASKET_SIZE = 5;
    uint16 public constant MIN_WEIGHT_BPS = 500; // 5 %
    uint16 public constant MAX_FEE_BPS = 2_000; // 20 %
    uint16 public constant MAX_SLIPPAGE_BPS = 3_000; // 30 %
    uint256 public constant MIN_TIMELOCK_DELAY = 1 days;
    uint256 public constant MAX_TIMELOCK_DELAY = 7 days;
    uint16 public constant MANAGER_FEE_SHARE_BPS = 9_000; // 90 %
    uint256 public constant VIRTUAL_SHARES = 1e6;
    uint256 public constant VIRTUAL_ASSETS = 1;

    // Rebalance parameters. The drift threshold (1-10 points, default 3) gates when the basket is
    // rebalanceable; the collective slippage (0.1-3 %, default 1 %) bounds every rebalance swap.
    // Both change only through a parameter update proposal executed via the vault timelock.
    uint16 public constant MIN_DRIFT_BPS = 100; // 1 point
    uint16 public constant MAX_DRIFT_BPS = 1_000; // 10 points
    uint16 public constant DEFAULT_DRIFT_BPS = 300; // 3 points
    uint16 public constant MIN_REBALANCE_SLIPPAGE_BPS = 10; // 0.1 %
    uint16 public constant MAX_REBALANCE_SLIPPAGE_BPS = 300; // 3 %
    uint16 public constant DEFAULT_REBALANCE_SLIPPAGE_BPS = 100; // 1 %
    uint256 public constant MAX_GAS_REBATE = 5e6; // absolute settlement cap per rebalance (5 units)
    uint256 public constant ETH_SETTLEMENT_PRICE_CAP = 5_000e6; // fixed ETH price cap in settlement wei per ETH

    /// @dev Trust mode chosen at creation and immutable afterwards.
    enum TimelockMode {
        Instant, // proposals are executable immediately
        Delayed, // proposals wait `timelockDelay` (1-7 days)
        Immutable // composition is frozen forever: proposals are refused permanently
    }

    /// @dev Single active reallocation proposal; `id == 0` means none pending.
    struct ReallocationProposal {
        uint256 id;
        uint256 executableAt;
        address[] assets;
        uint16[] weightsBps;
    }

    /// @dev Single active rebalance-parameter proposal; `id == 0` means none pending. Mutually
    /// exclusive with a reallocation proposal: only one pending change at a time.
    struct ParameterProposal {
        uint256 id;
        uint256 executableAt;
        uint16 driftThresholdBps;
        uint16 rebalanceSlippageBps;
    }

    /// @dev Executor-supplied constraints for `rebalance()`.
    struct RebalanceParams {
        uint256 deadline; // swaps revert past this timestamp
        uint256[] minAmountsOut; // per basket asset; 0 = vault default bound, any value below the default reverts
    }

    /// @notice Explicit execution constraints for a basket entry.
    struct EnterParams {
        uint256 settlementIn;
        address receiver;
        uint256 minSharesOut;
        uint256[] minAmountsOut;
        uint256 deadline;
        uint256 proposalId;
    }

    /// @notice Explicit execution constraints for a proportional basket exit.
    struct ExitParams {
        uint256 shares;
        address receiver;
        bool[] sellTokens;
        uint256[] minAmountsOut;
        uint256 minSettlementOut;
        uint256 deadline;
    }

    address public immutable manager;
    uint16 public immutable feeBps;
    uint16 public immutable maxSlippageBps;
    TimelockMode public immutable timelockMode;
    uint256 public immutable timelockDelay;
    AssetRegistry public immutable registry;
    IERC20 public immutable settlementAsset;
    uint8 private immutable _settlementDecimals;

    address[] private _basketAssets;
    uint16[] private _basketWeightsBps;

    uint256 public proposalCounter;
    ReallocationProposal internal _activeProposal;

    /// @notice Drift threshold in bps (1-10 points) above which the basket is rebalanceable.
    uint16 public driftThresholdBps;

    /// @notice Collective slippage bound in bps (0.1-3 %) applied to every rebalance swap by default.
    uint16 public rebalanceSlippageBps;

    ParameterProposal internal _activeParameterProposal;

    /// @notice Cumulative settlement contributed by each shareholder, minus the realized cost of redeemed shares.
    /// @dev Average cost basis per share = costBasis[account] / balanceOf(account); shares are
    /// non-transferable so this mapping always matches the share balance it accounts for.
    mapping(address account => uint256 amount) public costBasis;

    error InvalidAddress();
    error InvalidFee(uint16 feeBps);
    error InvalidSlippage(uint16 slippageBps);
    error InvalidBasketSize(uint256 size);
    error BasketLengthMismatch(uint256 assets, uint256 weights);
    error InvalidWeight(uint16 weightBps);
    error WeightsMustSumTo10000(uint256 sum);
    error DuplicateAsset(address asset);
    error SettlementAssetInBasket(address asset);
    error AssetNotRegistered(address asset);
    error MinOutsLengthMismatch(uint256 expected, uint256 actual);
    error SellFlagsLengthMismatch(uint256 expected, uint256 actual);
    error VaultPaused();
    error SharesNonTransferable();
    error NotManager();
    error InvalidTimelockDelay(uint256 delay);
    error TimelockImmutable();
    error ProposalAlreadyActive(uint256 id);
    error NoActiveProposal();
    error ProposalNotExecutable(uint256 executableAt);
    error ProposalIdMismatch(uint256 activeId, uint256 proposalId);
    error AssetNotAdmissible(address asset);
    error InvalidDriftThreshold(uint16 driftBps);
    error InvalidRebalanceSlippage(uint16 slippageBps);
    error DriftBelowThreshold(uint256 maxDeviationBps, uint16 thresholdBps);
    error DeadlineExpired(uint256 timestamp);
    error RebalanceMinTooPermissive(uint256 index, uint256 minOut, uint256 defaultMinOut);
    error EntrySharesBelowMinimum(uint256 actualShares, uint256 minSharesOut);
    error ExitSettlementBelowMinimum(uint256 actualSettlement, uint256 minSettlementOut);
    error InsufficientShares(address owner, uint256 available, uint256 required);
    error ExitMinTooPermissive(uint256 index, uint256 minOut, uint256 defaultMinOut);
    error MigrationMinTooPermissive(uint256 index, uint256 minOut, uint256 defaultMinOut);

    /// @notice Emitted after settlement is swapped into the basket and shares are minted from the
    /// basket value actually received, never from a pre-swap estimate.
    event Entered(
        address indexed caller, address indexed receiver, uint256 settlementIn, uint256 valueReceived, uint256 shares
    );

    /// @notice Emitted after a holder exits. `settlementOut` is the actual settlement transferred
    /// to the receiver; token transfers are emitted by their ERC-20 contracts.
    event Exited(address indexed owner, address indexed receiver, uint256 shares, uint256 settlementOut, uint256 feePot);

    event PerformanceFeeCollected(
        address indexed manager,
        address indexed treasury,
        uint256 amount,
        uint256 managerShare,
        uint256 treasuryShare
    );

    event ReallocationProposed(
        uint256 indexed id,
        address indexed proposer,
        uint256 executableAt,
        address[] assets,
        uint16[] weightsBps
    );

    event ReallocationCancelled(uint256 indexed id);

    event ReallocationExecuted(uint256 indexed id, address[] assets, uint16[] weightsBps);

    event ParameterUpdateProposed(
        uint256 indexed id, uint256 executableAt, uint16 driftThresholdBps, uint16 rebalanceSlippageBps
    );

    event ParameterUpdateCancelled(uint256 indexed id);

    event ParameterUpdateExecuted(uint256 indexed id, uint16 driftThresholdBps, uint16 rebalanceSlippageBps);

    /// @notice Emitted after a successful rebalance: net settlement sold/bought, gas reimbursed to
    /// the executor and the basket weights before/after (bps of NAV).
    event Rebalanced(
        address indexed executor,
        uint256 gasRebate,
        uint256 soldValueSettlement,
        uint256 boughtValueSettlement,
        uint256[] weightsBeforeBps,
        uint256[] weightsAfterBps
    );

    constructor(
        IERC20 settlementAsset_,
        AssetRegistry registry_,
        address manager_,
        address[] memory assets,
        uint16[] memory weightsBps,
        uint16 feeBps_,
        uint16 maxSlippageBps_,
        TimelockMode timelockMode_,
        uint256 timelockDelay_,
        uint16 driftThresholdBps_,
        uint16 rebalanceSlippageBps_
    ) ERC20("EquiVault", "EQV") {
        // `timelockMode_` cannot be out of range: Solidity bounds-checks enum values on conversion
        // and on ABI decoding, so an invalid mode is rejected with Panic(0x21) before this code.
        _initBasket(settlementAsset_, registry_, assets, weightsBps);

        settlementAsset = settlementAsset_;
        manager = manager_;
        registry = registry_;
        feeBps = feeBps_;
        maxSlippageBps = maxSlippageBps_;
        timelockMode = timelockMode_;
        timelockDelay = timelockDelay_;

        // Settlement asset decimals drive NAV values and are retained for price conversions.
        (bool ok, uint8 tokenDecimals) = SafeERC20.tryGetDecimals(settlementAsset_);
        _settlementDecimals = ok ? tokenDecimals : 18;

        // Remaining creation bounds are validated in InitLib (kept out of this initcode, which
        // VaultFactory embeds, so the factory stays under the EIP-170 code-size limit). 0 means
        // protocol defaults for drift and rebalance slippage.
        (uint16 drift, uint16 rebalanceSlip) = InitLib.validate(
            manager_, registry_, feeBps_, maxSlippageBps_, timelockMode_, timelockDelay_,
            driftThresholdBps_, rebalanceSlippageBps_
        );
        driftThresholdBps = drift;
        rebalanceSlippageBps = rebalanceSlip;
    }

    // ---------------------------------------------------------------------
    // Custom basket entry / exit API
    // ---------------------------------------------------------------------

    /// @notice NAV of the vault expressed in settlement units: each basket asset valued at its live
    /// registry price (primary oracle, then fallback). Settlement dust is excluded because it is
    /// not part of the basket distributed by `exit`.
    function totalAssets() public view returns (uint256) {
        uint256 nav;
        uint256 n = _basketAssets.length;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            nav += _valueSettlement(a, IERC20(a).balanceOf(address(this)));
        }
        return nav;
    }

    /// @notice Oracle-valued proportional basket slice for UI display only; it is not an execution guarantee.
    function quoteExitValue(uint256 shares) external view returns (uint256 value) {
        uint256 supply = totalSupply();
        if (shares == 0 || shares > supply) return 0;
        (, value) = ExitLib.computeExitAmounts(this, shares, supply);
    }

    /// @notice Swaps settlement into the basket and mints shares from the value actually received.
    /// @dev `minAmountsOut` is in basket order; an empty array applies the immutable vault default.
    /// `proposalId` is zero with no pending reallocation, otherwise it must equal the active id.
    function enter(EnterParams calldata params) external nonReentrant returns (uint256 shares) {
        if (params.deadline < block.timestamp) revert DeadlineExpired(block.timestamp);
        _requireCanDeposit();
        _requireEntryConsent(params.proposalId);

        uint256 supplyBefore = totalSupply();
        uint256 navBefore = totalAssets();
        _transferIn(_msgSender(), params.settlementIn);
        uint256 valueReceived = _buyBasket(params.settlementIn, params.minAmountsOut);
        shares = valueReceived.mulDiv(supplyBefore + VIRTUAL_SHARES, navBefore + VIRTUAL_ASSETS);
        if (shares == 0 || shares < params.minSharesOut) {
            revert EntrySharesBelowMinimum(shares, params.minSharesOut);
        }
        costBasis[params.receiver] += params.settlementIn;
        _mint(params.receiver, shares);
        emit Entered(_msgSender(), params.receiver, params.settlementIn, valueReceived, shares);
    }

    /// @notice Burns caller shares and distributes their proportional basket slice.
    /// @dev For a sold asset, a caller-provided min-out can only tighten the vault default;
    /// `minSettlementOut` protects the aggregate settlement transferred to the receiver.
    function exit(ExitParams calldata params) external nonReentrant returns (uint256 settlementOut) {
        if (params.deadline < block.timestamp) revert DeadlineExpired(block.timestamp);
        _requireCanExit();

        address owner = _msgSender();
        uint256 sharesBefore = balanceOf(owner);
        if (params.shares == 0 || params.shares > sharesBefore) {
            revert InsufficientShares(owner, sharesBefore, params.shares);
        }
        uint256 totalShares = totalSupply();
        uint256 n = _basketAssets.length;
        if (params.sellTokens.length != 0 && params.sellTokens.length != n) {
            revert SellFlagsLengthMismatch(n, params.sellTokens.length);
        }
        if (params.minAmountsOut.length != 0 && params.minAmountsOut.length != n) {
            revert MinOutsLengthMismatch(n, params.minAmountsOut.length);
        }
        bool explicitFlags = params.sellTokens.length != 0;

        (uint256[] memory amounts, uint256 valueWithdrawn) =
            ExitLib.computeExitAmounts(this, params.shares, totalShares);
        uint256 realizedCost = costBasis[owner].mulDiv(params.shares, sharesBefore);
        costBasis[owner] -= realizedCost;
        uint256 fee;
        if (valueWithdrawn > realizedCost) {
            fee = (valueWithdrawn - realizedCost).mulDiv(feeBps, BPS_DENOMINATOR);
        }

        _burn(owner, params.shares);
        (uint256 feePot, uint256 actualSettlementOut) = ExitLib.distribute(
            this, params.receiver, amounts, params.sellTokens, explicitFlags, params.minAmountsOut, fee, valueWithdrawn
        );
        if (actualSettlementOut < params.minSettlementOut) {
            revert ExitSettlementBelowMinimum(actualSettlementOut, params.minSettlementOut);
        }
        _settleFee(feePot);
        emit Exited(owner, params.receiver, params.shares, actualSettlementOut, feePot);
        return actualSettlementOut;
    }

    // ---------------------------------------------------------------------
    // Vault views
    // ---------------------------------------------------------------------

    /// @notice True while a basket asset cannot be safely rebalanced: both price sources are
    /// invalid or the registry forbids opening further exposure to it (ExitOnly/Quarantined).
    /// @dev Withdrawals remain governed separately by `_requireCanExit`; this guard only stops
    /// operations that could buy an asset after the registry has put it in exit-only mode.
    function paused() public view returns (bool) {
        return RebalanceLib.isPaused(this);
    }

    function basketAssets() external view returns (address[] memory) {
        return _basketAssets;
    }

    /// @notice Settlement asset decimals (read at construction, 18 when unreadable), exposed for
    /// `RebalanceLib` to rescale Chainlink-style prices into settlement units.
    function settlementDecimals() external view returns (uint8) {
        return _settlementDecimals;
    }

    /// @notice Shares use the settlement decimals plus the six-decimal virtual-share buffer.
    function decimals() public view override returns (uint8) {
        return _settlementDecimals + 6;
    }

    function basketWeightsBps() external view returns (uint16[] memory) {
        return _basketWeightsBps;
    }

    // ---------------------------------------------------------------------
    // Reallocation proposals
    // ---------------------------------------------------------------------

    modifier onlyManager() {
        if (_msgSender() != manager) revert NotManager();
        _;
    }

    /// @notice Returns the single active proposal, or an empty one (`id == 0`) when none is pending.
    function activeProposal() external view returns (ReallocationProposal memory) {
        return _activeProposal;
    }

    /// @notice Returns the single active rebalance-parameter proposal, or an empty one
    /// (`id == 0`) when none is pending.
    function activeParameterProposal() external view returns (ParameterProposal memory) {
        return _activeParameterProposal;
    }

    /// @notice Proposes a new basket (assets/weights), gated by the vault trust mode.
    /// @dev `assets_` must be 1-5 registered and Active assets, weights each >= 5 % summing to 100 %.
    /// A vault in `Immutable` mode refuses proposals forever. Only one proposal can be active; replacing requires
    /// cancelling first and
    /// restarts the full delay.
    function proposeReallocation(address[] calldata assets_, uint16[] calldata weightsBps_)
        external
        onlyManager
    {
        if (timelockMode == TimelockMode.Immutable) revert TimelockImmutable();
        if (_activeProposal.id != 0) revert ProposalAlreadyActive(_activeProposal.id);
        if (_activeParameterProposal.id != 0) revert ProposalAlreadyActive(_activeParameterProposal.id);

        _validateReallocationTarget(assets_, weightsBps_);

        uint256 id = ++proposalCounter;
        uint256 executableAt =
            timelockMode == TimelockMode.Instant ? block.timestamp : block.timestamp + timelockDelay;
        _activeProposal = ReallocationProposal({
            id: id,
            executableAt: executableAt,
            assets: assets_,
            weightsBps: weightsBps_
        });
        emit ReallocationProposed(id, manager, executableAt, assets_, weightsBps_);
    }

    /// @notice Cancels only the reallocation identified by the manager's consent.
    /// @dev A replaced, executed or already cancelled proposal cannot be cancelled by a stale request.
    function cancelReallocation(uint256 expectedProposalId) external onlyManager {
        uint256 id = _activeProposal.id;
        if (id == 0) revert NoActiveProposal();
        if (expectedProposalId != id) revert ProposalIdMismatch(id, expectedProposalId);
        delete _activeProposal;
        emit ReallocationCancelled(id);
    }

    /// @dev Permissionless once `executableAt` is reached. `expectedProposalId` and `deadline`
    /// bind the executor's consent to the displayed proposal and execution window. Re-validates
    /// the target (asset statuses may have changed since propose), then migrates
    /// the basket: removed assets are sold to the settlement asset and the freed balance is
    /// reinvested toward the new target weights by deficit (kept and added assets alike), so no
    /// settlement is left idle outside `totalAssets()`. Bounded by `sellMinOuts` in removed order
    /// and `buyMinOuts` in new-basket order (0 = vault default slippage bound).
    function executeReallocation(
        uint256 expectedProposalId,
        uint256 deadline,
        uint256[] calldata sellMinOuts,
        uint256[] calldata buyMinOuts
    ) external nonReentrant {
        ReallocationProposal memory proposal = _activeProposal;
        if (proposal.id == 0) revert NoActiveProposal();
        if (expectedProposalId != proposal.id) revert ProposalIdMismatch(proposal.id, expectedProposalId);
        if (deadline < block.timestamp) revert DeadlineExpired(block.timestamp);
        if (block.timestamp < proposal.executableAt) revert ProposalNotExecutable(proposal.executableAt);

        _validateReallocationTarget(proposal.assets, proposal.weightsBps);
        _migrateBasket(proposal.assets, proposal.weightsBps, sellMinOuts, buyMinOuts);

        delete _activeProposal;
        emit ReallocationExecuted(proposal.id, proposal.assets, proposal.weightsBps);
    }

    // ---------------------------------------------------------------------
    // Rebalance parameter updates
    // ---------------------------------------------------------------------

    /// @notice Proposes new drift threshold and collective slippage, gated by the vault trust mode
    /// exactly like a basket reallocation: immutable vaults refuse forever, delayed vaults wait
    /// `timelockDelay`, and only one pending change (basket or parameters) is allowed at a time.
    function proposeParameters(uint16 driftThresholdBps_, uint16 rebalanceSlippageBps_) external onlyManager {
        if (timelockMode == TimelockMode.Immutable) revert TimelockImmutable();
        if (_activeParameterProposal.id != 0) revert ProposalAlreadyActive(_activeParameterProposal.id);
        if (_activeProposal.id != 0) revert ProposalAlreadyActive(_activeProposal.id);

        _validateRebalanceParams(driftThresholdBps_, rebalanceSlippageBps_);

        uint256 id = ++proposalCounter;
        uint256 executableAt =
            timelockMode == TimelockMode.Instant ? block.timestamp : block.timestamp + timelockDelay;
        _activeParameterProposal = ParameterProposal({
            id: id,
            executableAt: executableAt,
            driftThresholdBps: driftThresholdBps_,
            rebalanceSlippageBps: rebalanceSlippageBps_
        });
        emit ParameterUpdateProposed(id, executableAt, driftThresholdBps_, rebalanceSlippageBps_);
    }

    /// @notice Cancels only the parameter update identified by the manager's consent.
    /// @dev Does not apply the pending parameters or change the current basket.
    function cancelParameterUpdate(uint256 expectedProposalId) external onlyManager {
        uint256 id = _activeParameterProposal.id;
        if (id == 0) revert NoActiveProposal();
        if (expectedProposalId != id) revert ProposalIdMismatch(id, expectedProposalId);
        delete _activeParameterProposal;
        emit ParameterUpdateCancelled(id);
    }

    /// @dev Permissionless once `executableAt` is reached. `expectedProposalId` and `deadline`
    /// bind the executor's consent to the displayed proposal and execution window.
    function executeParameterUpdate(uint256 expectedProposalId, uint256 deadline) external nonReentrant {
        ParameterProposal memory proposal = _activeParameterProposal;
        if (proposal.id == 0) revert NoActiveProposal();
        if (expectedProposalId != proposal.id) revert ProposalIdMismatch(proposal.id, expectedProposalId);
        if (deadline < block.timestamp) revert DeadlineExpired(block.timestamp);
        if (block.timestamp < proposal.executableAt) revert ProposalNotExecutable(proposal.executableAt);

        driftThresholdBps = proposal.driftThresholdBps;
        rebalanceSlippageBps = proposal.rebalanceSlippageBps;
        delete _activeParameterProposal;
        emit ParameterUpdateExecuted(proposal.id, proposal.driftThresholdBps, proposal.rebalanceSlippageBps);
    }

    // ---------------------------------------------------------------------
    // Rebalancing
    // ---------------------------------------------------------------------

    /// @notice Max absolute deviation (in bps of NAV) of any basket asset from its target weight.
    /// @dev The basket is rebalanceable when `maxDeviationBps` exceeds `driftThresholdBps`. The
    /// computation runs in `RebalanceLib` to keep this runtime under the EIP-170 code-size limit.
    function measureDrift() public view returns (uint256 maxDeviationBps, bool aboveThreshold) {
        return RebalanceLib.measureDrift(this);
    }

    /// @notice Permissionless basket rebalance: sells overweight assets and buys underweight ones
    /// through the registered liquidity routes, back toward the target weights.
    /// @dev Reverts unless the basket drift exceeds `driftThresholdBps` (so the reimbursement
    /// cannot be farmed), prices are fresh, the deadline has not passed, and every explicit
    /// `minAmountsOut` is at least as strict as the vault collective-slippage default. The executor
    /// receives a gas reimbursement measured on-chain and capped in the settlement asset. DEX costs
    /// stay in the vault; the history event exposes the net result and the weights before/after.
    /// The heavy sell/buy logic runs in `RebalanceLib` (DELEGATECALL, so the vault's context and
    /// route allowances apply) to keep this runtime under the EIP-170 code-size limit.
    function rebalance(RebalanceParams calldata params) external nonReentrant returns (uint256) {
        if (paused()) revert VaultPaused();
        (uint256 maxDeviationBps, bool aboveThreshold) = measureDrift();
        if (!aboveThreshold) revert DriftBelowThreshold(maxDeviationBps, driftThresholdBps);
        if (params.deadline < block.timestamp) revert DeadlineExpired(block.timestamp);

        uint256 n = _basketAssets.length;
        if (params.minAmountsOut.length != 0 && params.minAmountsOut.length != n) {
            revert MinOutsLengthMismatch(n, params.minAmountsOut.length);
        }

        uint256 startGas = gasleft();
        uint256 nav = totalAssets();
        uint256[] memory weightsBefore = RebalanceLib.weightsBpsOf(this, nav);

        uint256 soldValueSettlement = RebalanceLib.sellOverweight(this, nav, params.minAmountsOut);

        // Gas reimbursement: measured here in the vault (reading `gasleft()` inside the library
        // would be amputated by the EIP-150 63/64 rule and overestimate the gas used), converted at
        // a protocol-fixed ETH price cap and bounded by an absolute settlement cap, so an executor
        // can neither inflate it nor receive anything without a valid rebalance. The rebate is
        // additionally bounded by the collective tolerance applied to this rebalance's proceeds,
        // preserving the buy leg even when the vault is smaller than the absolute rebate cap.
        uint256 gasRebate =
            RebalanceLib.computeRebate(startGas - gasleft(), soldValueSettlement, rebalanceSlippageBps);
        IERC20 settlement = settlementAsset;
        uint256 pool = settlement.balanceOf(address(this));
        if (gasRebate > pool) gasRebate = pool;
        if (gasRebate > 0) settlement.safeTransfer(_msgSender(), gasRebate);

        uint256 boughtValueSettlement = RebalanceLib.buyUnderweight(this, nav, params.minAmountsOut);
        uint256[] memory weightsAfter = RebalanceLib.weightsBpsOf(this, totalAssets());

        emit Rebalanced(_msgSender(), gasRebate, soldValueSettlement, boughtValueSettlement, weightsBefore, weightsAfter);
        return gasRebate;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _transferIn(address caller, uint256 amount) internal {
        settlementAsset.safeTransferFrom(caller, address(this), amount);
    }

    /// @dev Splits the collected fee pot 90 % (manager) / 10 % (treasury) and transfers it.
    function _settleFee(uint256 feePot) internal {
        if (feePot > 0) {
            uint256 managerShare = feePot.mulDiv(MANAGER_FEE_SHARE_BPS, BPS_DENOMINATOR);
            uint256 treasuryShare = feePot - managerShare;
            address treasury = registry.treasury();
            settlementAsset.safeTransfer(manager, managerShare);
            settlementAsset.safeTransfer(treasury, treasuryShare);
            emit PerformanceFeeCollected(manager, treasury, feePot, managerShare, treasuryShare);
        }
    }

    /// @dev Buys the basket and returns the oracle value of tokens actually received. The
    /// pre/post balance delta, rather than a route-reported amount or input settlement, is what
    /// protects existing shareholders from an underperforming route (B003).
    function _buyBasket(uint256 assets, uint256[] memory minAmountsOut) internal returns (uint256 valueReceived) {
        uint256 n = _basketAssets.length;
        if (minAmountsOut.length != 0 && minAmountsOut.length != n) {
            revert MinOutsLengthMismatch(n, minAmountsOut.length);
        }
        bool explicitMins = minAmountsOut.length != 0;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            uint256 alloc = assets.mulDiv(_basketWeightsBps[i], BPS_DENOMINATOR);
            uint256 minOut = explicitMins ? minAmountsOut[i] : _buyMinOut(a, alloc);
            uint256 balanceBefore = IERC20(a).balanceOf(address(this));
            ISwapRouter(registry.assetConfig(a).liquidityRoute).swapExactIn(address(settlementAsset), a, alloc, minOut);
            valueReceived += _valueSettlement(a, IERC20(a).balanceOf(address(this)) - balanceBefore);
        }
    }

    /// @dev Token quote (natural units) for a settlement buy, discounted by the vault default slippage bound.
    function _buyMinOut(address a, uint256 settlementAmount) internal view returns (uint256) {
        uint256 quoted = _buyQuote(a, settlementAmount);
        return quoted.mulDiv(BPS_DENOMINATOR - maxSlippageBps, BPS_DENOMINATOR);
    }

    /// @dev Natural-unit token quote for a settlement buy amount.
    function _buyQuote(address a, uint256 settlementAmount) internal view returns (uint256) {
        uint256 baseScale = 10 ** uint256(registry.assetConfig(a).decimals);
        return settlementAmount.mulDiv(baseScale * 1e18, _priceOf(a) * (10 ** _settlementDecimals));
    }

    /// @dev Settlement wei value of `amount` natural units of basket asset `a` at its live price.
    /// `priceE18` is dollars per whole token (Chainlink-style), so the settlement quote rescales
    /// by the settlement decimals and the base token's own decimals. Kept here because `totalAssets`
    /// (the ERC-4626 NAV) is called on every valuation; the exit/rebalance copies live in the
    /// ExitLib/RebalanceLib/MigrationLib libraries to keep this runtime under EIP-170.
    function _valueSettlement(address a, uint256 amount) internal view returns (uint256) {
        uint256 baseScale = 10 ** uint256(registry.assetConfig(a).decimals);
        return amount.mulDiv(_priceOf(a) * (10 ** _settlementDecimals), baseScale * 1e18);
    }

    function _priceOf(address a) internal view returns (uint256) {
        (uint256 price,) = registry.getPrice(a, address(settlementAsset));
        return price;
    }

    function _isPriced(address a) internal view returns (bool) {
        try registry.getPrice(a, address(settlementAsset)) returns (uint256 price, uint256) {
            return price != 0;
        } catch {
            return false;
        }
    }

    function _requireEntryConsent(uint256 proposalId) internal view {
        uint256 activeId = _activeProposal.id;
        if (activeId == 0) {
            if (proposalId != 0) revert NoActiveProposal();
            return;
        }
        if (proposalId != activeId) revert ProposalIdMismatch(activeId, proposalId);
    }

    function _requireCanDeposit() internal view {
        uint256 n = _basketAssets.length;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            if (!registry.canOpenExposure(a) || !_isPriced(a)) revert VaultPaused();
        }
    }

    function _requireCanExit() internal view {
        uint256 n = _basketAssets.length;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            if (!registry.canExit(a) || !_isPriced(a)) revert VaultPaused();
        }
    }

    /// @dev Validates the initial basket, approves each liquidity route for both legs and records
    /// the arrays. Extracted from the constructor to keep its stack depth within limits.
    function _initBasket(
        IERC20 settlement_,
        AssetRegistry registry_,
        address[] memory assets,
        uint16[] memory weightsBps
    ) internal {
        uint256 n = assets.length;
        if (n == 0 || n > MAX_BASKET_SIZE) revert InvalidBasketSize(n);
        if (n != weightsBps.length) revert BasketLengthMismatch(n, weightsBps.length);

        uint256 weightSum;
        for (uint256 i = 0; i < n; ++i) {
            address asset = assets[i];
            if (asset == address(0)) revert InvalidAddress();
            if (asset == address(settlement_)) revert SettlementAssetInBasket(asset);
            for (uint256 j = 0; j < i; ++j) {
                if (assets[j] == asset) revert DuplicateAsset(asset);
            }
            bool registered;
            try registry_.assetConfig(asset) returns (AssetRegistry.AssetConfig memory config) {
                registered = true;
                // Allow the registered liquidity route to pull settlement and basket tokens on swap.
                SafeERC20.forceApprove(settlement_, config.liquidityRoute, type(uint256).max);
                SafeERC20.forceApprove(IERC20(asset), config.liquidityRoute, type(uint256).max);
            } catch {}
            if (!registered) revert AssetNotRegistered(asset);

            uint16 weight = weightsBps[i];
            if (weight < MIN_WEIGHT_BPS) revert InvalidWeight(weight);
            weightSum += weight;

            _basketAssets.push(asset);
            _basketWeightsBps.push(weight);
        }
        if (weightSum != BPS_DENOMINATOR) revert WeightsMustSumTo10000(weightSum);
    }

    /// @dev Rejects a reallocation target whose basket violates the vault rules. Asset
    /// statuses are checked with `canOpenExposure` so a proposal can only target assets the vault
    /// may still open exposure to.
    function _validateReallocationTarget(
        address[] memory assets_,
        uint16[] memory weightsBps_
    ) internal view {
        uint256 n = assets_.length;
        if (n == 0 || n > MAX_BASKET_SIZE) revert InvalidBasketSize(n);
        if (n != weightsBps_.length) revert BasketLengthMismatch(n, weightsBps_.length);

        uint256 weightSum;
        for (uint256 i = 0; i < n; ++i) {
            address a = assets_[i];
            if (a == address(0)) revert InvalidAddress();
            if (a == address(settlementAsset)) revert SettlementAssetInBasket(a);
            for (uint256 j = 0; j < i; ++j) {
                if (assets_[j] == a) revert DuplicateAsset(a);
            }
            if (!registry.canOpenExposure(a)) revert AssetNotAdmissible(a);
            uint16 weight = weightsBps_[i];
            if (weight < MIN_WEIGHT_BPS) revert InvalidWeight(weight);
            weightSum += weight;
        }
        if (weightSum != BPS_DENOMINATOR) revert WeightsMustSumTo10000(weightSum);
    }

    /// @dev Migrates the held basket toward the proposal target: sells removed assets entirely to
    /// the settlement asset, reinvests the freed balance toward the new target weights by deficit
    /// (kept and added assets alike), and approves each new liquidity route. Kept assets are never
    /// sold; residual drift is left to the rebalance engine. The swap/approval work runs in `MigrationLib`
    /// (DELEGATECALL, so the vault's context and route allowances apply) to keep this runtime under
    /// the EIP-170 code-size limit; only the basket arrays are written here.
    function _migrateBasket(
        address[] memory newAssets,
        uint16[] memory newWeightsBps,
        uint256[] calldata sellMinOuts,
        uint256[] calldata buyMinOuts
    ) internal {
        MigrationLib.migrate(this, newAssets, newWeightsBps, sellMinOuts, buyMinOuts);
        _basketAssets = newAssets;
        _basketWeightsBps = newWeightsBps;
    }

    // ---------------------------------------------------------------------
    // Rebalancing internals
    // ---------------------------------------------------------------------

    function _validateRebalanceParams(uint16 driftBps, uint16 slippageBps) internal view {
        if (driftBps < MIN_DRIFT_BPS || driftBps > MAX_DRIFT_BPS) revert InvalidDriftThreshold(driftBps);
        if (
            slippageBps < MIN_REBALANCE_SLIPPAGE_BPS || slippageBps > MAX_REBALANCE_SLIPPAGE_BPS
                || slippageBps > maxSlippageBps
        ) revert InvalidRebalanceSlippage(slippageBps);
    }

    // ---------------------------------------------------------------------
    // Non-transferable shares
    // ---------------------------------------------------------------------

    function transfer(address, uint256) public pure override(ERC20) returns (bool) {
        revert SharesNonTransferable();
    }

    function transferFrom(address, address, uint256) public pure override(ERC20) returns (bool) {
        revert SharesNonTransferable();
    }
}
