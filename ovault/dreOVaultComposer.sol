// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { VaultComposerSync } from "@layerzerolabs/ovault-evm/contracts/VaultComposerSync.sol";
import { IOFT, SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title dreOVaultComposer
 * @notice Cross-chain vault composer enabling omnichain vault operations via LayerZero
 * @dev This composer should be deployed on the hub chain only
 */
contract dreOVaultComposer is VaultComposerSync, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Error thrown when native token refund fails to both refundAddress and msg.sender
    error NativeRefundFailed();
    
    /// @notice Error thrown when stuck funds recipient is the zero address
    error StuckFundsRecipientZero();

    /// @notice Recipient for tokens when both compose and refund fail (e.g. sanctions, pause, frozen recipient)
    address public stuckFundsRecipient;

    /// @notice Emitted when refund to source fails and tokens are sent to stuckFundsRecipient instead
    event StuckFundsRecovered(address indexed oft, uint256 amount, uint256 msgValue, address refundAddress);
    
    /// @notice Emitted when stuck funds recipient is updated
    event StuckFundsRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /**
     * @notice Creates a new cross-chain vault composer
     * @param _dreUSDs The vault contract implementing ERC4626 for deposit/redeem operations
     * @param _dreUSD The OFT contract for cross-chain asset transfers (dreUSD)
     * @param _dreShareOFTAdapter On hub: dreShareOFTAdapter
     * @param _stuckFundsRecipient Multisig (or safe address) that receives tokens when refund to source fails
     */
    constructor(
        address _dreUSDs,
        address _dreUSD,
        address _dreShareOFTAdapter,
        address _stuckFundsRecipient
    ) VaultComposerSync(_dreUSDs, _dreUSD, _dreShareOFTAdapter) Ownable(msg.sender) {
        if (_stuckFundsRecipient == address(0)) revert StuckFundsRecipientZero();
        stuckFundsRecipient = _stuckFundsRecipient;
    }

    /**
     * @notice Sets the address that receives tokens when refund to source fails
     * @param _stuckFundsRecipient Multisig (or safe) address; must not be address(0)
     */
    function setStuckFundsRecipient(address _stuckFundsRecipient) external onlyOwner {
        if (_stuckFundsRecipient == address(0)) revert StuckFundsRecipientZero();
        address oldRecipient = stuckFundsRecipient;
        stuckFundsRecipient = _stuckFundsRecipient;
        emit StuckFundsRecipientUpdated(oldRecipient, _stuckFundsRecipient);
    }

    /**
     * @dev Override _depositAndSend to separate vault-conversion slippage from OFT slippage
     * @dev This fixes the audit issue where minAmountLD is set to 0, disabling OFT-level minimum-amount checks
     * @param _depositor The depositor (bytes32 format to account for non-evm addresses)
     * @param _assetAmount The number of assets to deposit
     * @param _sendParam Parameter that defines how to send the shares
     * @param _refundAddress Address to receive excess payment of the LZ fees
     * @param _msgValue The amount of native tokens sent with the transaction
     * @notice This function preserves the user's minAmountLD for OFT send while using it for vault slippage
     */
    function _depositAndSend(
        bytes32 _depositor,
        uint256 _assetAmount,
        SendParam memory _sendParam,
        address _refundAddress,
        uint256 _msgValue
    ) internal override {
        uint256 preShareBalance = IERC20(SHARE_ERC20).balanceOf(address(this));
        /// @dev Async functions may return an amount on `deposit`, but not transfer share tokens.
        _deposit(_depositor, _assetAmount);
        uint256 postShareBalance = IERC20(SHARE_ERC20).balanceOf(address(this));

        uint256 shareAmountReceived = postShareBalance - preShareBalance;
        
        // Store the original minAmountLD for OFT slippage protection
        // This represents the user's minimum expectation for the final bridged amount
        uint256 minAmountLD = _sendParam.minAmountLD;
        
        // Use minAmountLD for vault conversion slippage check
        _assertSlippage(shareAmountReceived, minAmountLD);

        _sendParam.amountLD = shareAmountReceived;
        // Preserve minAmountLD for OFT send instead of setting it to 0
        // This ensures OFT-level minimum-amount checks are enforced, preventing dust removal
        _sendParam.minAmountLD = minAmountLD;

        _send(SHARE_OFT, _sendParam, _refundAddress, _msgValue);
        emit Deposited(_depositor, _sendParam.to, _sendParam.dstEid, _assetAmount, shareAmountReceived);
    }

    /**
     * @dev Override _redeemAndSend to separate vault-conversion slippage from OFT slippage
     * @dev This fixes the audit issue where minAmountLD is set to 0, disabling OFT-level minimum-amount checks
     * @param _redeemer The address of the redeemer in bytes32 format
     * @param _shareAmount The number of shares to redeem
     * @param _sendParam Parameter that defines how to send the assets
     * @param _refundAddress Address to receive excess payment of the LZ fees
     * @param _msgValue The amount of native tokens sent with the transaction
     * @notice This function preserves the user's minAmountLD for OFT send while using it for vault slippage
     */
    function _redeemAndSend(
        bytes32 _redeemer,
        uint256 _shareAmount,
        SendParam memory _sendParam,
        address _refundAddress,
        uint256 _msgValue
    ) internal override {
        uint256 preAssetBalance = IERC20(ASSET_ERC20).balanceOf(address(this));
        /// @dev Async functions may return an amount on `redeem`, but not transfer asset tokens.
        _redeem(_redeemer, _shareAmount);
        uint256 postAssetBalance = IERC20(ASSET_ERC20).balanceOf(address(this));

        uint256 assetAmountReceived = postAssetBalance - preAssetBalance;
        
        // Store the original minAmountLD for OFT slippage protection
        // This represents the user's minimum expectation for the final bridged amount
        uint256 minAmountLD = _sendParam.minAmountLD;
        
        // Use minAmountLD for vault redemption slippage check
        _assertSlippage(assetAmountReceived, minAmountLD);

        _sendParam.amountLD = assetAmountReceived;
        // Preserve minAmountLD for OFT send instead of setting it to 0
        // This ensures OFT-level minimum-amount checks are enforced, preventing dust removal
        // from resulting in zero sends while leaving residual tokens trapped in the composer
        _sendParam.minAmountLD = minAmountLD;

        _send(ASSET_OFT, _sendParam, _refundAddress, _msgValue);
        emit Redeemed(_redeemer, _sendParam.to, _sendParam.dstEid, _shareAmount, assetAmountReceived);
    }

    /**
     * @notice Override _sendLocal to refund native tokens on successful local sends
     * @dev This fixes the audit issue where msg.value gets locked on local sends
     * @dev Refunds go to _refundAddress (user's smart account in ERC-4337)
     * @param _oft The OFT contract address
     * @param _sendParam The parameters for the send operation
     * @param _refundAddress Address to receive excess payment of the LZ fees
     * @param _msgValue The amount of native tokens sent with the transaction
     */
    function _sendLocal(
        address _oft,
        SendParam memory _sendParam,
        address _refundAddress,
        uint256 _msgValue
    ) internal override {
        // Call parent to do the ERC20 transfer
        super._sendLocal(_oft, _sendParam, _refundAddress, _msgValue);

        // Refund any native tokens that were sent
        // Note: In ERC-4337 context, _refundAddress is the user's smart account
        if (_msgValue > 0) {
            // Try refunding to _refundAddress first (user's smart account in ERC-4337)
            (bool success, ) = _refundAddress.call{ value: _msgValue }("");
            if (!success) {
                // Fallback to msg.sender (also the smart account in direct calls)
                // This handles cases where _refundAddress might be a contract without receive()
                (bool success2, ) = msg.sender.call{ value: _msgValue }("");
                if (!success2) {
                    revert NativeRefundFailed();
                }
            }
        }
    }

    /**
     * @dev Override _refund to fall back to stuckFundsRecipient when OFT refund fails
     * @notice When compose fails, the base tries to refund to source via OFT send. If that fails
     *         (e.g. recipient frozen/sanctioned, vault paused), tokens are sent to stuckFundsRecipient
     *         so funds are not left in the composer until policy changes or operator intervention.
     */
    function _refund(
        address _oft,
        bytes calldata _message,
        uint256 _amount,
        address _refundAddress,
        uint256 _msgValue
    ) internal override {
        SendParam memory refundSendParam;
        refundSendParam.dstEid = OFTComposeMsgCodec.srcEid(_message);
        refundSendParam.to = OFTComposeMsgCodec.composeFrom(_message);
        refundSendParam.amountLD = _amount;

        try IOFT(_oft).send{ value: _msgValue }(refundSendParam, MessagingFee(_msgValue, 0), _refundAddress) {
            // Refund succeeded
        } catch {
            // Refund failed (sanctions, pause, frozen recipient, etc.): send to multisig
            address token = _oft == ASSET_OFT ? ASSET_ERC20 : SHARE_ERC20;
            IERC20(token).safeTransfer(stuckFundsRecipient, _amount);
            if (_msgValue > 0) {
                (bool sent, ) = stuckFundsRecipient.call{ value: _msgValue }("");
                if (!sent) {
                    // Native left in contract; operator can rescue or next compose may use it
                }
            }
            emit StuckFundsRecovered(_oft, _amount, _msgValue, _refundAddress);
        }
    }
}
