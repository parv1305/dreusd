// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IWithdrawalNFT
 * @dev Common interface for withdrawal position NFTs (Express & Long Queue)
 */
interface IWithdrawalNFT {
    // ============ Structs ============

    /// @notice Position data stored on-chain
    struct Position {
        address user;           // Original creator/beneficiary
        uint256 usdcAmount;     // USDC amount owed
        uint256 createdAt;      // Creation timestamp
    }

    // ============ Errors ============

    error ZeroAddress();
    error InvalidCaller();
    error ZeroAmount();
    error PositionNotFound(uint256 tokenId);
    error SameDreUSD();
    error SameDreUSDManager();

    // ============ Events ============

    event PositionCreated(
        uint256 indexed tokenId,
        address indexed user,
        uint256 usdcAmount,
        uint256 createdAt
    );
    event PositionFilled(
        uint256 indexed tokenId,
        address indexed user,
        uint256 usdcAmount,
        address indexed filler
    );

    event DreUSDUpdated(address indexed dreUSD);
    event DreUSDManagerUpdated(address indexed oldManager, address indexed newManager);

    // ============ External Functions ============

    /**
     * @notice Mints a new withdrawal position NFT
     * @param to Address to mint the NFT to
     * @param usdcAmount USDC amount for this position
     * @return tokenId The newly minted token ID
     */
    function mint(address to, uint256 usdcAmount) external returns (uint256 tokenId);

    /**
     * @notice Burns a position NFT (called when position is filled)
     * @param tokenId Token ID to burn
     */
    function burn(uint256 tokenId) external;

    // ============ View Functions ============

    /**
     * @notice Gets position data for a token
     * @param tokenId Token ID to query
     * @return position The position data
     */
    function getPosition(uint256 tokenId) external view returns (Position memory position);

    /**
     * @notice Gets positions data for multiple tokens
     * @param tokenIds Token IDs to query
     * @return positions The position data
     */
    function getPositions(uint256[] memory tokenIds) external view returns (Position[] memory positions);

    /**
     * @notice Gets the USDC amount for a position
     * @param tokenId Token ID to query
     * @return usdcAmount The USDC amount owed
     */
    function getUsdcAmount(uint256 tokenId) external view returns (uint256 usdcAmount);

    /**
     * @notice Checks if a position exists (not burned)
     * @param tokenId Token ID to check
     * @return exists True if position exists
     */
    function positionExists(uint256 tokenId) external view returns (bool exists);

    /**
     * @notice Gets the original creator of a position
     * @param tokenId Token ID to query
     * @return user The original creator address
     */
    function getOriginalUser(uint256 tokenId) external view returns (address user);

    /**
     * @notice Gets the contiguous "next in order" pending range (frontier + 1 through nextTokenId - 1).
     *
     * Frontend — how to get all pending positions:
     * 1. Read lastBurnedTokenId and nextTokenId (or use getPendingRange() for the contiguous range).
     * 2. Pending = token IDs that still exist. Two options:
     *    (a) Enumerate existing tokens (e.g. totalSupply() then tokenByIndex(i) for i in [0, totalSupply)),
     *        then sort by tokenId for queue order; or
     *    (b) Contiguous tail: for id from startTokenId to endTokenId (from getPendingRange), include id
     *        if positionExists(id). Gaps below frontier: for id in [1, lastBurnedTokenId], include id
     *        if positionExists(id). Union of those two sets is the full pending set in queue order.
     * @return startTokenId First token ID in the contiguous pending range (lastBurnedTokenId + 1)
     * @return endTokenId Last token ID in that range (nextTokenId - 1), or 0 if none
     */
    function getPendingRange() external view returns (uint256 startTokenId, uint256 endTokenId);

    /**
     * @notice Gets token IDs by indexes
     * @param indexes Indexes to query
     * @return tokenIds The token IDs
     */
    function getTokensByIndexes(uint256[] memory indexes) external view returns (uint256[] memory tokenIds);
}
