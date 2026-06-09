// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title DreUSDBlockedMock
 * @dev Minimal mock for `isBlockedAddress` checks in keeper tests
 */
contract DreUSDBlockedMock {
    mapping(address => bool) public blocked;

    function setBlocked(address account, bool value) external {
        blocked[account] = value;
    }

    function isBlockedAddress(address account) external view returns (bool) {
        return blocked[account];
    }
}
