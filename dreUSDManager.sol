// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IdreUSDManager} from "./interfaces/IdreUSDManager.sol";
import {IdreUSD} from "./interfaces/IdreUSD.sol";
import {IDreUSDOracle} from "./interfaces/IDreUSDOracle.sol";
import {IWithdrawalNFT} from "./interfaces/IWithdrawalNFT.sol";
import {IAaveV3Adapter} from "./interfaces/IAaveV3Adapter.sol";
import {IdreRewardsDistributor} from "./interfaces/IdreRewardsDistributor.sol";
import {IdreUSDs} from "./interfaces/IdreUSDs.sol";
import {ScalingConstants} from "./libraries/ScalingConstants.sol";

/**
 * @title dreUSDManager
 * @dev Manager contract for dreUSD ecosystem, upgradeable via UUPS proxy
 *      Handles minting dreUSD 1:1 with allowed stablecoins (USDC, USDT)
 *      Two withdrawal queues:
 *      - Express: 6h fill target, 50 bps fee, global $10M limit
 *      - Long Queue: 7 days, 0% fee, no limit
 */
contract dreUSDManager is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    UUPSUpgradeable,
    IdreUSDManager
{
    using SafeERC20 for IERC20;

    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant EXPRESS_OPERATOR_ROLE = keccak256("EXPRESS_OPERATOR_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");
    bytes32 public constant WITHDRAWAL_CONFIG_ROLE = keccak256("WITHDRAWAL_CONFIG_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice dreUSD token address (immutable)
    address public immutable dreUSD;

    /// @notice dreUSDs staking vault address (immutable)
    address public immutable dreUSDs;

    /// @notice USDC token address for withdrawals (immutable)
    address public immutable usdc;

    /// @notice Price oracle for stablecoin validation (immutable)
    address public immutable oracle;

    /// @notice Custodian vault: receives stablecoin from mint flows (e.g. multisig)
    address public custodianVault;

    /// @notice Custodian addresses for fiat mint signature verification
    mapping(address => bool) public custodians;

    /// @notice Mapping of used mint references (prevents replay)
    mapping(bytes32 => bool) public usedMintRefs;

    /// @notice Maximum allowed daily fiat mint cap in USD (2 decimals, e.g., 100_000_000_00 for 100M USD)
    uint256 public constant MAX_DAILY_FIAT_MINT_CAP_USD = 100_000_000_00; // 100 million USD

    /// @notice Daily fiat mint cap in USD (2 decimals, e.g., 10_000_000_00 for 10M USD).
    ///         Not set in initialize and defaults to 0 as a safety measure: mintFromUsd and mintRewards
    ///         are not callable until MODERATOR_ROLE calls setDailyFiatMintCap(_cap).
    uint256 public dailyFiatMintCapUsd;

    /// @notice Amount minted via fiat per day (day number => amount in USD, 2 decimals)
    mapping(uint256 => uint256) public dailyFiatMinted;

    /// @notice Mapping of allowed stablecoins
    mapping(address => bool) public allowed;

    // ============ Express Withdrawal (6h fill, 50 bps fee) ============

    /// @notice Maximum express withdrawal fee in basis points (500 = 5%)
    uint256 public constant MAX_EXPRESS_WITHDRAWAL_FEE_BPS = 500;

    /// @notice Express withdrawal NFT contract (immutable)
    address public immutable expressWithdrawalNFT;

    /// @notice Global maximum limit for express withdrawals (in USDC, default 10M)
    uint256 public expressWithdrawalMaxLimit;

    /// @notice Currently available express withdrawal amount (decreases on request, increases on payback)
    uint256 public expressWithdrawalAvailable;

    /// @notice Express withdrawal fee in basis points (default 50 = 0.5%)
    uint256 public expressWithdrawalFeeBps;

    /// @notice Address where express filler receives payback
    address public expressPaybackAddress;

    /// @notice Total amount owed to express filler (unfilled + filled but not paid back)
    uint256 public expressFillerDebt;

    /// @notice Address that receives express withdrawal fees (vault/multisig)
    address public expressFeeRecipient;

    /// @notice USDC fee amount for each express withdrawal NFT (tokenId => fee in USDC)
    mapping(uint256 => uint256) public expressWithdrawalFees;

    // ============ Withdrawal (standard queue, 7 days, 0% fee) ============

    /// @notice Withdrawal NFT contract (immutable)
    address public immutable withdrawalNFT;

    /// @notice Minimum waiting time before withdrawal positions can be filled (default 7 days)
    uint256 public withdrawalWaitingTime;

    /// @notice Vault adapter for filling withdrawals (e.g., Aave V3)
    address public withdrawalVaultAdapter;

    // ============ EIP-712 MintFrom ============

    /// @notice Nonce per account for EIP-712 MintFrom (replay protection)
    mapping(address => uint256) public authNonce;

    /// @notice EIP-712 typehash for MintFrom (auth) struct
    bytes32 public constant AUTH_MINTFROM_TYPEHASH = keccak256(
        "MintFrom(address from,address receiver,address asset,uint256 amountIn,uint256 minAmountOut,uint256 deadline,uint256 nonce)"
    );
    bytes32 private constant AUTH_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant AUTH_DOMAIN_NAME_HASH = keccak256("dreUSDManager");
    bytes32 private constant AUTH_DOMAIN_VERSION_HASH = keccak256("1");

    /// @notice Struct for role addresses used in initialization
    struct RoleAddresses {
        address defaultAdmin;
        address upgrader;
        address moderator;
        address withdrawalConfig;
        address pauser;
        address keeper;
        address expressOperator;
        address treasury;
    }

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _dreUSD,
        address _dreUSDs,
        address _usdc,
        address _oracle,
        address _expressWithdrawalNFT,
        address _withdrawalNFT
    ) {
        if (_dreUSD == address(0)) revert ZeroAddress();
        if (_dreUSDs == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_oracle == address(0)) revert ZeroAddress();
        if (_expressWithdrawalNFT == address(0)) revert ZeroAddress();
        if (_withdrawalNFT == address(0)) revert ZeroAddress();

        dreUSD = _dreUSD;
        dreUSDs = _dreUSDs;
        usdc = _usdc;
        oracle = _oracle;
        expressWithdrawalNFT = _expressWithdrawalNFT;
        withdrawalNFT = _withdrawalNFT;

        _disableInitializers();
    }

    // public and external functions

    /**
     * @dev Initializes the contract.
     *      Note: dailyFiatMintCapUsd is intentionally not set here (defaults to 0). mintFromUsd and
     *      mintRewards remain uncallable until MODERATOR_ROLE calls setDailyFiatMintCap(_cap).
     *      Rewards distributor is read from dreUSDs vault (single source of truth).
     * @param _expressPaybackAddress Express payback address
     * @param _expressFeeRecipient Address that receives express withdrawal fees
     * @param roles Struct containing all role addresses including defaultAdmin
     */
    function initialize(
        address _expressPaybackAddress,
        address _expressFeeRecipient,
        RoleAddresses memory roles
    ) public initializer {
        // Validate all addresses are non-zero
        if (roles.defaultAdmin == address(0)) revert ZeroAddress();
        if (_expressPaybackAddress == address(0)) revert ZeroAddress();
        if (_expressFeeRecipient == address(0)) revert ZeroAddress();
        if (roles.upgrader == address(0)) revert ZeroAddress();
        if (roles.moderator == address(0)) revert ZeroAddress();
        if (roles.withdrawalConfig == address(0)) revert ZeroAddress();
        if (roles.pauser == address(0)) revert ZeroAddress();
        if (roles.keeper == address(0)) revert ZeroAddress();
        if (roles.expressOperator == address(0)) revert ZeroAddress();
        if (roles.treasury == address(0)) revert ZeroAddress();
        
        __AccessControl_init_unchained();
        __Pausable_init_unchained();

        expressPaybackAddress = _expressPaybackAddress;
        expressFeeRecipient = _expressFeeRecipient;
        
        // Express withdrawal defaults (6h fill, 50 bps fee)
        expressWithdrawalMaxLimit = ScalingConstants.EXPRESS_WITHDRAWAL_DEFAULT_LIMIT_6DEC;
        expressWithdrawalAvailable = ScalingConstants.EXPRESS_WITHDRAWAL_DEFAULT_LIMIT_6DEC;
        expressWithdrawalFeeBps = 50; // 0.5% fee

        // Withdrawal defaults (7 days, 0% fee)
        withdrawalWaitingTime = 7 days;

        // Grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, roles.defaultAdmin);
        _grantRole(UPGRADER_ROLE, roles.upgrader);
        _grantRole(MODERATOR_ROLE, roles.moderator);
        _grantRole(WITHDRAWAL_CONFIG_ROLE, roles.withdrawalConfig);
        _grantRole(PAUSER_ROLE, roles.pauser);
        _grantRole(KEEPER_ROLE, roles.keeper);
        _grantRole(EXPRESS_OPERATOR_ROLE, roles.expressOperator);
        _grantRole(TREASURY_ROLE, roles.treasury);
    }

    /// @inheritdoc IdreUSDManager
    function updateVault(address _custodianVault) external onlyRole(MODERATOR_ROLE) {
        if (_custodianVault == address(0)) revert ZeroAddress();
        if (_custodianVault == custodianVault) revert SameVault();
        address oldCustodianVault = custodianVault;
        custodianVault = _custodianVault;
        emit VaultUpdated(oldCustodianVault, _custodianVault);
    }

    /// @inheritdoc IdreUSDManager
    function updateCustodianList(address _custodian, bool isAllowed) external onlyRole(MODERATOR_ROLE) {
        if (_custodian == address(0)) revert ZeroAddress();
        if (isAllowed) {
            if (custodians[_custodian]) revert CustodianAlreadyAdded(_custodian);
            custodians[_custodian] = true;
            emit CustodianAdded(_custodian);
        } else {
            if (!custodians[_custodian]) revert CustodianNotAllowed(_custodian);
            custodians[_custodian] = false;
            emit CustodianRemoved(_custodian);
        }
    }

    /// @inheritdoc IdreUSDManager
    /// @dev Must be called (at least once) before mintFromUsd or mintRewards can succeed; cap defaults to 0 in initialize.
    function setDailyFiatMintCap(uint256 _cap) external onlyRole(MODERATOR_ROLE) {
        if (_cap > MAX_DAILY_FIAT_MINT_CAP_USD) revert DailyFiatMintCapTooHigh(_cap, MAX_DAILY_FIAT_MINT_CAP_USD);
        if (_cap == dailyFiatMintCapUsd) revert SameDailyFiatMintCap();
        uint256 oldCap = dailyFiatMintCapUsd;
        dailyFiatMintCapUsd = _cap;
        emit DailyFiatMintCapUpdated(oldCap, _cap);
    }

    /// @notice Returns the rewards distributor from the dreUSDs vault (single source of truth).
    function dreRewardsDistributor() public view returns (address) {
        return IdreUSDs(dreUSDs).rewardsDistributor();
    }

    /// @inheritdoc IdreUSDManager
    function updateExpressPaybackAddress(address newAddress) external onlyRole(WITHDRAWAL_CONFIG_ROLE) {
        if (newAddress == address(0)) revert ZeroAddress();
        if (newAddress == expressPaybackAddress) revert SameExpressPaybackAddress();
        address oldAddress = expressPaybackAddress;
        expressPaybackAddress = newAddress;
        emit ExpressPaybackAddressUpdated(oldAddress, newAddress);
    }

    /// @inheritdoc IdreUSDManager
    function updateExpressWithdrawal(
        uint256 maxLimit,
        uint256 feeBps,
        address feeRecipient
    ) external onlyRole(WITHDRAWAL_CONFIG_ROLE) {
        if (maxLimit == 0) revert ZeroAmount();
        if (feeBps > MAX_EXPRESS_WITHDRAWAL_FEE_BPS) revert InvalidLimit(); // Max 5%
        if (feeRecipient == address(0)) revert ZeroAddress();
        if (
            maxLimit == expressWithdrawalMaxLimit
                && feeBps == expressWithdrawalFeeBps
                && feeRecipient == expressFeeRecipient
        ) revert SameExpressWithdrawalConfig();
        uint256 oldLimit = expressWithdrawalMaxLimit;
        uint256 oldAvailable = expressWithdrawalAvailable;
        uint256 outstanding = oldLimit > oldAvailable ? oldLimit - oldAvailable : 0;
        if (maxLimit < outstanding) revert ExpressLimitBelowOutstanding(maxLimit, outstanding);
        expressWithdrawalMaxLimit = maxLimit;
        expressWithdrawalAvailable = maxLimit - outstanding;
        emit ExpressLimitUpdated(oldLimit, maxLimit);
        emit ExpressAvailableUpdated(oldAvailable, expressWithdrawalAvailable);
        uint256 oldFee = expressWithdrawalFeeBps;
        expressWithdrawalFeeBps = feeBps;
        emit ExpressFeeUpdated(oldFee, feeBps);
        address oldRecipient = expressFeeRecipient;
        expressFeeRecipient = feeRecipient;
        emit ExpressFeeRecipientUpdated(oldRecipient, feeRecipient);
    }

    /// @inheritdoc IdreUSDManager
    function updateWithdrawal(uint256 waitingTime) external onlyRole(WITHDRAWAL_CONFIG_ROLE) {
        uint256 minWaitingTime = 1 days;
        uint256 maxWaitingTime = 14 days;
        if (waitingTime < minWaitingTime || waitingTime > maxWaitingTime) {
            revert InvalidWithdrawalWaitingTime(waitingTime, minWaitingTime, maxWaitingTime);
        }
        if (waitingTime == withdrawalWaitingTime) revert SameWithdrawalWaitingTime();
        uint256 oldWaitingTime = withdrawalWaitingTime;
        withdrawalWaitingTime = waitingTime;
        emit WithdrawalWaitingTimeUpdated(oldWaitingTime, waitingTime);
    }

    /// @inheritdoc IdreUSDManager
    /// @dev Validates adapter reports the same USDC as this manager to avoid asset/unit mismatch in fill payouts.
    function updateVaultAdapter(address adapter) external onlyRole(WITHDRAWAL_CONFIG_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        if (adapter == withdrawalVaultAdapter) revert SameVaultAdapter();
        if (IAaveV3Adapter(adapter).getUsdc() != usdc) revert IncompatibleVaultAdapter(adapter, usdc);
        address oldAdapter = withdrawalVaultAdapter;
        withdrawalVaultAdapter = adapter;
        emit VaultAdapterUpdated(oldAdapter, adapter);
    }

    /// @inheritdoc IdreUSDManager
    function updateAllowedList(address token, bool allowed_) external onlyRole(MODERATOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (allowed_) {
            if (allowed[token]) revert StablecoinAlreadyAllowed(token);
            allowed[token] = true;
            emit StablecoinAdded(token);
        } else {
            if (!allowed[token]) revert StablecoinNotAllowed(token);
            allowed[token] = false;
            emit StablecoinRemoved(token);
        }
    }

    /// @inheritdoc IdreUSDManager
    function mint(
        address asset,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata permitSig
    ) external nonReentrant whenNotPaused {
        _preMintChecks(asset, amountIn, deadline);

        _validateAddress(msg.sender);

        // Execute permit to get allowance
        _executePermit(msg.sender, asset, amountIn, permitSig);

        // Transfer stablecoin, mint dreUSD, and check slippage
        uint256 dreUSDAmount = _transferAndMint(asset, msg.sender, amountIn, minAmountOut, msg.sender);

        emit Minted(msg.sender, asset, amountIn, dreUSDAmount);
    }

    /// @inheritdoc IdreUSDManager
    function mintFrom(
        address from,
        address asset,
        uint256 amountIn,
        address receiver,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata permitSig,
        bytes calldata authorizeSig
    ) external nonReentrant whenNotPaused {
        _preMintChecks(asset, amountIn, deadline);
        
        // Entrypoint-specific validations
        if (from == address(0)) revert ZeroAddress();
        if (receiver == address(0)) revert ZeroAddress();

        _validateAddress(from);
        _validateAddress(receiver);

        // Verify EIP-712 signature binds all params; signer must be from (replay + front-run protection)
        _authorize(from, receiver, asset, amountIn, minAmountOut, deadline, authorizeSig);
        authNonce[from]++;

        // Execute permit to get allowance from 'from' address
        _executePermit(from, asset, amountIn, permitSig);

        // Transfer stablecoin, mint dreUSD, and check slippage
        uint256 dreUSDAmount = _transferAndMint(asset, from, amountIn, minAmountOut, receiver);

        emit MintedFrom(from, receiver, asset, amountIn, dreUSDAmount);
    }

    /// @inheritdoc IdreUSDManager
    function mint(
        address asset,
        uint256 amount,
        uint256 minAmountOut,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        _preMintChecks(asset, amount, deadline);

        _validateAddress(msg.sender);

        // Transfer stablecoin, mint dreUSD, and check slippage
        uint256 dreUSDAmount = _transferAndMint(asset, msg.sender, amount, minAmountOut, msg.sender);

        emit Minted(msg.sender, asset, amount, dreUSDAmount);
    }

    /// @inheritdoc IdreUSDManager
    function mintAndStake(
        address asset,
        uint256 amountIn,
        address receiver,
        uint256 minAmountOut,
        uint256 minSharesOut,
        uint256 deadline,
        bytes calldata permitSig
    ) external nonReentrant whenNotPaused {
        if (receiver == address(0)) revert ZeroAddress();

        _preMintChecks(asset, amountIn, deadline);
        _validateAddress(msg.sender);
        _validateAddress(receiver);

        // Execute permit to get allowance
        _executePermit(msg.sender, asset, amountIn, permitSig);

        // Transfer stablecoin, mint dreUSD to this contract, and check slippage
        uint256 dreUSDAmount = _transferAndMint(asset, msg.sender, amountIn, minAmountOut, address(this));

        // Approve dreUSDs vault to spend dreUSD
        IERC20(dreUSD).approve(dreUSDs, dreUSDAmount);

        // Deposit dreUSD into vault for receiver; enforce minimum shares (totalAssets() can move between quote and execution)
        uint256 sharesOut = IERC4626(dreUSDs).deposit(dreUSDAmount, receiver);
        if (sharesOut < minSharesOut) revert SlippageExceeded(minSharesOut, sharesOut);

        emit MintAndStake(receiver, asset, amountIn, sharesOut, dreUSDAmount);
    }
    

    /// @inheritdoc IdreUSDManager
    function mintFromUsd(FiatMint calldata m, bytes calldata custodianSig) external onlyRole(KEEPER_ROLE) whenNotPaused {
        if (m.receiver == dreRewardsDistributor()) revert InvalidReceiver(m.receiver);
        uint256 dreUSDAmount;
        address signer;
        (dreUSDAmount, signer) = _mintFromFiatUsd(m, custodianSig);
        emit CustodianFiatMinted(m.mintRef, m.receiver, m.usdAmount, dreUSDAmount, signer);
    }

    /// @inheritdoc IdreUSDManager
    function mintRewards(FiatMint calldata m, bytes calldata custodianSig) external onlyRole(KEEPER_ROLE) whenNotPaused {
        if (dreRewardsDistributor() == address(0)) revert DreRewardsDistributorNotSet();
        if (m.receiver != dreRewardsDistributor()) revert InvalidReceiver(m.receiver);

        uint256 dreUSDAmount;
        address signer;
        (dreUSDAmount, signer) = _mintFromFiatUsd(m, custodianSig);
        IdreRewardsDistributor(dreRewardsDistributor()).addRewards();
        emit MintRewards(m.mintRef, m.receiver, m.usdAmount, dreUSDAmount, signer);
    }

    // ============ Withdrawal Functions (standard queue, 7 days, 0% fee) ============

    /// @inheritdoc IdreUSDManager
    function requestWithdrawal(
        uint256 dreUSDAmount,
        uint256 minUsdcAmount,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 tokenId) {
        _validateAddress(msg.sender);
        if (dreUSDAmount == 0) revert ZeroAmount();

        // Check deadline (time-limited order protection)
        if (block.timestamp > deadline) revert OrderExpired(deadline, block.timestamp);

        // Step 1: Burn entire dreUSD amount from user first
        IdreUSD(dreUSD).burn(msg.sender, dreUSDAmount);

        // Step 2: Use oracle to get USDC amount (dreUSD is 1:1 with USD)
        // Oracle accepts dreUSD amount (18 decimals), converts to price decimals internally,
        // and returns USDC amount in USDC decimals (6)
        uint256 usdcAmount = IDreUSDOracle(oracle).getTokenAmount(usdc, dreUSDAmount);

        // Check minimum USDC amount (slippage/flashloan protection)
        if (usdcAmount < minUsdcAmount) revert SlippageExceeded(minUsdcAmount, usdcAmount);

        // Step 3: Process withdrawal (dreUSD already burned, create NFT)
        tokenId = _queueWithdrawal(msg.sender, dreUSDAmount, usdcAmount);
    }

    /// @inheritdoc IdreUSDManager
    function requestExpressWithdrawal(
        uint256 dreUSDAmount,
        uint256 minUsdcAmount,
        uint256 deadline
    ) external nonReentrant whenNotPaused returns (uint256 expressTokenId) {
        _validateAddress(msg.sender);
        if (dreUSDAmount == 0) revert ZeroAmount();
        if (expressWithdrawalAvailable == 0) revert NoExpressAvailable();

        // Check deadline (time-limited order protection)
        if (block.timestamp > deadline) revert OrderExpired(deadline, block.timestamp);

        // Step 1: Use oracle to get USDC amount (dreUSD is 1:1 with USD)
        // Oracle accepts dreUSD amount (18 decimals), converts to price decimals internally,
        // and returns USDC amount in USDC decimals (6)
        uint256 totalUsdcAmount = IDreUSDOracle(oracle).getTokenAmount(usdc, dreUSDAmount);

        if (totalUsdcAmount < minUsdcAmount) revert SlippageExceeded(minUsdcAmount, totalUsdcAmount);
        if (totalUsdcAmount > expressWithdrawalAvailable) revert NoExpressAvailable();

        // Step 3: Burn the dreUSD amount from user
        IdreUSD(dreUSD).burn(msg.sender, dreUSDAmount);

        // Step 4: Mint the express withdrawal NFT
        expressTokenId = _queueExpressWithdrawal(msg.sender, totalUsdcAmount, dreUSDAmount);
    }

    /// @inheritdoc IdreUSDManager
    function fillWithdrawal(
        uint256[] calldata tokenIds,
        bool useVault
    ) external onlyRole(TREASURY_ROLE) whenNotPaused returns (uint256 filledCount, uint256 totalFilled) {
        if (tokenIds.length == 0) revert ZeroAmount();
        if (useVault && withdrawalVaultAdapter == address(0)) revert ZeroAddress();

        IWithdrawalNFT nft = IWithdrawalNFT(withdrawalNFT);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            // CHECKS
            if (!nft.positionExists(tokenId)) revert MissingPosition();

            IWithdrawalNFT.Position memory position = nft.getPosition(tokenId);
            uint256 usdcAmount = position.usdcAmount;

            // Skip if waiting time has not passed
            if (block.timestamp < position.createdAt + withdrawalWaitingTime) revert NotReady();

            // Check source has enough USDC
            if (useVault) {
                uint256 vaultBalance = IAaveV3Adapter(withdrawalVaultAdapter).getAvailableBalance();
                if (vaultBalance < usdcAmount) revert NoBalance();
            } else {
                if (IERC20(usdc).balanceOf(msg.sender) < usdcAmount) revert NoBalance();
            }

            // Get current NFT owner (may have been transferred)
            address currentOwner = IERC721(withdrawalNFT).ownerOf(tokenId);

            // Skip sanctioned/frozen owners: emit event and continue to next token
            if (IdreUSD(dreUSD).isBlockedAddress(currentOwner)) {
                emit WithdrawalSanctioned(tokenId, currentOwner);
                continue;
            }

            // EFFECTS - State changes before external calls (reentrancy protection)
            // Burn the NFT
            nft.burn(tokenId);

            filledCount++;
            totalFilled += usdcAmount;

            // INTERACTIONS - External calls last
            if (useVault) {
                // Withdraw from vault adapter directly to NFT owner
                IAaveV3Adapter(withdrawalVaultAdapter).withdraw(usdcAmount, currentOwner);
            } else {
                // Transfer USDC from caller (who has given allowance) to NFT owner
                IERC20(usdc).safeTransferFrom(msg.sender, currentOwner, usdcAmount);
            }

            // Emit event with actual fund source as filler
            address filler = useVault ? withdrawalVaultAdapter : msg.sender;
            emit WithdrawalFilled(tokenId, currentOwner, usdcAmount, filler);
        }
    }

    /// @inheritdoc IdreUSDManager
    function fillExpressWithdrawals(
        uint256[] calldata tokenIds
    ) external nonReentrant whenNotPaused onlyRole(EXPRESS_OPERATOR_ROLE) returns (uint256 filledCount, uint256 totalFilled) {
        if (tokenIds.length == 0) revert ZeroAmount();

        IWithdrawalNFT nft = IWithdrawalNFT(expressWithdrawalNFT);

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            // CHECKS
            if (!nft.positionExists(tokenId)) revert MissingPosition();

            IWithdrawalNFT.Position memory position = nft.getPosition(tokenId);
            uint256 userAmount = position.usdcAmount;
            uint256 feeAmount = expressWithdrawalFees[tokenId];
            uint256 totalRequired = userAmount + feeAmount;

            // Check custodian has enough USDC for both user amount and fee
            if (IERC20(usdc).balanceOf(msg.sender) < totalRequired) revert NoBalance();

            // Get current NFT owner (may have been transferred)
            address currentOwner = IERC721(expressWithdrawalNFT).ownerOf(tokenId);

            // Skip sanctioned/frozen owners: emit event and continue to next token
            if (IdreUSD(dreUSD).isBlockedAddress(currentOwner)) {
                emit WithdrawalSanctioned(tokenId, currentOwner);
                continue;
            }

            // EFFECTS - State changes before external calls (reentrancy protection)
            // Clear fee from mapping
            delete expressWithdrawalFees[tokenId];

            // Burn the NFT
            nft.burn(tokenId);

            filledCount++;
            totalFilled += totalRequired;
            
            // Track debt to express filler (total they need to pay: user amount + fee)
            expressFillerDebt += totalRequired;

            // INTERACTIONS - External calls last
            // Transfer USDC: user amount to NFT owner
            IERC20(usdc).safeTransferFrom(msg.sender, currentOwner, userAmount);

            // Transfer USDC: fee to fee recipient
            if (feeAmount > 0) {
                IERC20(usdc).safeTransferFrom(msg.sender, expressFeeRecipient, feeAmount);
                emit ExpressFeeCollected(expressFeeRecipient, feeAmount);
            }

            emit ExpressWithdrawalFilled(tokenId, currentOwner, userAmount, msg.sender);
        }
    }

    /// @inheritdoc IdreUSDManager
    function payExpressDebt(uint256 amount) external onlyRole(TREASURY_ROLE) {
        _paybackExpressFiller(amount);
    }

    // ============ Withdrawal View Functions ============


    /// @inheritdoc IdreUSDManager
    function getDailyFiatMinted() external view returns (uint256) {
        uint256 currentDay = block.timestamp / 1 days;
        return dailyFiatMinted[currentDay];
    }
    /// @inheritdoc IdreUSDManager
    function getExpressAvailable() external view returns (uint256) {
        return expressWithdrawalAvailable;
    }

    /// @inheritdoc IdreUSDManager
    function getExpressFillerDebt() external view returns (uint256) {
        return expressFillerDebt;
    }

    /// @inheritdoc IdreUSDManager
    function calculateExpressFee(uint256 usdcAmount) external view returns (uint256 feeAmount, uint256 userReceives) {
        feeAmount = (usdcAmount * expressWithdrawalFeeBps) / ScalingConstants.BPS_DENOMINATOR;
        userReceives = usdcAmount - feeAmount;
    }

    /// @inheritdoc IdreUSDManager
    function adminWithdraw(address token, address to, uint256 amount) external onlyRole(TREASURY_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(to, amount);

        emit AdminWithdraw(token, to, amount);
    }

    // internal functions

    /**
     * @dev Checks and updates the daily fiat mint tracking
     * @param usdAmount Amount being minted in USD (2 decimals)
     */
    function _checkAndUpdateDailyFiatMint(uint256 usdAmount) internal {
        // Calculate current day number (timestamp / seconds per day)
        uint256 currentDay = block.timestamp / 1 days;
        uint256 newTotal = dailyFiatMinted[currentDay] + usdAmount;
        // will revert automatically if dailyFiatMintCapUsd is 0
        if (newTotal > dailyFiatMintCapUsd) { 
            revert DailyFiatMintCapExceeded(newTotal, dailyFiatMintCapUsd);
        }

        // Update daily minted amount for current day
        dailyFiatMinted[currentDay] += usdAmount;
        emit DailyFiatMintUpdated(currentDay, newTotal);
    }

    /**
     * @dev Internal function to queue express withdrawal
     *      Calculates fee, creates NFT with user amount, stores fee in mapping
     * @param user Address of the user
     * @param usdcAmount Total USDC amount (before fee)
     * @return tokenId Minted NFT token ID
     */
    function _queueExpressWithdrawal(
        address user,
        uint256 usdcAmount,
        uint256 dreUSDAmount
    ) internal returns (uint256 tokenId) {
        // Ensure fee recipient is set
        if (expressFeeRecipient == address(0)) revert FeeRecipientNotSet();

        // Calculate fee in USDC
        uint256 feeUsdc = (usdcAmount * expressWithdrawalFeeBps) / ScalingConstants.BPS_DENOMINATOR;
        uint256 userReceivesUsdc = usdcAmount - feeUsdc;
    
        // Decrease available express limit
        uint256 oldAvailable = expressWithdrawalAvailable;
        expressWithdrawalAvailable -= usdcAmount;
        emit ExpressAvailableUpdated(oldAvailable, expressWithdrawalAvailable);

        // Mint express NFT (stores USDC amount user receives)
        tokenId = IWithdrawalNFT(expressWithdrawalNFT).mint(user, userReceivesUsdc);

        // Store fee in mapping (collected when filler fills this position)
        expressWithdrawalFees[tokenId] = feeUsdc;

        emit ExpressWithdrawalRequested(user, tokenId, dreUSDAmount, userReceivesUsdc, feeUsdc);
    }

    /**
     * @dev Internal function to queue withdrawal
     *      Creates NFT with USDC amount (no fee, dreUSD already burned in calling function)
     * @param user Address of the user
     * @param usdcAmount USDC amount for NFT
     * @return tokenId Minted NFT token ID
     */
    function _queueWithdrawal(
        address user,
        uint256 dreUSDAmount,
        uint256 usdcAmount
    ) internal returns (uint256 tokenId) {
        // Mint withdrawal NFT (1:1, no fee)
        tokenId = IWithdrawalNFT(withdrawalNFT).mint(user, usdcAmount);

        emit WithdrawalRequested(user, tokenId, dreUSDAmount, usdcAmount);
    }

    /**
     * @dev Internal function to pay back the express filler
     *      Transfers USDC to filler address and increases available limit
     * @param amount Amount to pay back
     */
    function _paybackExpressFiller(uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (expressPaybackAddress == address(0)) revert NoPaybackAddressSet();

        // Calculate max payback (can't payback more than debt or exceed max limit)
        uint256 maxPayback = expressFillerDebt;
        uint256 limitHeadroom =
            expressWithdrawalMaxLimit > expressWithdrawalAvailable
                ? expressWithdrawalMaxLimit - expressWithdrawalAvailable
                : 0;
        if (maxPayback > limitHeadroom) {
            maxPayback = limitHeadroom;
        }

        if (amount > maxPayback) {
            revert PaybackExceedsDebt(amount, maxPayback);
        }

        // Transfer USDC to filler
        IERC20(usdc).safeTransferFrom(msg.sender, expressPaybackAddress, amount);

        // Reduce debt
        expressFillerDebt -= amount;

        // Increase available limit
        uint256 oldAvailable = expressWithdrawalAvailable;
        expressWithdrawalAvailable += amount;

        emit ExpressFillerPayback(expressPaybackAddress, amount, expressWithdrawalAvailable);
        emit ExpressAvailableUpdated(oldAvailable, expressWithdrawalAvailable);
    }

    /**
     * @dev Common pre-mint validation checks shared across all mint entrypoints.
     *      Validates amount, custodian vault configuration, asset allowlist, and deadline.
     * @param asset Stablecoin address to validate
     * @param amountIn Amount being minted
     * @param deadline Deadline timestamp for the mint operation
     */
    function _preMintChecks(address asset, uint256 amountIn, uint256 deadline) internal view {
        if (amountIn == 0) revert ZeroAmount();
        if (custodianVault == address(0)) revert ZeroAddress();
        if (!allowed[asset]) revert StablecoinNotAllowed(asset);
        if (block.timestamp > deadline) revert OrderExpired(deadline, block.timestamp);
    }

    /**
     * @dev Checks if an address passes dreUSD compliance (sanctions/freeze).
     *      Uses dreUSD's centralized validation and reverts with manager's
     * @param addr Address to check
     */
    function _validateAddress(address addr) internal view {
       IdreUSD(dreUSD).validateAddress(addr);
    }

    /**
     * @dev EIP-712 domain separator for auth / MintFrom (for off-chain typed data)
     */
    function authDomainSeparator() external view returns (bytes32) {
        return _authDomainSeparator();
    }

    function _authDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                AUTH_DOMAIN_TYPEHASH,
                AUTH_DOMAIN_NAME_HASH,
                AUTH_DOMAIN_VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    /**
     * @dev Verifies EIP-712 MintFrom signature: digest must be signed by 'from', nonce must match.
     */
    function _authorize(
        address from,
        address receiver,
        address asset,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata authorizeSig
    ) internal view {
        uint256 nonce = authNonce[from];
        bytes32 structHash = keccak256(
            abi.encode(
                AUTH_MINTFROM_TYPEHASH,
                from,
                receiver,
                asset,
                amountIn,
                minAmountOut,
                deadline,
                nonce
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _authDomainSeparator(), structHash)
        );
        address signer = ECDSA.recover(digest, authorizeSig);
        if (signer != from) revert InvalidMintFromSignature();
    }

    /**
     * @dev Executes ERC20 Permit to get allowance from owner
     *      Checks if allowance is already sufficient before calling permit to prevent
     *      front-running attacks where an attacker consumes the permit nonce.
     * @param owner Address that signed the permit
     * @param asset Token address (must support ERC20 Permit)
     * @param amount Amount to approve
     * @param permitSig Encoded permit signature (abi.encode(deadline, v, r, s))
     */
    function _executePermit(
        address owner,
        address asset,
        uint256 amount,
        bytes calldata permitSig
    ) internal {
        // Check if allowance is already sufficient (prevents front-running attack)
        // If a front-runner already called permit(), the allowance will be set
        // and we can skip the permit call to avoid nonce reuse errors
        if (IERC20(asset).allowance(owner, address(this)) >= amount) {
            return;
        }

        // Decode the permit signature
        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = abi.decode(
            permitSig,
            (uint256, uint8, bytes32, bytes32)
        );

        // Call permit on the token to grant allowance to this contract
        IERC20Permit(asset).permit(owner, address(this), amount, deadline, v, r, s);
    }

    /**
     * @dev Transfers stablecoin from sender to custodian vault, mints dreUSD, and checks slippage
     *      Uses before-after balance check to account for fee-on-transfer tokens (e.g., USDT)
     * @param asset Stablecoin address
     * @param from Address to transfer stablecoin from
     * @param amountIn Amount of stablecoin
     * @param minAmountOut Minimum dreUSD amount expected (slippage protection)
     * @param receiver Address to receive dreUSD
     * @return dreUSDAmount Amount of dreUSD minted
     */
    function _transferAndMint(
        address asset,
        address from,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) internal returns (uint256 dreUSDAmount) {
        // Get balance before transfer to account for fee-on-transfer tokens
        uint256 balanceBefore = IERC20(asset).balanceOf(custodianVault);

        // Transfer stablecoin from sender to custodian vault
        IERC20(asset).safeTransferFrom(from, custodianVault, amountIn);

        // Get balance after transfer to calculate actual received amount
        uint256 balanceAfter = IERC20(asset).balanceOf(custodianVault);
        uint256 amountReceived = balanceAfter - balanceBefore;

        // Calculate and mint dreUSD based on actual received amount
        dreUSDAmount = _mintDreUSD(asset, amountReceived, receiver);

        // Check minimum amount out (slippage protection)
        if (dreUSDAmount < minAmountOut) revert SlippageExceeded(minAmountOut, dreUSDAmount);
    }

    /**
     * @dev Calculates dreUSD amount and mints to receiver
     *      Uses oracle to validate price and get USD value
     * @param asset Stablecoin address
     * @param amountIn Amount of stablecoin
     * @param receiver Address to receive dreUSD
     * @return dreUSDAmount Amount of dreUSD minted
     */
    function _mintDreUSD(
        address asset,
        uint256 amountIn,
        address receiver
    ) internal returns (uint256 dreUSDAmount) {
        uint8 dreUSDDecimals = IERC20Metadata(dreUSD).decimals();

        // Use oracle to get USD value (validates price is not stale and within deviation)
        // Oracle returns value in price feed's decimals
        uint256 usdValue = IDreUSDOracle(oracle).getUsdValue(asset, amountIn);
        uint8 priceDecimals = IDreUSDOracle(oracle).getPriceDecimals(asset);
        
        // Convert from price feed decimals to dreUSD decimals
        dreUSDAmount = _convertToDecimals(usdValue, priceDecimals, dreUSDDecimals);

        // Mint dreUSD to receiver
        IdreUSD(dreUSD).mint(receiver, dreUSDAmount);
    }

    /**
     * @dev Validates FiatMint request, verifies custodian signature, and mints dreUSD to receiver.
     *      Performs all validations shared between mintFromUsd and mintRewards.
     * @param m The FiatMint struct containing mint parameters
     * @param custodianSig The custodian signature for the mint request
     * @return dreUSDAmount Amount of dreUSD minted
     * @return signer Address of the custodian who signed the request
     */
    function _mintFromFiatUsd(FiatMint calldata m, bytes calldata custodianSig) internal returns (uint256 dreUSDAmount, address signer) {
        // Validate mint request
        if (m.receiver == address(0)) revert ZeroAddress();
        if (m.usdAmount == 0) revert ZeroAmount();
        if (block.timestamp > m.validUntil) revert MintExpired(m.validUntil);
        if (m.chainId != block.chainid) revert InvalidChainId(block.chainid, m.chainId);
        if (usedMintRefs[m.mintRef]) revert MintRefAlreadyUsed(m.mintRef);

        // Check and update daily limit
        _checkAndUpdateDailyFiatMint(m.usdAmount);

        // Verify custodian signature
        bytes32 structHash = _computeFiatMintStructHash(m.mintRef, m.receiver, m.usdAmount, m.validUntil, m.chainId);
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(structHash);
        signer = ECDSA.recover(ethSignedHash, custodianSig);
        if (!custodians[signer]) revert InvalidCustodianSignature();

        // Mark mintRef as used
        usedMintRefs[m.mintRef] = true;

        // Convert USD amount to dreUSD (fiat has 2 decimals)
        uint8 dreUSDDecimals = IERC20Metadata(dreUSD).decimals();
        dreUSDAmount = _convertToDecimals(m.usdAmount, 2, dreUSDDecimals);

        // Mint dreUSD to receiver
        IdreUSD(dreUSD).mint(m.receiver, dreUSDAmount);
    }

    /**
     * @dev Converts an amount from one decimal precision to another
     * @param amount The amount to convert
     * @param fromDecimals The source decimal precision
     * @param toDecimals The target decimal precision
     */
    function _convertToDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals > toDecimals) {
            return amount / ScalingConstants.scaleBase(uint8(fromDecimals - toDecimals));
        } else {
            return amount * ScalingConstants.scaleBase(uint8(toDecimals - fromDecimals));
        }
    }

    /**
     * @dev Computes the struct hash for the FiatMint struct
     * @param a The mintRef
     * @param b The receiver
     * @param c The usdAmount
     * @param d The validUntil
     * @param e The chainId
     * @return hashedVal The struct hash
     * @notice Includes address(this) to bind signatures to this specific contract instance
     */
    function _computeFiatMintStructHash(bytes32 a, address b, uint256 c, uint256 d, uint256 e) internal view returns (bytes32 hashedVal) {
        return keccak256(abi.encode(a, b, c, d, e, address(this)));
    }

    /**
     * @dev Override supportsInterface for AccessControl
     */
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    /** 
     * @dev Pauses mint and request withdrawals (only PAUSER_ROLE)
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses mint and request withdrawals (only PAUSER_ROLE)
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

}
