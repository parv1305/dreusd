// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title EndpointV2Mock
 * @dev Minimal mock for LayerZero EndpointV2 - implements setDelegate for initialization
 */
contract EndpointV2Mock {
    mapping(address => address) public delegates;

    /**
     * @dev Sets the delegate for an OApp
     * @param _delegate The delegate address
     */
    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }
}
