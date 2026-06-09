// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {IdreVault} from "./interfaces/IdreVault.sol";

/**
 * @title dreVault
 * @notice Holds USDC received from dreUSDManager and forwards the full balance downstream on Chainlink Automation upkeep.
 * @dev Deploy twice for a two-hop pipeline:
 *      1. Manager → dreVault (hop 1) → dreVault (hop 2) → Utila corporate wallet
 *      2. Register hop 1 and hop 2 as separate Chainlink Automation upkeeps.
 *      dreUSDManager must send mint proceeds to this contract (e.g. set `custodianVault` to hop 1).
 *      Owner (dre governance multisig) may recover mistaken ERC20 (except `token`) and ETH.
 */
contract dreVault is IdreVault, Ownable {
    using SafeERC20 for IERC20;

    /// @inheritdoc IdreVault
    address public immutable token;

    /// @inheritdoc IdreVault
    address public immutable forwardVault;

    /// @notice Accepts ETH sent by mistake so the owner can recover it
    receive() external payable {}

    /**
     * @param _token ERC20 token address (e.g. USDC); only forwarded via `performUpkeep`, not recoverable
     * @param _forwardVault Downstream vault or corporate wallet
     * @param _owner dre governance multisig
     */
    constructor(address _token, address _forwardVault, address _owner) Ownable(_owner) {
        if (_token == address(0)) revert ZeroAddress();
        if (_forwardVault == address(0)) revert ZeroAddress();
        token = _token;
        forwardVault = _forwardVault;
    }

    /// @inheritdoc IdreVault
    function checkUpkeep(
        bytes calldata /* checkData */
    ) external view returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = IERC20(token).balanceOf(address(this)) > 0;
        performData = "";
    }

    /// @inheritdoc IdreVault
    function performUpkeep(bytes calldata /* performData */) external {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToForward();
        IERC20(token).safeTransfer(forwardVault, amount);
        emit UsdcForwarded(forwardVault, amount);
    }

    /// @inheritdoc IdreVault
    function recoverToken(address token_, address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        if (token_ == token) revert ConfiguredTokenNotRecoverable();

        uint256 balance = IERC20(token_).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token_).safeTransfer(recipient, balance);
            emit TokenRecovered(token_, recipient, balance);
        }
    }

    /// @inheritdoc IdreVault
    function recoverEther(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();

        uint256 balance = address(this).balance;
        if (balance > 0) {
            Address.sendValue(payable(recipient), balance);
            emit EtherRecovered(recipient, balance);
        }
    }
}
