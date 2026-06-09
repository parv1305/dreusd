// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IWithdrawalNFT} from "../interfaces/IWithdrawalNFT.sol";

/**
 * @title WithdrawalEnumerableNFTMock
 * @dev Test-only enumerable withdrawal NFT for `dreWithdrawalKeeperBot` tests (does not modify audited mocks).
 */
contract WithdrawalEnumerableNFTMock is IWithdrawalNFT, IERC721, IERC721Enumerable {
    uint256 private _tokenIdCounter;
    uint256 private _lastBurnedTokenId;
    mapping(uint256 => Position) private _positions;
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    uint256[] private _allTokens;
    mapping(uint256 => uint256) private _tokenIndex;

    function mint(address to, uint256 usdcAmount) external returns (uint256 tokenId) {
        tokenId = ++_tokenIdCounter;
        _positions[tokenId] = Position({user: to, usdcAmount: usdcAmount, createdAt: block.timestamp});
        _owners[tokenId] = to;
        _balances[to]++;
        _tokenIndex[tokenId] = _allTokens.length;
        _allTokens.push(tokenId);
        emit PositionCreated(tokenId, to, usdcAmount, block.timestamp);
    }

    function burn(uint256 tokenId) external {
        require(_positions[tokenId].user != address(0), "PositionNotFound");
        if (tokenId > _lastBurnedTokenId) _lastBurnedTokenId = tokenId;
        address owner = _owners[tokenId];
        uint256 usdcAmount = _positions[tokenId].usdcAmount;
        delete _positions[tokenId];
        delete _owners[tokenId];
        _balances[owner]--;
        _removeToken(tokenId);
        emit PositionFilled(tokenId, owner, usdcAmount, msg.sender);
    }

    function getPosition(uint256 tokenId) external view returns (Position memory) {
        require(_positions[tokenId].user != address(0), "PositionNotFound");
        return _positions[tokenId];
    }

    function getUsdcAmount(uint256 tokenId) external view returns (uint256) {
        require(_positions[tokenId].user != address(0), "PositionNotFound");
        return _positions[tokenId].usdcAmount;
    }

    function positionExists(uint256 tokenId) external view returns (bool) {
        return _positions[tokenId].user != address(0);
    }

    function getOriginalUser(uint256 tokenId) external view returns (address) {
        require(_positions[tokenId].user != address(0), "PositionNotFound");
        return _positions[tokenId].user;
    }

    function getPositions(uint256[] memory tokenIds) external view returns (Position[] memory positions) {
        positions = new Position[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(_positions[tokenIds[i]].user != address(0), "PositionNotFound");
            positions[i] = _positions[tokenIds[i]];
        }
    }

    function lastBurnedTokenId() external view returns (uint256) {
        return _lastBurnedTokenId;
    }

    function nextTokenId() external view returns (uint256) {
        return _tokenIdCounter + 1;
    }

    function getPendingRange() external view returns (uint256 startTokenId, uint256 endTokenId) {
        startTokenId = _lastBurnedTokenId + 1;
        endTokenId = _tokenIdCounter > 0 ? _tokenIdCounter : 0;
    }

    function getTokensByIndexes(uint256[] memory) external pure returns (uint256[] memory) {
        revert("Not implemented");
    }

    function totalSupply() external view returns (uint256) {
        return _allTokens.length;
    }

    function tokenByIndex(uint256 index) external view returns (uint256) {
        return _allTokens[index];
    }

    function tokenOfOwnerByIndex(address, uint256) external pure returns (uint256) {
        revert("Not implemented");
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        require(_owners[tokenId] != address(0), "ERC721: invalid token ID");
        return _owners[tokenId];
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _balances[owner];
    }

    function approve(address, uint256) external pure {
        revert("Not implemented");
    }

    function getApproved(uint256) external pure returns (address) {
        revert("Not implemented");
    }

    function setApprovalForAll(address, bool) external pure {
        revert("Not implemented");
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        revert("Not implemented");
    }

    function transferFrom(address, address, uint256) external pure {
        revert("Not implemented");
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert("Not implemented");
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert("Not implemented");
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC721).interfaceId || interfaceId == type(IERC721Enumerable).interfaceId
            || interfaceId == type(IWithdrawalNFT).interfaceId;
    }

    function _removeToken(uint256 tokenId) private {
        uint256 index = _tokenIndex[tokenId];
        uint256 lastIndex = _allTokens.length - 1;
        if (index != lastIndex) {
            uint256 lastTokenId = _allTokens[lastIndex];
            _allTokens[index] = lastTokenId;
            _tokenIndex[lastTokenId] = index;
        }
        _allTokens.pop();
        delete _tokenIndex[tokenId];
    }
}
