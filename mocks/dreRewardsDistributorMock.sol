// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IdreRewardsDistributor} from "../interfaces/IdreRewardsDistributor.sol";

/**
 * @title dreRewardsDistributorMock
 * @dev Mock contract for testing dreUSDs integration with dreRewardsDistributor
 */
contract dreRewardsDistributorMock is IdreRewardsDistributor {
    address public dreUSD;
    address public vault;
    uint256 public constant VEST_PERIOD = 7 days;
    uint256 public cTs;
    uint256 public eTs;
    uint256 public rewards;
    uint256 public vestedAmountToReturn;
    uint256 public claimAmountToReturn;
    bool public shouldRevertClaim;
    bool public addRewardsCalled;
    uint256 public addRewardsCallCount;
    bool public paused;

    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");

    constructor(address _dreUSD, address _vault) {
        dreUSD = _dreUSD;
        vault = _vault;
        cTs = block.timestamp;
        eTs = block.timestamp + 7 days;
    }
    
    function setVestedAmount(uint256 _amount) external {
        vestedAmountToReturn = _amount;
    }
    
    function setClaimAmount(uint256 _amount) external {
        claimAmountToReturn = _amount;
    }
    
    function setShouldRevertClaim(bool _shouldRevert) external {
        shouldRevertClaim = _shouldRevert;
    }
    
    function setPaused(bool _paused) external {
        paused = _paused;
    }
    
    function vestedAmount() external view returns (uint256) {
        return vestedAmountToReturn;
    }

    function claimVested() external returns (uint256) {
        if (shouldRevertClaim) {
            revert("Mock revert");
        }
        if (claimAmountToReturn > 0) {
            IERC20(dreUSD).transfer(vault, claimAmountToReturn);
        }
        return claimAmountToReturn;
    }

    function addRewards() external {
        addRewardsCalled = true;
        addRewardsCallCount++;
    }
}
