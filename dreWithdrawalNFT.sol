// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC721EnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IWithdrawalNFT} from "./interfaces/IWithdrawalNFT.sol";
import {IdreUSD} from "./interfaces/IdreUSD.sol";

/**
 * @title dreWithdrawalNFT
 * @dev ERC721 NFT representing withdrawal positions (e.g. standard queue, 7 days, 0% fee)
 *      Upgradeable via UUPS proxy pattern
 */
contract dreWithdrawalNFT is
    Initializable,
    ERC721EnumerableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    IWithdrawalNFT
{
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");


    /// @notice Next token ID to mint
    uint256 public nextTokenId;

    /// @notice Position data by token ID
    mapping(uint256 => Position) private _positions;

    /// @notice Highest token ID that has been burned (processed) so far.
    uint256 public lastBurnedTokenId;

    /// @notice dreUSD token address for sanctions checking
    address public dreUSD;

    /// @notice dreUSDManager contract; only this address may call mint() and burn()
    address public dreUSDManager;

    /// @dev Reserved storage slots for future upgrades
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     * @param _dreUSD dreUSD token address validating transfers
     * @param _name Name of the NFT
     * @param _symbol Symbol of the NFT
     * @param defaultAdmin Address to grant the default admin role
     * @param upgrader Upgrader address to grant UPGRADER_ROLE
     */
    function initialize(
        address _dreUSD,
        string memory _name,
        string memory _symbol,
        address defaultAdmin,
        address upgrader
    ) public initializer {
        if (_dreUSD == address(0)) revert ZeroAddress();
        if (defaultAdmin == address(0)) revert ZeroAddress();
        if (upgrader == address(0)) revert ZeroAddress();

        __ERC721_init_unchained(_name, _symbol);
        __ERC721Enumerable_init_unchained();
        __AccessControl_init_unchained();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, upgrader);

        dreUSD = _dreUSD;
        nextTokenId = 1; // Start from 1, 0 is reserved for "no position"
    }

    /**
     * @dev Sets the dreUSD address (for already-deployed contracts)
     * @param _dreUSD dreUSD token address for sanctions checking
     */
    function setDreUSD(address _dreUSD) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_dreUSD == address(0)) revert ZeroAddress();
        if (_dreUSD == dreUSD) revert SameDreUSD();
        dreUSD = _dreUSD;
        emit DreUSDUpdated(_dreUSD);
    }

    /**
     * @notice Set the dreUSDManager address (only this contract may call mint() and burn())
     * @param _dreUSDManager dreUSDManager contract address
     */
    function setDreUSDManager(address _dreUSDManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_dreUSDManager == address(0)) revert ZeroAddress();
        if (_dreUSDManager == dreUSDManager) revert SameDreUSDManager();
        address oldManager = dreUSDManager;
        dreUSDManager = _dreUSDManager;
        emit DreUSDManagerUpdated(oldManager, _dreUSDManager);
    }

    // ============ External Functions ============

    /// @inheritdoc IWithdrawalNFT
    function mint(address to, uint256 usdcAmount) external returns (uint256 tokenId) {
        if (msg.sender != dreUSDManager) revert InvalidCaller();
        if (to == address(0)) revert ZeroAddress();
        if (usdcAmount == 0) revert ZeroAmount();

        tokenId = nextTokenId++;

        _positions[tokenId] = Position({
            user: to,
            usdcAmount: usdcAmount,
            createdAt: block.timestamp
        });

        _safeMint(to, tokenId);

        emit PositionCreated(tokenId, to, usdcAmount, block.timestamp);
    }

    /// @inheritdoc IWithdrawalNFT
    function burn(uint256 tokenId) external {
        if (msg.sender != dreUSDManager) revert InvalidCaller();
        if (!_exists(tokenId)) revert PositionNotFound(tokenId);

        Position memory position = _positions[tokenId];
        address owner = ownerOf(tokenId);

        if (tokenId > lastBurnedTokenId) {
            lastBurnedTokenId = tokenId;
        }

        delete _positions[tokenId];
        _burn(tokenId);

        emit PositionFilled(tokenId, owner, position.usdcAmount, msg.sender);
    }

    // ============ View Functions ============

    /// @inheritdoc IWithdrawalNFT
    function getPosition(uint256 tokenId) external view returns (Position memory position) {
        return _getPosition(tokenId);
    }

    /// @inheritdoc IWithdrawalNFT
    function getPositions(uint256[] memory tokenIds) external view returns (Position[] memory positions) {
        positions = new Position[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            positions[i] = _getPosition(tokenIds[i]);
        }
        return positions;
    }

    /// @inheritdoc IWithdrawalNFT
    function getUsdcAmount(uint256 tokenId) external view returns (uint256 usdcAmount) {
        if (!_exists(tokenId)) revert PositionNotFound(tokenId);
        return _positions[tokenId].usdcAmount;
    }

    /// @inheritdoc IWithdrawalNFT
    function positionExists(uint256 tokenId) external view returns (bool exists) {
        return _exists(tokenId);
    }

    /// @inheritdoc IWithdrawalNFT
    function getOriginalUser(uint256 tokenId) external view returns (address user) {
        if (!_exists(tokenId)) revert PositionNotFound(tokenId);
        return _positions[tokenId].user;
    }

    /// @inheritdoc IWithdrawalNFT
    /// @dev Returns the contiguous range of token IDs that are "next in order" (frontier + 1
    ///      through nextTokenId - 1). To get the full set of pending positions: (1) all IDs in
    ///      [startTokenId, endTokenId] from this return value that exist, and (2) any ID in
    ///      [1, lastBurnedTokenId] for which positionExists(id) is true (out-of-order gaps).
    function getPendingRange()
        external
        view
        returns (
            uint256 startTokenId,
            uint256 endTokenId
        )
    {
        startTokenId = lastBurnedTokenId + 1;
        endTokenId = nextTokenId > 1 ? nextTokenId - 1 : 0;
    }

    function getTokensByIndexes(uint256[] memory indexes) external view returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](indexes.length);
        for (uint256 i = 0; i < indexes.length; i++) {
            tokenIds[i] = tokenByIndex(indexes[i]);
        }
        return tokenIds;
    }

    // ============ Internal Functions ============

    /**
     * @dev Checks if a token exists
     */
    function _exists(uint256 tokenId) internal view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function _getPosition(uint256 tokenId) internal view returns (Position memory position) {
        if (!_exists(tokenId)) revert PositionNotFound(tokenId);
        return _positions[tokenId];
    }

    /**
     * @dev Override _update to validate addresses on transfers
     * @param to Address receiving the token
     * @param tokenId Token ID being transferred
     * @param auth Address that authorized the transfer (owner or approved)
     */
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to != address(0)) {
            _validateAddress(to);
        }

        address owner = _ownerOf(tokenId);
        if (owner != address(0)) {
            _validateAddress(owner);
        }

        if (auth != address(0) && auth != owner) {
            _validateAddress(auth);
        }

        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Checks if an address passes dreUSD compliance (sanctions/freeze).
     * @param addr Address to check
     */
    function _validateAddress(address addr) internal view {
       IdreUSD(dreUSD).validateAddress(addr);
    }

    /**
     * @dev Authorizes an upgrade to a new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    // ============ Required Overrides ============

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721EnumerableUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
