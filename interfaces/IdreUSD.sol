// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IdreUSD
 * @dev Interface for dreUSD token contract
 */
interface IdreUSD {
    // ============ Errors ============

    error ZeroAddress();
    error InvalidCaller();
    error SanctionedAddress(address addr);
    error FrozenAddress(address addr);
    error SameSanctionsList();
    error AlreadyFrozen(address account);
    error AlreadyUnfrozen(address account);

    // ============ Events ============

    event SanctionsListUpdated(address indexed oldSanctionsList, address indexed newSanctionsList);
    event DreUSDManagerUpdated(address indexed oldManager, address indexed newManager);
    event AddressFrozen(address indexed account);
    event AddressUnfrozen(address indexed account);

    // ============ View Functions ============

    /**
     * @notice Returns the sanctions list address
     * @return The address of the sanctions list contract
     */
    function sanctionsList() external view returns (address);

    /**
     * @notice Checks if an address is frozen
     * @param account Address to check
     * @return True if the address is frozen
     */
    function frozen(address account) external view returns (bool);

    /**
     * @notice Validates an address against current sanctions and freeze rules.
     *         MUST revert with FrozenAddress or SanctionedAddress on failure.
     * @param account Address to validate
     */
    function validateAddress(address account) external view;

    /**
     * @notice Returns true if the address is frozen or sanctioned (blocked from transfers).
     * @param account Address to check
     * @return True if the address is blocked
     */
    function isBlockedAddress(address account) external view returns (bool);

    // ============ Admin Functions ============

    /**
     * @notice Sets the sanctions list address
     * @param _sanctionsList New sanctions list address
     */
    function setSanctionsList(address _sanctionsList) external;

    /**
     * @notice Freezes an address, preventing transfers to/from it
     * @param account Address to freeze
     */
    function freeze(address account) external;

    /**
     * @notice Unfreezes an address, allowing transfers to/from it again
     * @param account Address to unfreeze
     */
    function unfreeze(address account) external;

    // ============ Token Functions ============

    /**
     * @notice Mints tokens to a specified address (manager only)
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burns tokens from a specified address (manager only)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external;
}
