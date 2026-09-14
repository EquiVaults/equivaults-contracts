// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockToken} from "../test/mocks/Mocks.sol";

/// @notice Local-only ERC-20 used by the rich Anvil fixture.
/// @dev It retains MockToken's unrestricted test minting and configurable decimals, while exposing
/// realistic-looking metadata for the frontend's on-chain metadata path. It is never deployed by
/// the default DeployLocal run or any production deployment script.
contract NamedMockToken is MockToken {
    string private _demoName;
    string private _demoSymbol;

    constructor(string memory demoName, string memory demoSymbol, uint8 tokenDecimals) MockToken(tokenDecimals) {
        _demoName = demoName;
        _demoSymbol = demoSymbol;
    }

    function name() public view override returns (string memory) {
        return _demoName;
    }

    function symbol() public view override returns (string memory) {
        return _demoSymbol;
    }
}
