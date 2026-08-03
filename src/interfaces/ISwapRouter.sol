// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal exact-input swap interface used by vaults.
/// @dev Each registered asset carries its own `liquidityRoute`; the vault uses that route for both
/// buying (USDC -> asset) and selling (asset -> USDC) against the settlement asset.
interface ISwapRouter {
    error SlippageExceeded(uint256 minAmountOut, uint256 amountOut);

    /// @notice Swaps exactly `amountIn` of `assetIn` for `assetOut`, reverting below `minAmountOut`.
    function swapExactIn(address assetIn, address assetOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
}
