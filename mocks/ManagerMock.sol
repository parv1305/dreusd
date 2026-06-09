// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ManagerMock
 * @dev Mock contract for testing manager functionality
 */
contract ManagerMock {
    address public token;

    function setToken(address _token) external {
        token = _token;
    }
}
