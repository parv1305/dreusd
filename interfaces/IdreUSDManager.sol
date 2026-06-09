// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IdreUSDManager
 * @dev Interface for dreUSDManager contract
 */
interface IdreUSDManager {
    // ============ Structs ============

    /// @notice Fiat mint request (off-chain USD deposit)
    struct FiatMint {
        bytes32 mintRef;            // Unique reference (see docs for generation)
        address receiver;           // Address to mint dreUSD to
        uint256 usdAmount;          // USD amount (2 decimals, e.g., 10000 = $100.00)
        uint256 validUntil;         // Timestamp after which this mint is invalid
        uint256 chainId;            // Chain ID to prevent cross-chain replay
    }

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error NoExpressAvailable();
    error StablecoinNotAllowed(address token);
    error StablecoinAlreadyAllowed(address token);
    error SanctionedAddress(address addr);
    error InvalidLimit();
    /// @notice Thrown when new express withdrawal limit is below current outstanding utilization
    error ExpressLimitBelowOutstanding(uint256 maxLimit, uint256 outstanding);
    error DailyFiatMintCapTooHigh(uint256 cap, uint256 maxCap);
    error MintRefAlreadyUsed(bytes32 mintRef);
    error MintExpired(uint256 validUntil);
    error InvalidChainId(uint256 expected, uint256 provided);
    error InvalidCustodianSignature();
    error CustodianAlreadyAdded(address custodian);
    error CustodianNotAllowed(address custodian);
    error SlippageExceeded(uint256 minExpected, uint256 actual);
    error DailyFiatMintCapExceeded(uint256 totalAmount, uint256 cap);
    error OrderExpired(uint256 deadline, uint256 currentTime);
    error PaybackExceedsDebt(uint256 payback, uint256 maxPayback);
    error NoPaybackAddressSet();
    error FeeRecipientNotSet();
    error NoBalance();
    error MissingPosition();
    error NotReady();
    error InvalidReceiver(address receiver);
    /// @notice Thrown when mintFrom receiver is not the token source (from)
    error MintFromReceiverNotAllowed(address from, address receiver);
    /// @notice Thrown when mintFrom EIP-712 signature is invalid or signer is not 'from'
    error InvalidMintFromSignature();
    /// @notice Thrown when withdrawal waiting time is outside allowed bounds (1–14 days)
    error InvalidWithdrawalWaitingTime(uint256 waitingTime, uint256 minAllowed, uint256 maxAllowed);
    /// @notice Thrown when dreRewardsDistributor is not set
    error DreRewardsDistributorNotSet();
    /// @notice Thrown when vault adapter's asset (USDC) does not match manager's USDC
    error IncompatibleVaultAdapter(address adapter, address expectedUsdc);
    error SameVault();
    error SameDailyFiatMintCap();
    error SameExpressPaybackAddress();
    error SameExpressWithdrawalConfig();
    error SameWithdrawalWaitingTime();
    error SameVaultAdapter();

    // ============ Events ============

    // Stablecoin management
    event StablecoinAdded(address indexed token);
    event StablecoinRemoved(address indexed token);
    event VaultUpdated(address indexed oldCustodianVault, address indexed newCustodianVault);

    // Minting
    event Minted(address indexed receiver, address asset, uint256 amountIn, uint256 dreUsdOut);
    event MintedFrom(address indexed from, address indexed receiver, address asset, uint256 amountIn, uint256 dreUsdOut);
    event MintAndStake(address indexed receiver, address asset, uint256 amountIn, uint256 dreUsdsOut, uint256 dreUSDAmount);
    event MintRewards(bytes32 indexed mintRef, address indexed receiver, uint256 usdAmount, uint256 dreUSDAmount, address signer);
    event CustodianFiatMinted(bytes32 indexed mintRef, address indexed receiver, uint256 usdAmount, uint256 dreUSDAmount, address signer);
    event CustodianAdded(address indexed custodian);
    event CustodianRemoved(address indexed custodian);
    event DailyFiatMintCapUpdated(uint256 oldCap, uint256 newCap);
    event DailyFiatMintUpdated(uint256 indexed day, uint256 newTotal);

    // Treasury
    event AdminWithdraw(address indexed token, address indexed to, uint256 amount);

    // Express Withdrawals
    event ExpressWithdrawalRequested(
        address indexed user,
        uint256 indexed tokenId,
        uint256 dreUSDAmount,
        uint256 usdcAmount,
        uint256 feeAmount
    );
    event ExpressWithdrawalFilled(
        uint256 indexed tokenId,
        address indexed user,
        uint256 usdcAmount,
        address indexed filler
    );
    event ExpressLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event ExpressAvailableUpdated(uint256 oldAvailable, uint256 newAvailable);
    event ExpressFillerPayback(address indexed to, uint256 amount, uint256 newAvailable);
    event ExpressPaybackAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event ExpressFeeUpdated(uint256 oldFee, uint256 newFee);
    event ExpressFeeCollected(address indexed recipient, uint256 amount);
    event ExpressFeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // Withdrawal (standard queue)
    event WithdrawalRequested(
        address indexed user,
        uint256 indexed tokenId,
        uint256 dreUSDAmount,
        uint256 usdcAmount
    );
    event WithdrawalFilled(
        uint256 indexed tokenId,
        address indexed user,
        uint256 usdcAmount,
        address indexed filler
    );
    event WithdrawalSanctioned(uint256 indexed tokenId, address indexed account);
    event WithdrawalWaitingTimeUpdated(uint256 oldWaitingTime, uint256 newWaitingTime);
    event VaultAdapterUpdated(address indexed oldAdapter, address indexed newAdapter);

    // Combined withdrawal request
    event WithdrawRequested(
        address indexed user,
        uint256 dreUSDAmount,
        uint256 totalUsdcAmount,
        uint256 expressUsdcAmount,
        uint256 withdrawalUsdcAmount,
        uint256 expressFeeAmount,
        uint256 expressTokenId,
        uint256 withdrawalTokenId
    );

    // ============ Configuration Functions ============

    /**
     * @notice Updates the custodian vault address (receives stablecoin from mint flows; e.g. multisig)
     * @param _custodianVault New custodian vault address
     */
    function updateVault(address _custodianVault) external;

    /**
     * @notice Update custodian list (fiat mint signers)
     * @param _custodian Custodian address
     * @param isAllowed True to add, false to remove
     */
    function updateCustodianList(address _custodian, bool isAllowed) external;

    /**
     * @notice Sets the daily fiat mint cap
     * @param _cap New daily cap in USD (6 decimals)
     */
    function setDailyFiatMintCap(uint256 _cap) external;

    /**
     * @notice Returns the rewards distributor (read from dreUSDs vault; single source of truth).
     */
    function dreRewardsDistributor() external view returns (address);

    /**
     * @notice Update allowed stablecoin list for minting
     * @param token Stablecoin address
     * @param allowed True to allow, false to disallow
     */
    function updateAllowedList(address token, bool allowed) external;

    // ============ Minting Functions ============

    /**
     * @notice Mints dreUSD 1:1 with allowed stablecoin deposit using ERC20 Permit
     * @param asset Address of the stablecoin to deposit
     * @param amountIn Amount of stablecoin to deposit (in stablecoin decimals)
     * @param minAmountOut Minimum dreUSD to receive (slippage protection)
     * @param deadline Timestamp after which the order expires
     * @param permitSig ERC20 Permit signature (abi.encode(deadline, v, r, s))
     */
    function mint(
        address asset,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata permitSig
    ) external;

    /**
     * @notice Mints dreUSD using standard ERC20 approval (no permit)
     * @param stablecoin Address of the stablecoin to deposit
     * @param amount Amount of stablecoin to deposit (in stablecoin decimals)
     * @param minAmountOut Minimum dreUSD to receive (slippage protection)
     * @param deadline Timestamp after which the order expires
     */
    function mint(
        address stablecoin,
        uint256 amount,
        uint256 minAmountOut,
        uint256 deadline
    ) external;

    /**
     * @notice Mints dreUSD from another address using ERC20 Permit
     * @param from Address to transfer stablecoin from (must have signed the permit)
     * @param asset Address of the stablecoin to deposit
     * @param amountIn Amount of stablecoin to deposit (in stablecoin decimals)
     * @param receiver Address to receive dreUSD
     * @param minAmountOut Minimum dreUSD to receive (slippage protection)
     * @param deadline Timestamp after which the order expires
     * @param permitSig ERC20 Permit signature (abi.encode(deadline, v, r, s))
     * @param authorizeSig EIP-712 signature over MintFrom(from, receiver, asset, amountIn, minAmountOut, deadline, nonce); signer must be from
     */
    function mintFrom(
        address from,
        address asset,
        uint256 amountIn,
        address receiver,
        uint256 minAmountOut,
        uint256 deadline,
        bytes calldata permitSig,
        bytes calldata authorizeSig
    ) external;

    /// @notice Current nonce for EIP-712 MintFrom (per address, incremented on each mintFrom)
    function authNonce(address account) external view returns (uint256);

    /// @notice EIP-712 domain separator for MintFrom (for off-chain typed data)
    function authDomainSeparator() external view returns (bytes32);

    /**
     * @notice Mints dreUSD and stakes into dreUSDs vault in one transaction
     * @param asset Address of the stablecoin to deposit
     * @param amountIn Amount of stablecoin to deposit (in stablecoin decimals)
     * @param receiver Address to receive dreUSDs shares
     * @param minAmountOut Minimum dreUSD to mint (slippage protection)
     * @param minSharesOut Minimum dreUSDs shares to receive (slippage protection)
     * @param deadline Timestamp after which the order expires
     * @param permitSig ERC20 Permit signature (abi.encode(deadline, v, r, s))
     */
    function mintAndStake(
        address asset,
        uint256 amountIn,
        address receiver,
        uint256 minAmountOut,
        uint256 minSharesOut,
        uint256 deadline,
        bytes calldata permitSig
    ) external;

    /**
     * @notice Mints dreUSD for off-chain USD deposits with custodian signature
     * @param m FiatMint struct containing mint details
     * @param custodianSig Signature from custodian authorizing the mint
     */
    function mintFromUsd(FiatMint calldata m, bytes calldata custodianSig) external;

    /**
     * @notice Mints dreUSD to a rewards distributor and calls addRewards on it. Same parameters as mintFromUsd; receiver is the distributor.
     * @param m FiatMint struct containing mint details (receiver = rewards distributor)
     * @param custodianSig Signature from custodian authorizing the mint
     */
    function mintRewards(FiatMint calldata m, bytes calldata custodianSig) external;

    // ============ Express Withdrawal Functions ============

    /**
     * @notice Request an express withdrawal (6h fill target, 50 bps fee in USDC)
     * @dev All-or-nothing: reverts with NoExpressAvailable if oracle USDC amount > expressWithdrawalAvailable.
     *      Slippage: reverts with SlippageExceeded if oracle USDC amount (gross) < minUsdcAmount.
     *      Full dreUSDAmount is burned on success.
     * @param dreUSDAmount Amount of dreUSD to withdraw (burned immediately)
     * @param minUsdcAmount Minimum gross USDC amount from oracle (slippage/flashloan protection)
     * @param deadline Timestamp after which the order expires (time-limited order)
     * @return expressTokenId The express NFT token ID
     */
    function requestExpressWithdrawal(
        uint256 dreUSDAmount,
        uint256 minUsdcAmount,
        uint256 deadline
    ) external returns (uint256 expressTokenId);

    /**
     * @notice Express custodian fills express withdrawal positions
     * @param tokenIds Array of express NFT token IDs to fill
     * @return filledCount Number of positions successfully filled
     * @return totalFilled Total USDC amount paid to users
     */
    function fillExpressWithdrawals(uint256[] calldata tokenIds) external returns (uint256 filledCount, uint256 totalFilled);

    /**
     * @notice Pay express debt (transfer USDC to express payback address, increase available express limit)
     * @param amount Amount of USDC to pay
     */
    function payExpressDebt(uint256 amount) external;

    /**
     * @notice Update the address that receives express payback (when moderator calls payExpressDebt)
     * @param newAddress Address to receive payback
     */
    function updateExpressPaybackAddress(address newAddress) external;

    /**
     * @notice Update express withdrawal config (max limit, fee bps, fee recipient)
     * @param maxLimit Max express limit in USDC (6 decimals)
     * @param feeBps Fee in basis points (e.g., 50 = 0.5%)
     * @param feeRecipient Address to receive express fees
     */
    function updateExpressWithdrawal(uint256 maxLimit, uint256 feeBps, address feeRecipient) external;

    // ============ Withdrawal Functions (standard queue) ============

    /**
     * @notice Request a standard withdrawal (7 days, 0% fee)
     *         Goes directly to withdrawal queue without using express limit
     * @param dreUSDAmount Amount of dreUSD to withdraw
     * @param minUsdcAmount Minimum USDC amount to receive (slippage/flashloan protection)
     * @param deadline Timestamp after which the order expires (time-limited order)
     * @return tokenId The minted NFT token ID
     */
    function requestWithdrawal(
        uint256 dreUSDAmount,
        uint256 minUsdcAmount,
        uint256 deadline
    ) external returns (uint256 tokenId);

    /**
     * @notice Treasury fills withdrawal positions
     * @param tokenIds Array of withdrawal NFT token IDs to fill
     * @param useVault If true, withdraw USDC from vault adapter (e.g., Aave). If false, transfer from caller's allowance.
     * @return filledCount Number of positions successfully filled
     * @return totalFilled Total USDC amount paid to users
     */
    function fillWithdrawal(uint256[] calldata tokenIds, bool useVault) external returns (uint256 filledCount, uint256 totalFilled);

    /**
     * @notice Update withdrawal config (waiting time)
     * @param waitingTime Minimum waiting time before positions can be filled (seconds)
     */
    function updateWithdrawal(uint256 waitingTime) external;

    /**
     * @notice Update the vault adapter for filling withdrawals
     * @param adapter Address of the vault adapter (e.g., dreAaveAdapter). Cannot be zero address.
     */
    function updateVaultAdapter(address adapter) external;

    // ============ View Functions ============

    /**
     * @notice Returns the amount minted via fiat today
     * @return Amount minted in USD (2 decimals)
     */
    function getDailyFiatMinted() external view returns (uint256);

    /**
     * @notice Get current available express withdrawal amount
     * @return Available amount in USDC
     */
    function getExpressAvailable() external view returns (uint256);

    /**
     * @notice Get the debt owed to express filler
     * @return Debt amount in USDC
     */
    function getExpressFillerDebt() external view returns (uint256);

    /**
     * @notice Calculate the fee for an express withdrawal amount
     * @param usdcAmount USDC amount to withdraw
     * @return feeAmount The fee that would be charged
     * @return userReceives Amount user would receive after fee
     */
    function calculateExpressFee(uint256 usdcAmount) external view returns (uint256 feeAmount, uint256 userReceives);

    // ============ Treasury Functions ============

    /**
     * @notice Treasury function to withdraw tokens from the manager
     * @param token Address of the token to withdraw
     * @param to Address to send tokens to
     * @param amount Amount to withdraw
     */
    function adminWithdraw(address token, address to, uint256 amount) external;
}
