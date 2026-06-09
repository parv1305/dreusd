// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IdreUSDs} from "./interfaces/IdreUSDs.sol";
import {IdreRewardsDistributor} from "./interfaces/IdreRewardsDistributor.sol";
import {IdreUSD} from "./interfaces/IdreUSD.sol";

/**
 * @title dreUSDs
 * @dev ERC4626 vault for dreUSD tokens, upgradeable via UUPS proxy
 *      Rewards are managed by dreRewardsDistributor which handles vesting
 */
contract dreUSDs is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IdreUSDs
{
    using SafeERC20 for IERC20;
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice The dreRewardsDistributor that holds and vests rewards
    address public rewardsDistributor;

    /// @notice Share OFT adapter on hub; transfers from this address skip sanctions/freeze checks so bridge delivery does not trap messages.
    address public shareOFTAdapter;

    /// @notice Virtual balance used in totalAssets (inflation-attack mitigation).
    ///         Increases on deposit (+ claimed vested) and decreases on withdraw; ignores direct transfers to vault.
    uint256 private _virtualBalance;

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // public and external functions

    /**
     * @dev Initializes the vault
     * @param asset_ The dreUSD token address
     * @param defaultAdmin Address to grant the default admin role
     */
    function initialize(IERC20 asset_, address defaultAdmin) public initializer {
        if (defaultAdmin == address(0)) revert ZeroAddress();
        if (address(asset_) == address(0)) revert ZeroAddress();
        
        __ERC4626_init_unchained(asset_);
        __ERC20_init_unchained("dreUSDs", "dreUSDs");
        __AccessControl_init_unchained();
        __Pausable_init_unchained();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, defaultAdmin);
    }

    /**
     * @dev Sets the rewards distributor address. Claims any remaining vested rewards from the current
     *      distributor and adds them to _virtualBalance before switching, so totalAssets does not drop
     *      and share pricing stays correct. The previous distributor must not be paused if those rewards
     *      should be pulled; otherwise they remain in the old contract until separately settled.
     * @param _rewardsDistributor New rewards distributor address
     */
    function setRewardsDistributor(address _rewardsDistributor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_rewardsDistributor == address(0)) revert ZeroAddress();
        if (_rewardsDistributor == rewardsDistributor) revert SameRewardsDistributor();

        address oldDistributor = rewardsDistributor;
        if (oldDistributor != address(0)) {
            uint256 claimed = IdreRewardsDistributor(oldDistributor).claimVested();
            _virtualBalance += claimed;
        }
        rewardsDistributor = _rewardsDistributor;
        emit RewardsDistributorUpdated(oldDistributor, _rewardsDistributor);
    }

    /**
     * @dev Sets the share OFT adapter address (hub only). Transfers from this address skip sanctions/freeze checks so bridge delivery to any receiver does not trap LayerZero messages; the adapter may route to stuckFundsRecipient on failure.
     * @param _shareOFTAdapter Adapter address (or zero to clear)
     */
    function setShareOFTAdapter(address _shareOFTAdapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_shareOFTAdapter == address(0)) revert ZeroAddress();
        if (_shareOFTAdapter == shareOFTAdapter) revert SameShareOFTAdapter();
        
        address oldAdapter = shareOFTAdapter;
        shareOFTAdapter = _shareOFTAdapter;
        emit ShareOFTAdapterUpdated(oldAdapter, _shareOFTAdapter);
    }

    /**
     * @dev Returns the total assets managed by the vault (virtual balance + unclaimed vested rewards).
     *      Virtual balance increases on deposit (and when claiming vested) and decreases on withdraw,
     *      so direct transfers to the vault do not inflate the share price.
     */
    function totalAssets() public view override returns (uint256) {
        uint256 vested = rewardsDistributor != address(0)
            ? IdreRewardsDistributor(rewardsDistributor).vestedAmount()
            : 0;
        return _virtualBalance + vested;
    }

    /**
     * @dev Returns the number of decimals (matches dreUSD)
     */
    function decimals() public view override returns (uint8) {
        return super.decimals();
    }

    /**
     * @dev Returns 0 when paused or when receiver is sanctioned/frozen (ERC-4626: "if deposits are entirely disabled it MUST return 0").
     */
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        if (_isBlockedAddress(receiver)) return 0;
        return super.maxDeposit(receiver);
    }

    /**
     * @dev Returns 0 when paused or when receiver is sanctioned/frozen.
     */
    function maxMint(address receiver) public view override returns (uint256) {
        if (paused()) return 0;
        if (_isBlockedAddress(receiver)) return 0;
        return super.maxMint(receiver);
    }

    /**
     * @dev Returns 0 when paused or when owner is sanctioned/frozen.
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        if (_isBlockedAddress(owner)) return 0;
        return super.maxWithdraw(owner);
    }

    /**
     * @dev Returns 0 when paused or when owner is sanctioned/frozen.
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        if (paused()) return 0;
        if (_isBlockedAddress(owner)) return 0;
        return super.maxRedeem(owner);
    }

    /// @inheritdoc IdreUSDs
    function claimVestedRewards() external whenNotPaused returns (uint256 claimed) {
        claimed = _claimVestedRewards();
        _virtualBalance += claimed;
        return claimed;
    }

    /// @inheritdoc IdreUSDs
    function excessDreUSD() public view override returns (uint256) {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance <= _virtualBalance) return 0;
        return balance - _virtualBalance;
    }

    /// @inheritdoc IdreUSDs
    function withdrawExcessDreUSD(address to) external onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = excessDreUSD();
        if (amount == 0) revert ZeroExcess();
        IERC20(asset()).safeTransfer(to, amount);
        emit ExcessDreUSDWithdrawn(to, amount);
        return amount;
    }

    /**
     * @dev Pauses deposit and withdraw (only PAUSER_ROLE)
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses deposit and withdraw (only PAUSER_ROLE)
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // internal functions

    /**
     * @dev Claims vested rewards from distributor (best-effort). Called during deposit/withdraw so users pay the gas.
     *      Skips claim when distributor is paused
     * @return claimed Amount transferred to the vault (0 if distributor not set or when distributor is paused)
     */
    function _claimVestedRewards() internal returns (uint256 claimed) {
        if (rewardsDistributor == address(0)) return 0;
        if (PausableUpgradeable(rewardsDistributor).paused()) return 0;
        return IdreRewardsDistributor(rewardsDistributor).claimVested();
    }

    /**
     * @dev Hook called during deposit - claims vested rewards first, updates virtual balance; reverts when paused.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override whenNotPaused {
        _virtualBalance += _claimVestedRewards();
        _virtualBalance += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Hook called during withdrawal - claims vested rewards first, updates virtual balance; reverts when paused.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        _virtualBalance += _claimVestedRewards();
        _virtualBalance -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /**
     * @dev Validates an address against the underlying dreUSD sanctions/freeze rules.
     *      Reverts if the address is frozen or sanctioned in the dreUSD contract.
     * @param addr Address to validate
     */
    function _validateAddress(address addr) internal view {
        address dreUSDAsset = address(asset());

        // Delegate to dreUSD's centralized validation logic. Any failure
        // will bubble up as FrozenAddress or SanctionedAddress from dreUSD.
        IdreUSD(dreUSDAsset).validateAddress(addr);
    }

    /**
     * @dev Returns true if the address would fail validation (sanctioned or frozen). Delegates to dreUSD.isBlockedAddress.
     */
    function _isBlockedAddress(address addr) internal view returns (bool) {
        if (addr == address(0)) return false;
        return IdreUSD(address(asset())).isBlockedAddress(addr);
    }

    /**
     * @dev ERC20 hook called before any share transfer, mint, or burn.
     *      Enforces that both source and destination addresses comply with
     *      the underlying dreUSD sanctions and freeze rules, unless the transfer
     *      is from the share OFT adapter (bridge-in on hub), so the message is not trapped.
     *      Reverts when paused to prevent share transfers during emergencies.
     */
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        if (from != shareOFTAdapter) {
            if (from != address(0)) {
                _validateAddress(from);
            }
            if (to != address(0)) {
                _validateAddress(to);
            }
        }

        super._update(from, to, value);
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
