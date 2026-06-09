// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IdreUSD} from "./interfaces/IdreUSD.sol";
import {ISanctionsList} from "./interfaces/ISanctionsList.sol";
import {OFTUpgradeable} from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title dreUSD
 * @dev ERC20 token with permit functionality and access control, upgradeable via UUPS proxy.
 *
 * LayerZero crediting: _credit() mints via ERC20Upgradeable._update to bypass address validation.
 * Recipient is outer SendParam.to (standard send) or the inner recipient from composeMsg (compose
 * send); neither is pre-validated for sanctions/freeze. If the recipient is frozen/sanctioned on
 * this chain, tokens are still minted but remain quarantined (transfer/send call _validateAddress
 * and revert). See docs/BRIDGE_COMPLIANCE.md for quarantine policy and handling procedures.
 */
contract dreUSD is
    Initializable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    OFTUpgradeable,
    IdreUSD
{
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    address public sanctionsList;

    /// @notice dreUSDManager contract; only this address may call mint() and burn()
    address public dreUSDManager;

    /// @notice Mapping of frozen addresses
    mapping(address => bool) public frozen;

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    modifier onlyGuardian() {
        _checkRole(GUARDIAN_ROLE);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint) OFTUpgradeable(_lzEndpoint) {
        _disableInitializers();
    }

    // public and external functions

    /**
     * @dev Initializes the contract
     * @param defaultAdmin Address to grant the default admin role
     * @param upgrader Address to grant the upgrader role
     * @param guardian Address to grant the guardian role
     */
    function initialize(address defaultAdmin, address upgrader, address guardian) public initializer {
        if (defaultAdmin == address(0)) revert ZeroAddress();
        if (upgrader == address(0)) revert ZeroAddress();
        if (guardian == address(0)) revert ZeroAddress();

        __AccessControl_init_unchained();
        __Ownable_init_unchained(defaultAdmin);
        __OFT_init("dreUSD", "dreUSD", defaultAdmin);
        __EIP712_init_unchained("dreUSD", "1");
        __ERC20Permit_init_unchained("dreUSD");

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, upgrader);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    /// @inheritdoc IdreUSD
    function setSanctionsList(address _sanctionsList) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_sanctionsList == sanctionsList) revert SameSanctionsList();
        address oldSanctionsList = sanctionsList;
        sanctionsList = _sanctionsList;
        emit SanctionsListUpdated(oldSanctionsList, _sanctionsList);
    }

    /// @inheritdoc IdreUSD
    function mint(address to, uint256 amount) external {
        if (msg.sender != dreUSDManager) revert InvalidCaller();
        _mint(to, amount);
    }

    /// @inheritdoc IdreUSD
    function burn(address from, uint256 amount) external {
        if (msg.sender != dreUSDManager) revert InvalidCaller();
        _burn(from, amount);
    }

    /**
     * @notice Set the dreUSDManager address (only this contract may call mint() and burn())
     * @param _dreUSDManager dreUSDManager contract address
     */
    function setDreUSDManager(address _dreUSDManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_dreUSDManager == address(0)) revert ZeroAddress();
        address oldManager = dreUSDManager;
        dreUSDManager = _dreUSDManager;
        emit DreUSDManagerUpdated(oldManager, _dreUSDManager);
    }

    /// @inheritdoc IdreUSD
    function freeze(address account) external onlyGuardian {
        if (account == address(0)) revert ZeroAddress();
        if (frozen[account]) revert AlreadyFrozen(account);
        frozen[account] = true;
        emit AddressFrozen(account);
    }

    /// @inheritdoc IdreUSD
    function unfreeze(address account) external onlyGuardian {
        if (account == address(0)) revert ZeroAddress();
        if (!frozen[account]) revert AlreadyUnfrozen(account);
        frozen[account] = false;
        emit AddressUnfrozen(account);
    }

    // internal functions

    /**
     * @dev Validates an address is not frozen or sanctioned
     * @param addr Address to validate
     */
    function _validateAddress(address addr) internal view {
        if (frozen[addr]) {
            revert FrozenAddress(addr);
        }

        if (sanctionsList != address(0) && ISanctionsList(sanctionsList).isSanctioned(addr)) {
            revert SanctionedAddress(addr);
        }
    }
    
    /// @inheritdoc IdreUSD
    function validateAddress(address account) external view override {
        _validateAddress(account);
    }

    /// @inheritdoc IdreUSD
    function isBlockedAddress(address account) external view override returns (bool) {
        try this.validateAddress(account) {
            return false;
        } catch {
            return true;
        }
    }

    /**
     * @dev Hook that is called before any token transfer, including minting and burning
     *      Checks for sanctioned and frozen addresses
     * @param from Address tokens are transferred from
     * @param to Address tokens are transferred to
     * @param value Amount of tokens transferred
     */
    function _update(address from, address to, uint256 value) internal override {
        // Skip validation for address(0) to allow minting and burning
        if (from != address(0)) {
            _validateAddress(from);
        }
        if (to != address(0)) {
            _validateAddress(to);
        }

        super._update(from, to, value);
    }

    /**
     * @dev Override LZ _credit to mint via ERC20Upgradeable._update, bypassing address validation.
     * _to is outer SendParam.to (standard) or inner compose recipient (compose path); not
     * pre-validated. If frozen/sanctioned here, tokens are quarantined (transfer/send revert).
     * See docs/BRIDGE_COMPLIANCE.md.
     * @param _to Recipient on destination chain
     * @param _amountLD Amount to credit in local decimals
     * @return amountReceivedLD Amount credited (always _amountLD for native OFT)
     */
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /*_srcEid*/
    ) internal virtual override returns (uint256 amountReceivedLD) {
        if (_to == address(0)) _to = address(0xdead);
        // Bypass our _update (and thus _validateAddress) by calling base ERC20 _update directly.
        ERC20Upgradeable._update(address(0), _to, _amountLD);
        return _amountLD;
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /**
     * @dev Override transferOwnership to require DEFAULT_ADMIN_ROLE instead of onlyOwner.
     * @param newOwner Address of the new owner
     */
    function transferOwnership(address newOwner) public override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _transferOwnership(newOwner);
    }

    /**
     * @dev Override renounceOwnership to require DEFAULT_ADMIN_ROLE instead of onlyOwner.
     *      Calls _transferOwnership(address(0)) directly to avoid the parent's onlyOwner check.
     */
    function renounceOwnership() public override onlyRole(DEFAULT_ADMIN_ROLE) {
        _transferOwnership(address(0));
    }
}
