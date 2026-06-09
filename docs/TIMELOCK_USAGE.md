# Timelock Controller Usage Guide

This guide explains how to use `dreTimelockController` to secure administrative operations in the dreUSD system.

## Overview

The `dreTimelockController` adds a delay between when an operation is proposed and when it can be executed. This gives users time to review and react to administrative changes.

## Deployment

### Step 1: Deploy the Timelock

```solidity
// Example deployment script
import {dreTimelockController} from "./contracts/governance/dreTimelockController.sol";

function deployTimelock() public returns (address) {
    uint256 minDelay = 48 hours; // or 2 * 86400 seconds
    
    // Proposers: addresses that can schedule operations (e.g., multisig, DAO)
    address[] memory proposers = new address[](1);
    proposers[0] = 0xYourMultisigAddress;
    
    // Executors: addresses that can execute operations (can be same as proposers)
    address[] memory executors = new address[](1);
    executors[0] = 0xYourMultisigAddress;
    
    dreTimelockController timelock = new dreTimelockController(
        minDelay,
        proposers,
        executors
    );
    
    return address(timelock);
}
```

### Step 2: Transfer Admin Roles to Timelock

After deploying, transfer administrative control to the timelock:

```solidity
// Example: Transfer DEFAULT_ADMIN_ROLE to timelock
dreUSDManager manager = dreUSDManager(Config.MANAGER);
manager.grantRole(DEFAULT_ADMIN_ROLE, address(timelock));
manager.revokeRole(DEFAULT_ADMIN_ROLE, deployerAddress);

// Repeat for other contracts that need timelock protection:
// - dreUSDOracle
// - dreUSDs
// - dreWithdrawalNFT
// - etc.
```

## Workflow: Scheduling and Executing Operations

### Basic Workflow

1. **Propose**: A proposer schedules an operation
2. **Wait**: Wait for `minDelay` to pass
3. **Execute**: An executor executes the operation

### Example 1: Updating Vault Address

```solidity
// Step 1: Schedule the operation
address newVault = 0xNewVaultAddress;
bytes memory data = abi.encodeWithSelector(
    dreUSDManager.updateVault.selector,
    newVault
);

timelock.schedule(
    address(manager),           // target contract
    0,                          // value (ETH)
    data,                       // encoded function call
    bytes32(0),                 // predecessor (0 = no dependency)
    bytes32(0),                 // salt (0 = unique operation)
    timelock.getMinDelay()      // delay (must be >= minDelay)
);

// Step 2: Wait for minDelay (e.g., 48 hours)
// Monitor with: timelock.getTimestamp(operationId)

// Step 3: Execute after delay has passed
bytes32 operationId = timelock.hashOperation(
    address(manager),
    0,
    data,
    bytes32(0),
    bytes32(0)
);

require(timelock.isOperationReady(operationId), "Not ready yet");
timelock.execute(
    address(manager),
    0,
    data,
    bytes32(0),
    bytes32(0)
);
```

### Example 2: Batch Operations (Multiple Changes)

```solidity
address[] memory targets = new address[](2);
uint256[] memory values = new uint256[](2);
bytes[] memory payloads = new bytes[](2);

// Operation 1: Update vault
targets[0] = address(manager);
values[0] = 0;
payloads[0] = abi.encodeWithSelector(
    dreUSDManager.updateVault.selector,
    newVault
);

// Operation 2: Update daily mint cap
targets[1] = address(manager);
values[1] = 0;
payloads[1] = abi.encodeWithSelector(
    dreUSDManager.setDailyFiatMintCap.selector,
    20_000_000e2
);

// Schedule batch
timelock.scheduleBatch(
    targets,
    values,
    payloads,
    bytes32(0),                 // predecessor
    bytes32(0),                 // salt
    timelock.getMinDelay()      // delay
);

// Execute batch (after delay)
bytes32 operationId = timelock.hashOperationBatch(
    targets,
    values,
    payloads,
    bytes32(0),
    bytes32(0)
);

require(timelock.isOperationReady(operationId), "Not ready yet");
timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));
```

### Example 3: Dependent Operations (Sequential)

```solidity
// Operation 1: Update vault adapter
bytes memory data1 = abi.encodeWithSelector(
    dreUSDManager.updateVaultAdapter.selector,
    newAdapter
);
bytes32 op1Id = timelock.hashOperation(
    address(manager), 0, data1, bytes32(0), bytes32(0)
);
timelock.schedule(
    address(manager), 0, data1, bytes32(0), bytes32(0), timelock.getMinDelay()
);

// Operation 2: Update vault (depends on op1 completing first)
bytes memory data2 = abi.encodeWithSelector(
    dreUSDManager.updateVault.selector,
    newVault
);
timelock.schedule(
    address(manager), 0, data2, op1Id, bytes32(0), timelock.getMinDelay()
);

// Execute op1 first
timelock.execute(address(manager), 0, data1, bytes32(0), bytes32(0));

// Then execute op2 (only after op1 is done)
timelock.execute(address(manager), 0, data2, op1Id, bytes32(0));
```

## Common Operations for dreUSD System

### Updating Manager Configuration

```solidity
// Update vault
function scheduleUpdateVault(address newVault) external {
    bytes memory data = abi.encodeWithSelector(
        dreUSDManager.updateVault.selector,
        newVault
    );
    timelock.schedule(
        address(manager), 0, data, bytes32(0), bytes32(0), timelock.getMinDelay()
    );
}

// Update daily mint cap
function scheduleSetDailyMintCap(uint256 newCap) external {
    bytes memory data = abi.encodeWithSelector(
        dreUSDManager.setDailyFiatMintCap.selector,
        newCap
    );
    timelock.schedule(
        address(manager), 0, data, bytes32(0), bytes32(0), timelock.getMinDelay()
    );
}

// Update express withdrawal config
function scheduleUpdateExpressWithdrawal(
    address nft,
    uint256 maxLimit,
    uint256 feeBps,
    address feeRecipient
) external {
    bytes memory data = abi.encodeWithSelector(
        dreUSDManager.updateExpressWithdrawal.selector,
        nft,
        maxLimit,
        feeBps,
        feeRecipient
    );
    timelock.schedule(
        address(manager), 0, data, bytes32(0), bytes32(0), timelock.getMinDelay()
    );
}
```

### Granting/Revoking Roles

```solidity
// Grant role to new address
function scheduleGrantRole(bytes32 role, address account) external {
    bytes memory data = abi.encodeWithSelector(
        AccessControl.grantRole.selector,
        role,
        account
    );
    timelock.schedule(
        address(manager), 0, data, bytes32(0), bytes32(0), timelock.getMinDelay()
    );
}
```

### Updating Oracle

```solidity
// Set oracle feed
function scheduleSetOracle(
    address token,
    address feed,
    uint256 stalenessThreshold
) external {
    bytes memory data = abi.encodeWithSelector(
        dreUSDOracle.setOracle.selector,
        token,
        feed,
        stalenessThreshold
    );
    timelock.schedule(
        address(oracle), 0, data, bytes32(0), bytes32(0), timelock.getMinDelay()
    );
}
```

## Checking Operation Status

```solidity
// Get operation ID
bytes32 opId = timelock.hashOperation(target, value, data, predecessor, salt);

// Check if operation exists
bool exists = timelock.isOperation(opId);

// Check if operation is pending (waiting or ready)
bool pending = timelock.isOperationPending(opId);

// Check if operation is ready to execute
bool ready = timelock.isOperationReady(opId);

// Check if operation is done
bool done = timelock.isOperationDone(opId);

// Get timestamp when operation becomes ready
uint256 timestamp = timelock.getTimestamp(opId);

// Get operation state
TimelockController.OperationState state = timelock.getOperationState(opId);
// Returns: Unset, Waiting, Ready, or Done
```

## Canceling Operations

Only addresses with `CANCELLER_ROLE` can cancel pending operations:

```solidity
bytes32 opId = timelock.hashOperation(target, value, data, predecessor, salt);
timelock.cancel(opId);
```

## Best Practices

1. **Use Multisig/DAO as Proposers**: Don't use a single EOA as proposer
2. **Separate Proposers and Executors**: Can be the same, but separation adds security
3. **Monitor Operations**: Set up monitoring for scheduled operations
4. **Document Changes**: Keep track of what operations are scheduled and why
5. **Test First**: Test operations on testnet before mainnet
6. **Use Batch Operations**: Group related changes together for atomic execution
7. **Set Appropriate Delays**: Balance security (longer delay) vs. agility (shorter delay)

## Integration with Existing System

### Recommended Setup

1. Deploy `dreTimelockController` with 48-hour delay
2. Transfer `DEFAULT_ADMIN_ROLE` from deployer to timelock for:
   - `dreUSDManager`
   - `dreUSDOracle`
   - `dreUSDs`
   - `dreWithdrawalNFT` (both instances)
   - Other upgradeable contracts
3. Keep deployer as proposer/executor initially, then transfer to multisig/DAO
4. All future admin operations go through timelock

### Example Integration Script

```solidity
// After deploying timelock
function setupTimelock(dreTimelockController timelock) external {
    // Transfer admin roles to timelock
    dreUSDManager(Config.MANAGER).grantRole(
        DEFAULT_ADMIN_ROLE,
        address(timelock)
    );
    
    dreUSDOracle(Config.ORACLE_ADDRESS).grantRole(
        DEFAULT_ADMIN_ROLE,
        address(timelock)
    );
    
    // Grant necessary roles to timelock for operations
    // (e.g., if timelock needs to call functions that require specific roles)
    
    // Revoke admin from deployer
    dreUSDManager(Config.MANAGER).revokeRole(
        DEFAULT_ADMIN_ROLE,
        msg.sender
    );
}
```

## Security Considerations

- **No Admin**: Timelock is self-administered (admin = address(0)), so role changes must go through timelock
- **Minimum Delay**: Cannot schedule operations with delay less than `minDelay`
- **Predecessor Dependencies**: Operations can depend on others completing first
- **Cancellation**: Only pending operations can be canceled (not ready/done)
- **Reentrancy**: Timelock handles reentrancy internally

## Troubleshooting

**Operation not ready?**
- Check `getTimestamp(opId)` - must be <= `block.timestamp`
- Ensure predecessor operations are done (if any)

**Can't schedule operation?**
- Check caller has `PROPOSER_ROLE`
- Ensure delay >= `getMinDelay()`
- Operation must not already exist

**Can't execute operation?**
- Check caller has `EXECUTOR_ROLE` (or executor role is open to all)
- Operation must be in `Ready` state
- Predecessor must be done (if specified)
