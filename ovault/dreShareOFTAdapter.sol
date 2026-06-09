// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { OFTAdapterUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTAdapterUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title dreShareOFTAdapter
 * @notice OFT adapter for vault shares enabling cross-chain transfers
 * @dev The share token MUST be an OFT adapter (lockbox).
 * @dev A mint-burn adapter would not work since it transforms `ShareERC20::totalSupply()`
 * @dev This adapter should be deployed on the hub chain only
 */
contract dreShareOFTAdapter is Initializable, OFTAdapterUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Recipient for tokens when credit to recipient fails (e.g. sanctioned, frozen)
    address public stuckFundsRecipient;

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    /// @notice Emitted when credit to recipient fails and tokens are sent to stuckFundsRecipient instead
    event StuckFundsRecovered(address indexed to, uint256 amountLD, uint32 srcEid);
    
    /// @notice Emitted when stuck funds recipient is updated
    event StuckFundsRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // ============ Errors ============
    error ZeroAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _token,
        address _lzEndpoint
    ) OFTAdapterUpgradeable(_token, _lzEndpoint) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the OFT adapter for vault shares
     * @dev Sets up cross-chain token transfer capabilities for vault shares
     * @param _delegate The account with administrative privileges
     * @param _stuckFundsRecipient Multisig (or safe) that receives tokens when credit to recipient fails
     */
    function initialize(address _delegate, address _stuckFundsRecipient) public initializer {
        if (_delegate == address(0)) revert ZeroAddress();
        if (_stuckFundsRecipient == address(0)) revert ZeroAddress();

        __OFTAdapter_init(_delegate);
        __Ownable_init(_delegate);
        stuckFundsRecipient = _stuckFundsRecipient;
    }

    /**
     * @notice Sets the address that receives tokens when credit to recipient fails
     * @param _stuckFundsRecipient Multisig (or safe) address
     */
    function setStuckFundsRecipient(address _stuckFundsRecipient) external onlyOwner {
        if (_stuckFundsRecipient == address(0)) revert ZeroAddress();
        address oldRecipient = stuckFundsRecipient;
        stuckFundsRecipient = _stuckFundsRecipient;
        emit StuckFundsRecipientUpdated(oldRecipient, _stuckFundsRecipient);
    }

    /**
     * @dev Override _credit to fall back to stuckFundsRecipient when transfer to recipient fails.
     */
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 _srcEid
    ) internal override returns (uint256 amountReceivedLD) {
        if (!_tryTransfer(_to, _amountLD)) {
            innerToken.safeTransfer(stuckFundsRecipient, _amountLD);
            emit StuckFundsRecovered(_to, _amountLD, _srcEid);
            return _amountLD;
        }
        return _amountLD;
    }

    /// @dev External call so we can try/catch; only used by _credit
    function _tryTransfer(address to, uint256 amount) internal returns (bool) {
        try IERC20(innerToken).transfer(to, amount) returns (bool success) {
            return success;
        } catch {
            return false;
        }
    }



    /**
     * @dev Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     * @dev Only the owner can authorize upgrades
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
