// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IWithdrawalNFT} from "../interfaces/IWithdrawalNFT.sol";

/**
 * @title WithdrawalNFTMock
 * @dev Mock withdrawal NFT for testing
 */
contract WithdrawalNFTMock is IWithdrawalNFT, IERC721 {
    uint256 private _tokenIdCounter;
    uint256 private _lastBurnedTokenId;
    mapping(uint256 => Position) private _positions;
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    
    function mint(address to, uint256 usdcAmount) external returns (uint256 tokenId) {
        tokenId = ++_tokenIdCounter;
        _positions[tokenId] = Position({
            user: to,
            usdcAmount: usdcAmount,
            createdAt: block.timestamp
        });
        _owners[tokenId] = to;
        _balances[to]++;
        emit PositionCreated(tokenId, to, usdcAmount, block.timestamp);
        return tokenId;
    }
    
    function burn(uint256 tokenId) external {
        require(_positions[tokenId].user != address(0), "PositionNotFound");
        if (tokenId > _lastBurnedTokenId) _lastBurnedTokenId = tokenId;
        address owner = _owners[tokenId];
        uint256 usdcAmount = _positions[tokenId].usdcAmount;
        delete _positions[tokenId];
        delete _owners[tokenId];
        _balances[owner]--;
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

    function getPendingRange() external view returns (uint256 startTokenId, uint256 endTokenId) {
        startTokenId = _lastBurnedTokenId + 1;
        endTokenId = _tokenIdCounter > 0 ? _tokenIdCounter : 0;
    }

    function getTokensByIndexes(uint256[] memory) external pure returns (uint256[] memory) {
        revert("Not implemented");
    }

    // ERC721 functions
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
    
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}
