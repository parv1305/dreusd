// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title ERC4626Mock
 * @dev Simple ERC4626 mock for testing
 */
contract ERC4626Mock is IERC4626 {
    string public name;
    string public symbol;
    uint8 public decimals;

    /// @notice For manager tests: rewards distributor address (manager reads from vault).
    address public rewardsDistributor;

    IERC20 private _asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    constructor(address __asset) {
        name = "MockVault";
        symbol = "MV";
        decimals = 18;
        _asset = IERC20(__asset);
    }

    function setRewardsDistributor(address _rewardsDistributor) external {
        rewardsDistributor = _rewardsDistributor;
    }

    function asset() external view returns (address) {
        return address(_asset);
    }
    
    function deposit(uint256 assets, address receiver) external returns (uint256) {
        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        uint256 shares = assets; // 1:1 for simplicity
        balanceOf[receiver] += shares;
        totalSupply += shares;
        emit Transfer(address(0), receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }
    
    function mint(uint256 shares, address receiver) external returns (uint256) {
        uint256 assets = shares; // 1:1
        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        balanceOf[receiver] += shares;
        totalSupply += shares;
        emit Transfer(address(0), receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return assets;
    }
    
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256) {
        uint256 shares = assets; // 1:1
        if (msg.sender != owner) {
            allowance[owner][msg.sender] -= shares;
        }
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        IERC20(_asset).transfer(receiver, assets);
        emit Transfer(owner, address(0), shares);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }
    
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        uint256 assets = shares; // 1:1
        if (msg.sender != owner) {
            allowance[owner][msg.sender] -= shares;
        }
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        IERC20(_asset).transfer(receiver, assets);
        emit Transfer(owner, address(0), shares);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }
    
    function totalAssets() external view returns (uint256) {
        return IERC20(_asset).balanceOf(address(this));
    }
    
    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets; // 1:1
    }
    
    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares; // 1:1
    }
    
    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }
    
    function maxMint(address) external pure returns (uint256) {
        return type(uint256).max;
    }
    
    function maxWithdraw(address owner) external view returns (uint256) {
        return balanceOf[owner];
    }
    
    function maxRedeem(address owner) external view returns (uint256) {
        return balanceOf[owner];
    }
    
    function previewDeposit(uint256 assets) external pure returns (uint256) {
        return assets;
    }
    
    function previewMint(uint256 shares) external pure returns (uint256) {
        return shares;
    }
    
    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets;
    }
    
    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
