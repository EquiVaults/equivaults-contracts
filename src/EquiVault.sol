// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AssetRegistry} from "./AssetRegistry.sol";
import {ExitLib} from "./ExitLib.sol";
import {InitLib} from "./InitLib.sol";
import {MigrationLib} from "./MigrationLib.sol";
import {RebalanceLib} from "./RebalanceLib.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @notice Stablecoin-settled ERC-4626 vault holding a basket of registered assets, with a
/// configurable trust mode and a reallocation proposal mechanism.
/// @dev Deposits buy the basket immediately through each asset's liquidity route; redemptions
/// withdraw the exact proportional share of every asset and let the user pick, per asset, between
/// receiving the token and selling it to the settlement asset. Shares are non-transferable. A performance fee on
/// realized gain (0-20 %, immutable) is charged only at withdrawal, 90 % to the manager and 10 %
/// to the protocol treasury. If both price sources of any basket asset fail, this vault pauses.
/// The trust mode (instant, delayed 1-7 days, or immutable) is chosen at creation and frozen: it
/// gates single reallocation proposals that change the basket assets/weights and the AUM cap
/// (`capAum`, bounded by the registry exposure caps), executed by anyone after the delay with the
/// positions migrated through the registered liquidity routes. The OpenZeppelin inflation-attack
/// mitigation (virtual shares/assets via `_decimalsOffset`, set to 6 for a stronger virtual-share
/// buffer) is preserved.
contract EquiVault is ERC4626, ReentrancyGuard {
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
        uint256 capAum;
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

    address public immutable manager;
    uint16 public immutable feeBps;
    uint16 public immutable maxSlippageBps;
    TimelockMode public immutable timelockMode;
    uint256 public immutable timelockDelay;
    AssetRegistry public immutable registry;
    uint8 private immutable _settlementDecimals;

    address[] private _basketAssets;
    uint16[] private _basketWeightsBps;

    /// @notice Maximum vault value (settlement-asset units) before new deposits are refused.
    /// @dev Bounded by `registry.maxVaultAum` (minimum over the basket); changes only through a
    /// reallocation proposal executed via the vault timelock.
    uint256 public capAum;

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
    error InvalidAumCap(uint256 capAum, uint256 bound);
    error AumCapReached(uint256 navAfter, uint256 capAum);
    error TimelockImmutable();
    error ProposalAlreadyActive(uint256 id);
    error NoActiveProposal();
    error ProposalNotExecutable(uint256 executableAt);
    error ProposalIdMismatch(uint256 activeId, uint256 proposalId);
    error DepositRequiresConsent(uint256 proposalId);
    error AssetNotAdmissible(address asset);
    error InvalidDriftThreshold(uint16 driftBps);
    error InvalidRebalanceSlippage(uint16 slippageBps);
    error DriftBelowThreshold(uint256 maxDeviationBps, uint16 thresholdBps);
    error DeadlineExpired(uint256 timestamp);
    error RebalanceMinTooPermissive(uint256 index, uint256 minOut, uint256 defaultMinOut);

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
        uint16[] weightsBps,
        uint256 capAum
    );

    event ReallocationCancelled(uint256 indexed id);

    event ReallocationExecuted(uint256 indexed id, address[] assets, uint16[] weightsBps, uint256 capAum);

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
        IERC20 settlementAsset,
        AssetRegistry registry_,
        address manager_,
        address[] memory assets,
        uint16[] memory weightsBps,
        uint16 feeBps_,
        uint16 maxSlippageBps_,
        TimelockMode timelockMode_,
        uint256 timelockDelay_,
        uint256 capAum_,
        uint16 driftThresholdBps_,
        uint16 rebalanceSlippageBps_
    ) ERC4626(settlementAsset) ERC20("EquiVault", "EQV") {
        // `timelockMode_` cannot be out of range: Solidity bounds-checks enum values on conversion
        // and on ABI decoding, so an invalid mode is rejected with Panic(0x21) before this code.
        _initBasket(settlementAsset, registry_, assets, weightsBps);

        manager = manager_;
        registry = registry_;
        feeBps = feeBps_;
        maxSlippageBps = maxSlippageBps_;
        timelockMode = timelockMode_;
        timelockDelay = timelockDelay_;

        // Settlement asset decimals drive the NAV scale: `priceE18` follows the USD/Chainlink
        // convention (dollars per whole token at 1e18), so the settlement wei value needs
        // rescaling. Must be set before `_maxVaultAumBound`, which converts the registry ceiling
        // to these units.
        (bool ok, uint8 settlementDecimals) = SafeERC20.tryGetDecimals(settlementAsset);
        _settlementDecimals = ok ? settlementDecimals : 18;

        // AUM cap in settlement-asset units, bounded by the registry-derived exposure ceiling.
        uint256 aumBound = _maxVaultAumBound(assets, weightsBps);

        // Remaining creation bounds are validated in InitLib (kept out of this initcode, which
        // VaultFactory embeds, so the factory stays under the EIP-170 code-size limit). 0 means
        // protocol defaults for drift and rebalance slippage.
        (uint16 drift, uint16 rebalanceSlip) = InitLib.validate(
            manager_, registry_, feeBps_, maxSlippageBps_, timelockMode_, timelockDelay_, capAum_, aumBound,
            driftThresholdBps_, rebalanceSlippageBps_
        );
        capAum = capAum_;
        driftThresholdBps = drift;
        rebalanceSlippageBps = rebalanceSlip;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 overrides
    // ---------------------------------------------------------------------

    /// @notice NAV of the vault expressed in settlement units: each basket asset valued at its live
    /// registry price (primary oracle, then fallback). The settlement balance is deliberately
    /// excluded: exits distribute only the basket, so counting uninvested settlement would break
    /// the link between
    /// share price and redemption value (e.g. under a donation attack).
    function totalAssets() public view override returns (uint256) {
        uint256 nav;
        uint256 n = _basketAssets.length;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            nav += _valueSettlement(a, IERC20(a).balanceOf(address(this)));
        }
        return nav;
    }

    /// @dev Stronger inflation-attack mitigation: virtual shares/assets scale with `10 ** _decimalsOffset()`
    /// (OpenZeppelin mechanism, offset 6 as in the historical v4.9 default). Keeps the vault usable for
    /// later depositors even after a deliberate donation.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        _requireCanDeposit();
        _requireNoActiveProposal();
        _requireAumCapacity(assets);
        shares = previewDeposit(assets);
        _enter(_msgSender(), receiver, assets, shares, new uint256[](0));
    }

    /// @dev `minAmountsOut` applies per basket asset in order; 0 falls back to the vault default bound.
    function deposit(uint256 assets, address receiver, uint256[] calldata minAmountsOut)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _requireCanDeposit();
        _requireNoActiveProposal();
        _requireAumCapacity(assets);
        shares = previewDeposit(assets);
        _enter(_msgSender(), receiver, assets, shares, minAmountsOut);
    }

    /// @dev Same as the `minAmountsOut` overload, but while a reallocation proposal is pending the
    /// caller must consent to the exact displayed proposal id.
    function deposit(uint256 assets, address receiver, uint256[] calldata minAmountsOut, uint256 proposalId)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _requireCanDeposit();
        _requireProposalConsent(proposalId);
        _requireAumCapacity(assets);
        shares = previewDeposit(assets);
        _enter(_msgSender(), receiver, assets, shares, minAmountsOut);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        _requireCanDeposit();
        _requireNoActiveProposal();
        assets = previewMint(shares);
        _requireAumCapacity(assets);
        _enter(_msgSender(), receiver, assets, shares, new uint256[](0));
    }

    /// @dev `minAmountsOut` applies per basket asset in order; 0 falls back to the vault default bound.
    function mint(uint256 shares, address receiver, uint256[] calldata minAmountsOut)
        external
        nonReentrant
        returns (uint256 assets)
    {
        _requireCanDeposit();
        _requireNoActiveProposal();
        assets = previewMint(shares);
        _requireAumCapacity(assets);
        _enter(_msgSender(), receiver, assets, shares, minAmountsOut);
    }

    /// @dev Same as the `minAmountsOut` overload, but consenting to the pending proposal id.
    function mint(uint256 shares, address receiver, uint256[] calldata minAmountsOut, uint256 proposalId)
        external
        nonReentrant
        returns (uint256 assets)
    {
        _requireCanDeposit();
        _requireProposalConsent(proposalId);
        assets = previewMint(shares);
        _requireAumCapacity(assets);
        _enter(_msgSender(), receiver, assets, shares, minAmountsOut);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _requireCanExit();
        shares = previewWithdraw(assets);
        _exit(_msgSender(), receiver, owner, shares, new bool[](0));
    }

    /// @dev `sellTokens[i]` = true sells asset i to the settlement asset, false transfers the
    /// token to `receiver`.
    function withdraw(uint256 assets, address receiver, address owner, bool[] calldata sellTokens)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _requireCanExit();
        shares = previewWithdraw(assets);
        _exit(_msgSender(), receiver, owner, shares, sellTokens);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        assets = _exit(_msgSender(), receiver, owner, shares, new bool[](0));
    }

    /// @dev `sellTokens[i]` = true sells asset i to the settlement asset, false transfers the
    /// token to `receiver`.
    function redeem(uint256 shares, address receiver, address owner, bool[] calldata sellTokens)
        external
        nonReentrant
        returns (uint256 assets)
    {
        assets = _exit(_msgSender(), receiver, owner, shares, sellTokens);
    }

    // ---------------------------------------------------------------------
    // Vault views
    // ---------------------------------------------------------------------

    /// @notice True while any basket asset cannot currently be priced (both oracles invalid).
    function paused() public view returns (bool) {
        uint256 n = _basketAssets.length;
        for (uint256 i = 0; i < n; ++i) {
            if (!_isPriced(_basketAssets[i])) return true;
        }
        return false;
    }

    function basketAssets() external view returns (address[] memory) {
        return _basketAssets;
    }

    /// @notice Settlement asset decimals (read at construction, 18 when unreadable), exposed for
    /// `RebalanceLib` to rescale Chainlink-style prices into settlement units.
    function settlementDecimals() external view returns (uint8) {
        return _settlementDecimals;
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

    /// @notice Proposes a new basket (assets/weights) and AUM cap, gated by the vault trust mode.
    /// @dev `assets_` must be 1-5 registered and Active assets, weights each >= 5 % summing to 100 %,
    /// and `capAum_` bounded by the registry exposure ceiling. A vault in `Immutable` mode refuses
    /// proposals forever. Only one proposal can be active; replacing requires cancelling first and
    /// restarts the full delay.
    function proposeReallocation(address[] calldata assets_, uint16[] calldata weightsBps_, uint256 capAum_)
        external
        onlyManager
    {
        if (timelockMode == TimelockMode.Immutable) revert TimelockImmutable();
        if (_activeProposal.id != 0) revert ProposalAlreadyActive(_activeProposal.id);
        if (_activeParameterProposal.id != 0) revert ProposalAlreadyActive(_activeParameterProposal.id);

        _validateReallocationTarget(assets_, weightsBps_, capAum_);

        uint256 id = ++proposalCounter;
        uint256 executableAt =
            timelockMode == TimelockMode.Instant ? block.timestamp : block.timestamp + timelockDelay;
        _activeProposal = ReallocationProposal({
            id: id,
            executableAt: executableAt,
            assets: assets_,
            weightsBps: weightsBps_,
            capAum: capAum_
        });
        emit ReallocationProposed(id, manager, executableAt, assets_, weightsBps_, capAum_);
    }

    function cancelReallocation() external onlyManager {
        if (_activeProposal.id == 0) revert NoActiveProposal();
        uint256 id = _activeProposal.id;
        delete _activeProposal;
        emit ReallocationCancelled(id);
    }

    /// @dev Permissionless once `executableAt` is reached. Re-validates the target (asset statuses
    /// and registry caps may have changed since propose), then migrates the basket: removed assets
    /// are sold to the settlement asset and added assets are bought from the freed balance, each bounded by
    /// `sellMinOuts`/`buyMinOuts` in removed/added order (0 = vault default slippage bound).
    function executeReallocation(uint256[] calldata sellMinOuts, uint256[] calldata buyMinOuts)
        external
        nonReentrant
    {
        ReallocationProposal memory proposal = _activeProposal;
        if (proposal.id == 0) revert NoActiveProposal();
        if (block.timestamp < proposal.executableAt) revert ProposalNotExecutable(proposal.executableAt);

        _validateReallocationTarget(proposal.assets, proposal.weightsBps, proposal.capAum);
        _migrateBasket(proposal.assets, proposal.weightsBps, sellMinOuts, buyMinOuts);

        capAum = proposal.capAum;
        delete _activeProposal;
        emit ReallocationExecuted(proposal.id, proposal.assets, proposal.weightsBps, proposal.capAum);
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

    function cancelParameterUpdate() external onlyManager {
        if (_activeParameterProposal.id == 0) revert NoActiveProposal();
        uint256 id = _activeParameterProposal.id;
        delete _activeParameterProposal;
        emit ParameterUpdateCancelled(id);
    }

    /// @dev Permissionless once `executableAt` is reached; applies the proposed parameters.
    function executeParameterUpdate() external nonReentrant {
        ParameterProposal memory proposal = _activeParameterProposal;
        if (proposal.id == 0) revert NoActiveProposal();
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
        // can neither inflate it nor receive anything without a valid rebalance. Paid between the
        // sell and buy legs so the pool holds the settlement just received from sells.
        uint256 gasRebate = RebalanceLib.computeRebate(startGas - gasleft());
        IERC20 settlement = IERC20(asset());
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

    function _enter(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares,
        uint256[] memory minAmountsOut
    ) internal {
        _requireCanDeposit();
        _transferIn(caller, assets);
        _buyBasket(assets, minAmountsOut);
        costBasis[receiver] += assets;
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Sells the proportional share of every basket asset, charges the performance fee on
    /// realized gain, then distributes per-asset token or settlement proceeds to `receiver`.
    function _exit(address caller, address receiver, address owner, uint256 shares, bool[] memory sellTokens)
        internal
        returns (uint256 assetsOut)
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        uint256 sharesBefore = balanceOf(owner);
        if (shares > sharesBefore) revert ERC4626ExceededMaxRedeem(owner, shares, sharesBefore);
        _requireCanExit();

        uint256 totalShares = totalSupply();
        uint256 n = _basketAssets.length;
        if (sellTokens.length != 0 && sellTokens.length != n) revert SellFlagsLengthMismatch(n, sellTokens.length);
        bool explicitFlags = sellTokens.length != 0;

        // Exact proportional share of each asset, valued at live prices. The per-asset amounts and
        // the distribution (swaps and transfers) run in ExitLib to keep this runtime under the
        // EIP-170 code-size limit; the vault keeps the storage writes (cost basis, share burn).
        (uint256[] memory amounts, uint256 valueWithdrawn) = ExitLib.computeExitAmounts(this, shares, totalShares);

        // Realized gain on the withdrawn fraction; fee only on positive gain.
        uint256 realizedCost = costBasis[owner].mulDiv(shares, sharesBefore);
        costBasis[owner] -= realizedCost;
        uint256 fee;
        if (valueWithdrawn > realizedCost) {
            fee = (valueWithdrawn - realizedCost).mulDiv(feeBps, BPS_DENOMINATOR);
        }

        _burn(owner, shares);

        _settleFee(ExitLib.distribute(this, receiver, amounts, sellTokens, explicitFlags, fee, valueWithdrawn));

        emit Withdraw(caller, receiver, owner, valueWithdrawn, shares);
        return valueWithdrawn;
    }

    /// @dev Splits the collected fee pot 90 % (manager) / 10 % (treasury) and transfers it.
    function _settleFee(uint256 feePot) internal {
        if (feePot > 0) {
            uint256 managerShare = feePot.mulDiv(MANAGER_FEE_SHARE_BPS, BPS_DENOMINATOR);
            uint256 treasuryShare = feePot - managerShare;
            address treasury = registry.treasury();
            IERC20(asset()).safeTransfer(manager, managerShare);
            IERC20(asset()).safeTransfer(treasury, treasuryShare);
            emit PerformanceFeeCollected(manager, treasury, feePot, managerShare, treasuryShare);
        }
    }

    function _buyBasket(uint256 assets, uint256[] memory minAmountsOut) internal {
        uint256 n = _basketAssets.length;
        if (minAmountsOut.length != 0 && minAmountsOut.length != n) {
            revert MinOutsLengthMismatch(n, minAmountsOut.length);
        }
        bool explicitMins = minAmountsOut.length != 0;
        for (uint256 i = 0; i < n; ++i) {
            address a = _basketAssets[i];
            uint256 alloc = assets.mulDiv(_basketWeightsBps[i], BPS_DENOMINATOR);
            uint256 minOut = explicitMins ? minAmountsOut[i] : _buyMinOut(a, alloc);
            ISwapRouter(registry.assetConfig(a).liquidityRoute).swapExactIn(asset(), a, alloc, minOut);
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
        (uint256 price,) = registry.getPrice(a, asset());
        return price;
    }

    function _isPriced(address a) internal view returns (bool) {
        try registry.getPrice(a, asset()) returns (uint256 price, uint256) {
            return price != 0;
        } catch {
            return false;
        }
    }

    function _requireNoActiveProposal() internal view {
        if (_activeProposal.id != 0) revert DepositRequiresConsent(_activeProposal.id);
    }

    function _requireProposalConsent(uint256 proposalId) internal view {
        uint256 activeId = _activeProposal.id;
        if (activeId == 0) revert NoActiveProposal();
        if (proposalId != activeId) revert ProposalIdMismatch(activeId, proposalId);
    }

    /// @dev Refuses deposits that would push the vault NAV above `capAum`; a cap below the current
    /// NAV therefore blocks all new deposits (without forcing withdrawals) until redemptions lower it.
    function _requireAumCapacity(uint256 assets) internal view {
        uint256 navAfter = totalAssets() + assets;
        if (navAfter > capAum) revert AumCapReached(navAfter, capAum);
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

    /// @dev Rejects a reallocation target whose basket or cap violates the vault rules. Asset
    /// statuses are checked with `canOpenExposure` so a proposal can only target assets the vault
    /// may still open exposure to.
    function _validateReallocationTarget(
        address[] memory assets_,
        uint16[] memory weightsBps_,
        uint256 capAum_
    ) internal view {
        uint256 n = assets_.length;
        if (n == 0 || n > MAX_BASKET_SIZE) revert InvalidBasketSize(n);
        if (n != weightsBps_.length) revert BasketLengthMismatch(n, weightsBps_.length);

        uint256 weightSum;
        for (uint256 i = 0; i < n; ++i) {
            address a = assets_[i];
            if (a == address(0)) revert InvalidAddress();
            if (a == address(asset())) revert SettlementAssetInBasket(a);
            for (uint256 j = 0; j < i; ++j) {
                if (assets_[j] == a) revert DuplicateAsset(a);
            }
            if (!registry.canOpenExposure(a)) revert AssetNotAdmissible(a);
            uint16 weight = weightsBps_[i];
            if (weight < MIN_WEIGHT_BPS) revert InvalidWeight(weight);
            weightSum += weight;
        }
        if (weightSum != BPS_DENOMINATOR) revert WeightsMustSumTo10000(weightSum);

        uint256 bound = _maxVaultAumBound(assets_, weightsBps_);
        if (capAum_ == 0 || capAum_ > bound) revert InvalidAumCap(capAum_, bound);
    }

    /// @dev Minimum over the basket of the registry-derived vault ceiling, converted to
    /// settlement-asset units (the registry expresses the ceiling in USD at 1e18).
    function _maxVaultAumBound(address[] memory assets_, uint16[] memory weightsBps_)
        internal
        view
        returns (uint256)
    {
        uint256 bound = type(uint256).max;
        uint256 n = assets_.length;
        for (uint256 i = 0; i < n; ++i) {
            uint256 b = registry.maxVaultAum(assets_[i], weightsBps_[i]);
            b = b.mulDiv(10 ** _settlementDecimals, 1e18);
            if (b < bound) bound = b;
        }
        return bound;
    }

    /// @dev Migrates the held basket toward the proposal target: sells removed assets entirely to
    /// the settlement asset, buys added assets proportionally to their target weights from the
    /// freed balance, and approves each new liquidity route. Kept assets keep their positions;
    /// weight drift is left to the rebalance engine. The swap/approval work runs in `MigrationLib`
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

    function transfer(address, uint256) public pure override(ERC20, IERC20) returns (bool) {
        revert SharesNonTransferable();
    }

    function transferFrom(address, address, uint256) public pure override(ERC20, IERC20) returns (bool) {
        revert SharesNonTransferable();
    }
}
