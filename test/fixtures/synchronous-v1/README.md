# Legacy synchronous v1 fixture

This fixture is an auditable historical source extraction for local compatibility tests and
the local dual-version deployment. It was extracted with `git show` from this repository at
`c2f5605aec16d4121bd2c43354d7effef81cee95`.

The extracted sources are `EquiVault.sol`, `VaultFactory.sol`, `ExitLib.sol`, `InitLib.sol`,
`MigrationLib.sol`, `RebalanceLib.sol`, and `interfaces/ISwapRouter.sol` from that commit.
The only transformations are mechanical identifier renames to the `Legacy*`/`ILegacy*` names
so their artifacts cannot collide with v2, corresponding relative-import updates, and using
the unchanged current `src/AssetRegistry.sol`. The v1 source and current registry are
byte-for-byte identical at this source boundary. No economic or protocol behavior was changed.

`LegacyVaultFactory` has intentionally no `protocolVersion()` getter. Local discovery treats
its deployed runtime code hash and this recorded source commit as the v1 compatibility identity.
