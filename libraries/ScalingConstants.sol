// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ScalingConstants
 * @dev Shared constants and helpers for basis points and decimal scaling.
 */
library ScalingConstants {
    /// @notice Basis points denominator (100 bps = 1%). Use for bps math: (amount * bps) / BPS_DENOMINATOR.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Default express withdrawal limit: 10M USDC (6 decimals).
    uint256 public constant EXPRESS_WITHDRAWAL_DEFAULT_LIMIT_6DEC = 10_000_000e6;

    /// @return 10 ** decimals (e.g. scaleBase(6) => 1e6).
    function scaleBase(uint8 decimals) external pure returns (uint256) {
        return 10 ** decimals;
    }
}
