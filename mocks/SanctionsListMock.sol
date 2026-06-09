// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISanctionsList} from "../interfaces/ISanctionsList.sol";

/**
 * @title SanctionsListMock
 * @dev Mock contract for testing sanctions list functionality
 */
contract SanctionsListMock is ISanctionsList {
    mapping(address => bool) private _sanctioned;

    function isSanctioned(address addr) external view override returns (bool) {
        return _sanctioned[addr];
    }

    function setSanctioned(address addr, bool sanctioned) external {
        _sanctioned[addr] = sanctioned;
    }

    function removeSanctioned(address addr) external {
        delete _sanctioned[addr];
    }
}
