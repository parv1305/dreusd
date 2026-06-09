// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { OFTUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IdreUSD } from "../interfaces/IdreUSD.sol";

/**
 * @title dreShareOFT
 * @notice ERC20 representation of the vault's share token on a spoke chain for cross-chain functionality
 * @dev This contract represents the vault's share tokens on spoke chains. It inherits from
 * LayerZero's OFT (Omnichain Fungible Token) to enable seamless cross-chain transfers of
 * vault shares between the hub chain and spoke chains. This contract is designed to work
 * with ERC4626-compliant vaults, enabling standardized cross-chain vault interactions.
 *
 * Share tokens represent ownership in the vault and can be redeemed for the underlying
 * asset on the hub chain. The OFT mechanism ensures that shares maintain their value and can be freely
 * moved across supported chains while preserving the vault's accounting integrity.
 *
 * COMPLIANCE: All transfer validation delegates to dreUSD (same address across chains). Single
 * compliance source per chain.
 *
 * UPGRADEABILITY: This contract uses UUPS (Universal Upgradeable Proxy Standard) pattern,
 * allowing the implementation to be upgraded while preserving state and address.
 */
contract dreShareOFT is Initializable, OFTUpgradeable, UUPSUpgradeable {

    // ============ Errors ============
    error ZeroAddress();

    // ============ Immutable ============
    /// @notice dreUSD address (same across all chains); all address validation delegates here.
    address public immutable dreUSDCompliance;

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint, address _dreUSDCompliance) OFTUpgradeable(_lzEndpoint) {
        if (_dreUSDCompliance == address(0)) revert ZeroAddress();
        dreUSDCompliance = _dreUSDCompliance;
        _disableInitializers();
    }

    /**
     * @notice Initializes the Share OFT contract
     * @dev Initializes the OFT with LayerZero endpoint and sets up ownership
     * @param _name The name of the share token
     * @param _symbol The symbol of the share token
     * @param _delegate The address that will have owner privileges
     */
    function initialize(
        string memory _name,
        string memory _symbol,
        address _delegate
    ) public initializer {
        if (_delegate == address(0)) revert ZeroAddress();

        __OFT_init(_name, _symbol, _delegate);
        __Ownable_init(_delegate);

        // WARNING: Do NOT mint share tokens directly as this breaks the vault's share-to-asset ratio
        // Share tokens should only be minted when receiving cross-chain transfers via OFT._credit()
        // which calls _mint() when shares are sent from the hub chain to this spoke chain.
        // The OFT contract automatically mints tokens when receiving cross-chain messages via lzReceive.
        // _mint(msg.sender, 1 ether); // ONLY uncomment for testing UI/integration, never in production
    }

    // ============ Internal Functions ============

    /**
     * @notice Validates an address via dreUSD (single compliance source).
     * @dev Reverts with IdreUSD.FrozenAddress or IdreUSD.SanctionedAddress if validation fails.
     * @param addr Address to validate
     */
    function _validateAddress(address addr) internal view {
        IdreUSD(dreUSDCompliance).validateAddress(addr);
    }

    /**
     * @notice ERC20 hook called before any share transfer, mint, or burn.
     * @dev Enforces that both source and destination addresses comply with dreUSD sanctions/freeze.
     * @param from Address tokens are transferred from
     * @param to Address tokens are transferred to
     * @param value Amount of tokens transferred
     */
    function _update(address from, address to, uint256 value) internal override {
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
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
