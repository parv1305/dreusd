// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";
import {IAaveV3Adapter} from "./interfaces/IAaveV3Adapter.sol";

/**
 * @title dreAaveAdapter
 * @notice Adapter that withdraws USDC from Aave V3 for filling long queue positions
 * @dev The aTokens are held by a vault (multisig) which gives allowance to this adapter.
 *      This adapter pulls aTokens from the vault and redeems them for USDC.
 * 
 * Deployment requirements:
 * 1. Set the vault address (multisig holding aUSDC)
 * 2. Vault must approve this adapter to spend aUSDC
 * 3. Set dreUSDManager in initialize (or via setDreUSDManager); only that contract may call withdraw()
 */
contract dreAaveAdapter is 
    IAaveV3Adapter,
    AccessControlUpgradeable, 
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ============ Roles ============

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============ State Variables ============

    /// @notice Aave V3 Pool contract
    address public aavePool;

    /// @notice USDC token address
    address public usdc;

    /// @notice aUSDC token address (Aave interest-bearing USDC)
    address public aUsdc;

    /// @notice Vault address (multisig) that holds aTokens and gives allowance to this adapter
    address public vault;

    /// @notice dreUSDManager contract; only this address may call withdraw()
    address public dreUSDManager;

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    // ============ Events ============

    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event DreUSDManagerUpdated(address indexed oldManager, address indexed newManager);
    event TokenRecovered(address indexed token, address indexed recipient, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the adapter contract
     * @param _aavePool Aave V3 Pool address
     * @param _usdc USDC token address
     * @param _vault Vault address (multisig) holding aTokens
     * @param admin Default admin address
     * @param upgrader Upgrader address to grant UPGRADER_ROLE
     * @param manager dreUSDManager address to set
     */
    function initialize(
        address _aavePool,
        address _usdc,
        address _vault,
        address admin,
        address upgrader,
        address manager
    ) external initializer {
        if (_aavePool == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_vault == address(0)) revert ZeroAddress();
        if (admin == address(0)) revert ZeroAddress();
        if (upgrader == address(0)) revert ZeroAddress();
        if (manager == address(0)) revert ZeroAddress();

        __AccessControl_init_unchained();

        aavePool = _aavePool;
        usdc = _usdc;
        vault = _vault;

        // Get aToken address from Aave Pool
        IAaveV3Pool.ReserveData memory reserveData = IAaveV3Pool(_aavePool).getReserveData(_usdc);
        if (reserveData.aTokenAddress == address(0)) revert InvalidATokenAddress();
        if (reserveData.aTokenAddress.code.length == 0) revert InvalidATokenAddress();
        aUsdc = reserveData.aTokenAddress;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(UPGRADER_ROLE, upgrader);
        dreUSDManager = manager;
    }

    // ============ External Functions ============

    /// @inheritdoc IAaveV3Adapter
    function withdraw(
        uint256 amount, 
        address to
    ) external returns (uint256 withdrawn) {
        if (msg.sender != dreUSDManager) revert InvalidCaller();
        if (amount == 0) revert ZeroAmount();
        if (amount == type(uint256).max) revert MaxSentinelNotSupported();
        if (to == address(0)) revert ZeroAddress();

        // Check vault has enough aUSDC and has given us allowance
        uint256 available = getAvailableBalance();
        if (available < amount) revert InsufficientBalance(available, amount);

        uint256 balanceBefore = IERC20(aUsdc).balanceOf(address(this));
        IERC20(aUsdc).safeTransferFrom(vault, address(this), amount);
        uint256 delta = IERC20(aUsdc).balanceOf(address(this)) - balanceBefore;
        if (delta < amount) revert WithdrawalFailed();

        // Withdraw exact transfer delta so residual/donated aUSDC on adapter cannot affect user fills
        withdrawn = IAaveV3Pool(aavePool).withdraw(usdc, delta, to);

        if (withdrawn < amount) revert WithdrawalFailed();

        emit Withdrawn(to, withdrawn);
    }

    /// @inheritdoc IAaveV3Adapter
    function getAvailableBalance() public view returns (uint256) {
        // Check vault's aToken balance and allowance to this adapter
        uint256 vaultBalance = IERC20(aUsdc).balanceOf(vault);
        uint256 allowance = IERC20(aUsdc).allowance(vault, address(this));
        uint256 available = vaultBalance < allowance ? vaultBalance : allowance;
        
        // Also check Aave pool liquidity
        uint256 availableLiquidity = IERC20(usdc).balanceOf(aUsdc);
        
        return available < availableLiquidity ? available : availableLiquidity;
    }

    /// @inheritdoc IAaveV3Adapter
    function getAavePool() external view returns (address) {
        return aavePool;
    }

    /// @inheritdoc IAaveV3Adapter
    function getAToken() external view returns (address) {
        return aUsdc;
    }

    /// @inheritdoc IAaveV3Adapter
    function getUsdc() external view returns (address) {
        return usdc;
    }

    /**
     * @notice Get the vault address that holds aTokens
     * @return Address of the vault (multisig)
     */
    function getVault() external view returns (address) {
        return vault;
    }

    /**
     * @notice Set the dreUSDManager address (only this contract may call withdraw())
     * @param _dreUSDManager dreUSDManager contract address
     */
    function setDreUSDManager(address _dreUSDManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_dreUSDManager == address(0)) revert ZeroAddress();
        address oldManager = dreUSDManager;
        dreUSDManager = _dreUSDManager;
        emit DreUSDManagerUpdated(oldManager, _dreUSDManager);
    }

    // ============ Admin Functions ============

    /**
     * @notice Update the vault address
     * @param _vault New vault address
     * @dev Validates that the new vault has approved this adapter to spend aUSDC
     *      to prevent operational failures where withdraw() calls would revert
     */
    function setVault(address _vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_vault == address(0)) revert ZeroAddress();
        
        // Defensive check: verify the new vault has approved this adapter to spend aUSDC
        // This prevents operational failures where subsequent withdraw() calls would revert
        uint256 allowance = IERC20(aUsdc).allowance(_vault, address(this));
        if (allowance == 0) {
            revert InsufficientAllowance(_vault, allowance);
        }
        
        address oldVault = vault;
        vault = _vault;
        emit VaultUpdated(oldVault, _vault);
    }

    /**
     * @notice Recover any ERC20 tokens accidentally sent to this contract
     * @dev Use to sweep residual aUSDC (e.g. to vault) or USDC (e.g. to treasury) so they do not affect user fills
     * @param token Token address to recover
     * @param recipient Address to receive the tokens
     */
    function recoverToken(address token, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).safeTransfer(recipient, balance);
            emit TokenRecovered(token, recipient, balance);
        }
    }

    // ============ Internal Functions ============

    /**
     * @dev Authorizes contract upgrades
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
