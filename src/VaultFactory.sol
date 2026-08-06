// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AssetRegistry} from "./AssetRegistry.sol";
import {EquiVault} from "./EquiVault.sol";

/// @notice Permissionless factory deploying non-upgradeable EquiVaults for one deployment chain.
/// @dev One factory per chain, bound at construction to that deployment's settlement asset (USDG
/// on Robinhood Chain per the 2026-08-05 decision; any ERC-20 on other EVM chains — multichain
/// decision of 2026-08-06: the chain is a configuration layer, never a code layer). `createVault`
/// only admits assets the registry currently opens exposure to, fixes manager, trust mode,
/// timelock, performance fee, max slippage, drift, rebalance slippage and AUM cap within their
/// bounds at creation, and records the vault in a public registry the frontend can enumerate
/// without a backend. The chain id is exposed for indexers; no signature scheme is used yet, so no
/// EIP-712 domain is needed — any future signature scheme MUST include the chain id in its domain
/// so a vault created on Robinhood Chain is never replayable on another EVM chain.
contract VaultFactory {
    /// @notice Deployment settlement asset; every vault created here settles in it.
    IERC20 public immutable settlementAsset;

    /// @notice Asset catalogue whose admission state gates every creation.
    AssetRegistry public immutable registry;

    address[] private _vaults;
    mapping(address vault => bool created) private _created;

    error InvalidAddress();
    error AssetNotAdmissible(address asset);

    /// @notice Emitted for every created vault with the immutable parameters the frontend needs to
    /// rebuild the list and the manager's history from RPC events, without a backend. The basket is
    /// read live from the vault itself (`basketAssets()`/`basketWeightsBps()`) so an indexer never
    /// serves a stale composition after a reallocation.
    event VaultCreated(
        address indexed vault,
        address indexed manager,
        address indexed settlementAsset,
        uint256 chainId,
        EquiVault.TimelockMode timelockMode,
        uint256 timelockDelay,
        uint16 feeBps,
        uint16 maxSlippageBps,
        uint16 driftThresholdBps,
        uint16 rebalanceSlippageBps,
        uint256 capAum
    );

    constructor(IERC20 settlementAsset_, AssetRegistry registry_) {
        if (address(settlementAsset_) == address(0)) revert InvalidAddress();
        if (address(registry_) == address(0)) revert InvalidAddress();
        settlementAsset = settlementAsset_;
        registry = registry_;
    }

    /// @notice Deploys a new non-upgradeable vault, paying the gas from the caller.
    /// @param manager_ Owner of the vault; can never change afterwards.
    /// @param assets_ 1-5 registered and currently admitted basket assets.
    /// @param weightsBps_ Target weights, each >= 5 % and summing exactly to 100 %.
    /// @param feeBps_ Immutable performance fee on realized gain (0-20 %).
    /// @param maxSlippageBps_ Immutable max swap slippage bound (0-30 %).
    /// @param timelockMode_ Instant / Delayed (1-7 days) / Immutable, frozen forever.
    /// @param timelockDelay_ Delay used by Delayed mode, otherwise must be 0.
    /// @param capAum_ AUM cap in settlement units, bounded by the registry exposure ceilings.
    /// @param driftThresholdBps_ Rebalance drift threshold (1-10 points; 0 = default 3).
    /// @param rebalanceSlippageBps_ Collective rebalance slippage (0.1-3 %; 0 = default 1 %).
    /// @return vault Address of the deployed EquiVault.
    function createVault(
        address manager_,
        address[] calldata assets_,
        uint16[] calldata weightsBps_,
        uint16 feeBps_,
        uint16 maxSlippageBps_,
        EquiVault.TimelockMode timelockMode_,
        uint256 timelockDelay_,
        uint256 capAum_,
        uint16 driftThresholdBps_,
        uint16 rebalanceSlippageBps_
    ) external returns (address vault) {
        // Only assets the registry currently admits may enter a new basket; the EquiVault
        // constructor then enforces the remaining bounds (basket size, weights, fee, slippage,
        // timelock, AUM cap, drift and rebalance slippage) with specific errors.
        uint256 n = assets_.length;
        for (uint256 i = 0; i < n; ++i) {
            if (!registry.canOpenExposure(assets_[i])) revert AssetNotAdmissible(assets_[i]);
        }

        vault = _deploy(manager_, assets_, weightsBps_, feeBps_, maxSlippageBps_, timelockMode_, timelockDelay_, capAum_,
            driftThresholdBps_, rebalanceSlippageBps_);
        _vaults.push(vault);
        _created[vault] = true;

        // The event mirrors the vault's effective state (after applying the protocol defaults for
        // drift/slippage when 0 was passed), so indexers never have to second-guess a field.
        EquiVault v = EquiVault(vault);
        emit VaultCreated(
            vault, manager_, address(settlementAsset), block.chainid, v.timelockMode(), v.timelockDelay(), v.feeBps(),
            v.maxSlippageBps(), v.driftThresholdBps(), v.rebalanceSlippageBps(), v.capAum()
        );
    }

    /// @dev Deploys the vault through the constructor, keeping the creation call's stack shallow.
    function _deploy(
        address manager_,
        address[] calldata assets_,
        uint16[] calldata weightsBps_,
        uint16 feeBps_,
        uint16 maxSlippageBps_,
        EquiVault.TimelockMode timelockMode_,
        uint256 timelockDelay_,
        uint256 capAum_,
        uint16 driftThresholdBps_,
        uint16 rebalanceSlippageBps_
    ) private returns (address vault) {
        vault = address(
            new EquiVault(
                settlementAsset,
                registry,
                manager_,
                assets_,
                weightsBps_,
                feeBps_,
                maxSlippageBps_,
                timelockMode_,
                timelockDelay_,
                capAum_,
                driftThresholdBps_,
                rebalanceSlippageBps_
            )
        );
    }

    /// @notice Chain id of this deployment, for indexers and cross-chain tooling.
    function chainId() external view returns (uint256) {
        return block.chainid;
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    /// @notice Vault address at `index` in creation order.
    function vaults(uint256 index) external view returns (address) {
        return _vaults[index];
    }

    /// @notice True when `candidate` was created by this factory (anti-impersonation check).
    function isVault(address candidate) external view returns (bool) {
        return _created[candidate];
    }
}
