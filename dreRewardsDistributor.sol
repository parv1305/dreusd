// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IdreRewardsDistributor} from "./interfaces/IdreRewardsDistributor.sol";
import {IdreUSDs} from "./interfaces/IdreUSDs.sol";

/**
 * @title dreRewardsDistributor
 * @dev Streams dreUSD rewards to the vault (dreUSDs) over a fixed vest period (7 days).
 *      Rewards must be transferred to this contract before calling addRewards(). addRewards() (MODERATOR_ROLE)
 *      vests new balance (current balance minus remaining rewards) linearly; first call vests full balance
 *      over VEST_PERIOD; later calls extend or reset the end timestamp. claimVested() (only the vault) transfers
 *      vested dreUSD from this contract to the immutable vault.
 */
contract dreRewardsDistributor is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IdreRewardsDistributor
{
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");

    /// @notice Vest period in seconds (e.g. 7 days). Used when (re)starting a vesting schedule.
    uint256 public constant VEST_PERIOD = 7 days;

    /// @notice The dreUSD token address
    address public immutable dreUSD;

    /// @notice The vault that holds dreUSD rewards and receives claimed rewards: dreUSDs
    address public immutable vault;

    /// @notice Last claim timestamp; vesting is linear from cTs to eTs.
    uint256 public cTs;

    /// @notice End timestamp for the current reward distribution period.
    uint256 public eTs;
    
    /// @notice Total rewards amount still vesting (decreases as vested is claimed and transferred to vault).
    uint256 public rewards;

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _dreUSD, address _vault) {
        if (_dreUSD == address(0)) revert ZeroAddress();
        if (_vault == address(0)) revert ZeroAddress();
        dreUSD = _dreUSD;
        vault = _vault;
        _disableInitializers();
    }
    
    // Public and external functions

    /**
     * @dev Initializes the distributor. Call addRewards() after transferring dreUSD to this contract.
     * @param defaultAdmin Address to grant the default admin role
     * @param upgraderAddress Address to grant the upgrader role
     * @param pauserAddress Address to grant the pauser role
     * @notice MODERATOR_ROLE is not granted during initialization as it's assigned to dreUSDManager after deployment
     */
    function initialize(address defaultAdmin, address upgraderAddress, address pauserAddress) public initializer {
        if (defaultAdmin == address(0)) revert ZeroAddress();
        if (upgraderAddress == address(0)) revert ZeroAddress();
        if (pauserAddress == address(0)) revert ZeroAddress();
        __AccessControl_init_unchained();
        __Pausable_init_unchained();

        cTs = block.timestamp;
        eTs = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, upgraderAddress);
        _grantRole(PAUSER_ROLE, pauserAddress);
    }

    /**
     * @dev Pauses claiming (only PAUSER_ROLE)
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses claiming (only PAUSER_ROLE)
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Adds new rewards. Call after transferring dreUSD to this contract.
     *      Flushes any vested amount to the vault, then treats (balance - rewards) as new rewards.
     *      If new rewards > 0: extends end timestamp by time equivalent to new rewards at current rate,
     *      or resets to now + VEST_PERIOD if the resulting period would be > VEST_PERIOD or < VEST_PERIOD - 1 day.
     */
    function addRewards() external onlyRole(MODERATOR_ROLE) whenNotPaused {
        IdreUSDs(vault).claimVestedRewards();
        // compute added rewards that are not yet vested
        uint256 newRewards = IERC20(dreUSD).balanceOf(address(this)) - rewards;
        if (newRewards > 0) {
            if (rewards == 0) {
                // first time or all was vested: vest full balance over VEST_PERIOD from now
                rewards = newRewards;
                cTs = block.timestamp;
                eTs = block.timestamp + VEST_PERIOD;
            } else {
                // based on same linear vesting distribution rate, compute how much time new rewards adds to end timestamp
                uint256 rTs = newRewards * (eTs - cTs) / rewards;
                uint256 newVestPeriod = (eTs - cTs) + rTs;
                rewards = rewards + newRewards;
                // if higher than vestingPeriod or lower we redistribute everything over 7 days with new rewards rate
                if (newVestPeriod > VEST_PERIOD || newVestPeriod < (VEST_PERIOD - 1 days)) {
                    cTs = block.timestamp;
                    eTs = block.timestamp + VEST_PERIOD;
                } else {
                    eTs = eTs + rTs;
                }
            }
        } else {
            // No new rewards: if current vest window is outside [VEST_PERIOD - 1 day, VEST_PERIOD], re-vest remainder over 7 days (same bounds as add-rewards reset)
            uint256 currentVestPeriod = eTs - cTs;
            if (rewards > 0 && (currentVestPeriod < (VEST_PERIOD - 1 days))) {
                cTs = block.timestamp;
                eTs = block.timestamp + VEST_PERIOD;
            }
        }
        emit RewardsScheduleUpdated(newRewards, rewards, cTs, eTs);
    }

    /**
     * @dev Transfers vested dreUSD from this contract to the immutable vault. Callable only by the vault so that
     *      the vault can update its _virtualBalance in the same flow (deposit/withdraw); reverts if called by others.
     * @return claimed Amount of dreUSD transferred to the vault
     */
    function claimVested() external whenNotPaused returns (uint256 claimed) {
        if (msg.sender != vault) revert IdreRewardsDistributor.CallerNotVault();
        return _claimVested();
    }

    /**
     * @dev Returns the amount of rewards that have vested and are claimable (linear vest from cTs to eTs, capped by rewards).
     */
    function vestedAmount() external view returns (uint256 vested) {
        (vested,) = _computeVestedAmount();
    }

    // Internal functions


    /// @dev Computes vested amount, transfers it to vault, decrements rewards and updates cTs.
    function _claimVested() internal returns (uint256 vested) {
        uint256 newClaimTimestamp;
        (vested, newClaimTimestamp) = _computeVestedAmount();
        if (vested > 0) {
            IERC20(dreUSD).safeTransfer(vault, vested);
            rewards = rewards - vested;
            cTs = newClaimTimestamp;
            emit RewardsClaimed(vested);
        }
    }

    /// @dev Linear vest: (now - cTs) / (eTs - cTs) * rewards. Returns 0 if now >= eTs.
    function _computeVestedAmount() internal view returns (uint256 vested, uint256 newClaimTimestamp) {
        newClaimTimestamp = block.timestamp > eTs ? eTs : block.timestamp;
        if (newClaimTimestamp - cTs == 0) return (0, newClaimTimestamp);
        uint256 timePassed = newClaimTimestamp - cTs;
        vested = timePassed * rewards / (eTs - cTs);
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
