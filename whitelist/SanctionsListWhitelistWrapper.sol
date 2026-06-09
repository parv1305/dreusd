// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ISanctionsList} from "../interfaces/ISanctionsList.sol";

/**
 * @title SanctionsListWhitelistWrapper
 * @notice Adapter over a sanctions oracle with an allowlist gate.
 * @dev Non-whitelisted addresses are treated as sanctioned: `isSanctioned(addr)` is `true` and the
 *      underlying list is not read. Whitelisted addresses defer to `sanctionsList.isSanctioned(addr)`.
 */
contract SanctionsListWhitelistWrapper is AccessControl, ISanctionsList {
    /// @notice Role allowed to add or remove whitelist entries.
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");

    /// @notice Underlying sanctions oracle (e.g. Chainalysis).
    ISanctionsList public immutable sanctionsList;

    mapping(address => bool) private _whitelisted;

    event AddressWhitelisted(address indexed account);
    event AddressRemovedFromWhitelist(address indexed account);

    error SanctionsListZeroAddress();
    error AdminZeroAddress();

    /**
     * @param sanctionsList_ Underlying list; its `isSanctioned` is evaluated only when `addr` is
     *        whitelisted (non-whitelisted `addr` short-circuits to sanctioned without an oracle call).
     * @param admin Receives `DEFAULT_ADMIN_ROLE` (can grant/revoke `MODERATOR_ROLE`).
     */
    constructor(ISanctionsList sanctionsList_, address admin) {
        if (address(sanctionsList_) == address(0)) revert SanctionsListZeroAddress();
        if (admin == address(0)) revert AdminZeroAddress();

        sanctionsList = sanctionsList_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc ISanctionsList
    function isSanctioned(address addr) external view override returns (bool) {
        return _whitelisted[addr] == false || sanctionsList.isSanctioned(addr);
    }

    /// @notice Whether `account` is whitelisted
    function isWhitelisted(address account) external view returns (bool) {
        return _whitelisted[account];
    }

    /**
     * @notice Adds `account` to the whitelist so `isSanctioned` reads the underlying oracle for it.
     */
    function addToWhitelist(address account) external onlyRole(MODERATOR_ROLE) {
        _whitelisted[account] = true;
        emit AddressWhitelisted(account);
    }

    /**
     * @notice Removes `account` from the whitelist; `isSanctioned` becomes `true` without consulting the oracle.
     */
    function removeFromWhitelist(address account) external onlyRole(MODERATOR_ROLE) {
        _whitelisted[account] = false;
        emit AddressRemovedFromWhitelist(account);
    }

    /// @inheritdoc AccessControl
    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return interfaceId == type(ISanctionsList).interfaceId || super.supportsInterface(interfaceId);
    }
}
