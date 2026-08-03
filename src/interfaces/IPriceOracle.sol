// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPriceOracle {
    error InvalidPrice(address base, address quote, int256 answer);
    error StalePrice(address base, address quote, uint256 updatedAt, uint256 validUntil);

    /// @dev `priceE18` is the quote-token amount for one whole base token, normalized to 1e18.
    function getPrice(address base, address quote) external view returns (uint256 priceE18, uint256 updatedAt);
}
