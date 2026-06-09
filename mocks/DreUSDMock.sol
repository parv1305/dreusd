// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IdreUSD} from "../interfaces/IdreUSD.sol";
import {ISanctionsList} from "../interfaces/ISanctionsList.sol";

/**
 * @title DreUSDMock
 * @dev Mock dreUSD token for testing
 */
contract DreUSDMock is IERC20, IERC20Metadata, IdreUSD {
    string public name;
    string public symbol;
    uint8 public decimals;
    
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    address public manager;
    address public sanctionsList;
    mapping(address => bool) public frozen;
    
    constructor() {
        name = "dreUSD";
        symbol = "dreUSD";
        decimals = 18;
    }
    
    /// @dev Mock: grant MANAGER_ROLE sets manager for mint/burn
    function grantRole(bytes32 role, address account) external {
        if (role == MANAGER_ROLE) manager = account;
    }
    
    function setSanctionsList(address _sanctionsList) external {
        sanctionsList = _sanctionsList;
    }
    
    function freeze(address account) external {
        frozen[account] = true;
    }
    
    function unfreeze(address account) external {
        frozen[account] = false;
    }
    
    function mint(address to, uint256 amount) external {
        require(msg.sender == manager, "OnlyManager");
        require(!frozen[to], "FrozenAddress");
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
    
    function burn(address from, uint256 amount) external {
        require(msg.sender == manager, "OnlyManager");
        require(!frozen[from], "FrozenAddress");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        require(!frozen[msg.sender], "FrozenAddress");
        require(!frozen[to], "FrozenAddress");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(!frozen[from], "FrozenAddress");
        require(!frozen[to], "FrozenAddress");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function validateAddress(address account) external view {
        if (frozen[account]) {
            revert FrozenAddress(account);
        }
        if (sanctionsList != address(0) && ISanctionsList(sanctionsList).isSanctioned(account)) {
            revert SanctionedAddress(account);
        }
    }

    function isBlockedAddress(address account) external view returns (bool) {
        if (frozen[account]) return true;
        if (sanctionsList != address(0) && ISanctionsList(sanctionsList).isSanctioned(account)) return true;
        return false;
    }
}
