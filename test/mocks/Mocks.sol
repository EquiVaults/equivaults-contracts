// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {ISwapRouter} from "../../src/interfaces/ISwapRouter.sol";

/// @dev Minimal ERC-20 with configurable decimals, used as USDC and basket tokens in tests.
contract MockToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(uint8 tokenDecimals) ERC20("Mock Token", "MOCK") {
        _tokenDecimals = tokenDecimals;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Configurable IPriceOracle: price and timestamp settable, or forced to fail (both-sources-down simulation).
contract MockOracle is IPriceOracle {
    uint256 internal _price;
    uint256 internal _updatedAt;
    bool internal _fails;

    function setPrice(uint256 price, uint256 updatedAt) external {
        _price = price;
        _updatedAt = updatedAt;
    }

    function setFails(bool fails) external {
        _fails = fails;
    }

    function getPrice(address, address) external view returns (uint256, uint256) {
        require(!_fails, "oracle unavailable");
        return (_price, _updatedAt);
    }
}

/// @dev Constant-product pool (USDC/token) implementing ISwapRouter, with configurable swap fee.
/// The pool holds both legs; `swapExactIn` enforces `minAmountOut` on-chain like a real DEX route.
contract MockPool is ISwapRouter {
    uint16 public immutable swapFeeBps;
    IERC20 public immutable usdc;
    IERC20 public immutable token;
    mapping(address => uint256) public reserveOf;

    constructor(IERC20 usdc_, IERC20 token_, uint16 swapFeeBps_) {
        usdc = usdc_;
        token = token_;
        swapFeeBps = swapFeeBps_;
    }

    function seed(uint256 usdcAmount, uint256 tokenAmount) external {
        bool usdcOk = usdc.transferFrom(msg.sender, address(this), usdcAmount);
        bool tokenOk = token.transferFrom(msg.sender, address(this), tokenAmount);
        require(usdcOk && tokenOk, "MockPool: seed transfer failed");
        reserveOf[address(usdc)] += usdcAmount;
        reserveOf[address(token)] += tokenAmount;
    }

    function swapExactIn(address assetIn, address assetOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        if (assetIn == address(usdc)) {
            require(assetOut == address(token), "MockPool: wrong pair");
        } else {
            require(assetIn == address(token) && assetOut == address(usdc), "MockPool: wrong pair");
        }

        uint256 rIn = reserveOf[assetIn];
        uint256 rOut = reserveOf[assetOut];
        uint256 amountInNet = amountIn * (10_000 - swapFeeBps) / 10_000;
        amountOut = rOut - (rIn * rOut) / (rIn + amountInNet);
        if (amountOut < minAmountOut) revert SlippageExceeded(minAmountOut, amountOut);

        bool inOk = IERC20(assetIn).transferFrom(msg.sender, address(this), amountIn);
        bool outOk = IERC20(assetOut).transfer(msg.sender, amountOut);
        require(inOk && outOk, "MockPool: swap transfer failed");
        reserveOf[assetIn] = rIn + amountIn;
        reserveOf[assetOut] = rOut - amountOut;
    }
}
