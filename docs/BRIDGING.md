# dreUSD Cross-Chain Bridging Guide

This guide explains how to send dreUSD tokens between chains using LayerZero.

## Prerequisites

Before bridging tokens, ensure:

1. ✅ **Contracts are deployed** on both source and destination chains
2. ✅ **LayerZero is configured** using `script/dreUSD/ConfigureDreUSD.s.sol` on both chains
3. ✅ **You have dreUSD tokens** on the source chain
4. ✅ **You have native tokens** (ETH/ETH) on the source chain to pay for gas and LayerZero fees

## Quick Reference

- **Ethereum Sepolia EID**: `40161`
- **Base Sepolia EID**: `40245`
- **dreUSD Proxy Address**: `0xC4efF8FBC00063cAe77A950E0cF3e3ca6f59B7e6` (same on all chains)

## Required Environment Variables

Before sending tokens, set the following environment variable:

- `PRIVATE_KEY` - Private key of the sender account (must have dreUSD tokens and native tokens for gas)

### Example Setup

```bash
export PRIVATE_KEY=your_private_key_here
```

## Configuring Send Parameters

The recipient address, amount, and destination chain ID are configured directly in the script file. Edit `script/dreUSD/SendDreUSD.s.sol` and update the following values:

- **Line 27**: `address recipient` - Set the recipient address on the destination chain
- **Line 28**: `uint256 amount` - Set the amount to send in wei (e.g., `100000000000000000000` for 100 tokens with 18 decimals)
- **Line 29**: `uint256 chainId` - Set the destination chain ID (e.g., `84532` for Base Sepolia, `11155111` for Ethereum Sepolia)

### Example Configuration

```solidity
address recipient = 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb;
uint256 amount = 100000000000000000000; // 100 tokens in wei
uint256 chainId = 84532; // Base Sepolia
```

## Step-by-Step: Sending Tokens

### Step 1: Get a Quote for the Fee

First, you need to get a quote for the LayerZero messaging fee. This tells you how much native token you need to send with the transaction.

#### Using Foundry Cast

```bash
# Get quote for sending 100 dreUSD from Ethereum Sepolia to Base Sepolia
cast call 0xC4efF8FBC00063cAe77A950E0cF3e3ca6f59B7e6 \
  "quoteSend((uint32,bytes32,uint256,uint256,bytes,bytes,bytes),bool)" \
  "(40245,0x000000000000000000000000YOUR_RECIPIENT_ADDRESS,100000000000000000000,100000000000000000000,0x,0x,0x),false" \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
```

**Parameters explained:**
- `40245`: Destination EID (Base Sepolia)
- `0x000000000000000000000000YOUR_RECIPIENT_ADDRESS`: Recipient address as bytes32 (pad with zeros)
- `100000000000000000000`: Amount in wei (100 tokens with 18 decimals)
- `100000000000000000000`: Minimum amount (same as amount for no slippage)
- `0x`: Empty extra options (uses enforced options from config)
- `0x`: Empty compose message
- `0x`: Empty OFT command
- `false`: Pay in native token (not LZ token)

**Note**: The quote returns two values: `nativeFee` and `lzTokenFee`. You'll need the `nativeFee` value.

### Step 2: Send Tokens

Once you have the fee quote, you can send the tokens using the deployment script.

#### Using the Send Script (Recommended)

**Step 1: Configure the Script**

Edit `script/dreUSD/SendDreUSD.s.sol` and update the values:
- `recipient` (line 27) - Recipient address
- `amount` (line 28) - Amount in wei
- `chainId` (line 29) - Destination chain ID

**Step 2: Set Environment Variable**

```bash
export PRIVATE_KEY=your_private_key_here
```

**Step 3: Run the Script**

```bash
forge script script/dreUSD/SendDreUSD.s.sol \
  --rpc-url <YOUR_RPC_URL> \
  --broadcast
```

**Full Example:**
```bash
# 1. Edit script/dreUSD/SendDreUSD.s.sol with your values:
#    - recipient = 0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb
#    - amount = 100000000000000000000  # 100 tokens
#    - chainId = 84532  # Base Sepolia

# 2. Set private key
export PRIVATE_KEY=your_private_key_here

# 3. Send tokens
forge script script/dreUSD/SendDreUSD.s.sol \
  --rpc-url https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY \
  --broadcast
```

**Note**: The script will automatically:
- Get the fee quote
- Check your token balance
- Send the tokens cross-chain
- Display the transaction GUID for tracking

## Address Conversion

When sending, the recipient address must be converted to `bytes32`. Here's how:

```solidity
// In Solidity
bytes32 recipientBytes32 = bytes32(uint256(uint160(recipientAddress)));

// Using cast
cast --to-bytes32 $(cast --to-checksum-address 0xYourAddress)
```

## Important Notes

1. **Token Balance**: Make sure you have enough dreUSD tokens on the source chain
2. **Native Token Balance**: You need native tokens (ETH) to pay for:
   - Gas fees for the transaction
   - LayerZero messaging fees (returned by `quoteSend`)
3. **Minimum Amount**: Set `minAmountLD` to protect against slippage. For no slippage, set it equal to `amountLD`
4. **Refund Address**: Any excess native tokens sent will be refunded to the `refundAddress`
5. **Delivery Time**: Cross-chain messages typically take a few minutes to be delivered, depending on the destination chain's finality

## Verifying the Transfer

After sending, you can verify the transfer in multiple ways:

### 1. Check Transaction on Source Chain Explorer

1. **Find the transaction hash** from the script output or your wallet
2. **View the transaction** on the source chain explorer (e.g., Etherscan for Ethereum Sepolia)
3. **Look for the `OFTSent` event** in the transaction logs
4. **Note the GUID** - This is the unique identifier for the cross-chain message

### 2. Check LayerZero Dashboard

The LayerZero dashboard (LayerZeroScan) is the best way to track cross-chain message delivery.

#### Accessing the Dashboard

1. **Open LayerZeroScan**: Navigate to [https://layerzeroscan.com/](https://layerzeroscan.com/)

2. **Search by Transaction Hash**:
   - Enter the source chain transaction hash in the search bar
   - The dashboard will show the message details including:
     - Source and destination chains
     - Message status (Pending, Delivered, Failed)
     - GUID (Global Unique Identifier)
     - Amount being transferred
     - Timestamps

3. **Search by GUID** (if you have it from the script output):
   - Enter the GUID in the search bar
   - View the complete message lifecycle

#### Understanding the Dashboard

The LayerZero dashboard shows:
- **Status**: 
  - 🟡 **Pending**: Message is queued and waiting for delivery
  - 🟢 **Delivered**: Message successfully delivered to destination chain
  - 🔴 **Failed**: Message delivery failed (check error details)
- **Source Chain**: The chain where the transaction originated
- **Destination Chain**: The chain where tokens will be received
- **Amount**: The amount of tokens being transferred
- **GUID**: Unique identifier for tracking this specific message
- **Transaction Links**: Direct links to both source and destination transactions

#### Monitoring Delivery

1. **Wait for delivery** (usually 1-5 minutes depending on chain finality)
2. **Refresh the dashboard** to see status updates
3. **Click on destination transaction** link when status changes to "Delivered"
4. **Verify the `OFTReceived` event** on the destination chain transaction

### 3. Check Destination Chain

1. **Check the recipient's balance** on the destination chain explorer
2. **Look for the destination transaction** (linked from LayerZero dashboard)
3. **Verify the `OFTReceived` event** in the destination transaction logs
4. **Confirm tokens arrived** in the recipient's wallet

## Troubleshooting

### "Insufficient balance"
- Ensure you have enough dreUSD tokens
- Ensure you have enough native tokens for gas + LayerZero fees

### "NoPeer" error
- The LayerZero configuration might not be complete
- Run `script/dreUSD/ConfigureDreUSD.s.sol` on both chains

### "SlippageExceeded" error
- The `minAmountLD` is too high
- Reduce `minAmountLD` or check if there are fees being deducted

### Tokens not arriving
- Check the transaction on the source chain
- Verify the recipient address is correct
- Check LayerZero explorer for message status
- Ensure the destination chain configuration is correct


## Additional Resources

- [LayerZero V2 Documentation](https://docs.layerzero.network/v2/developers/evm/oapp)
- [OFT Documentation](https://docs.layerzero.network/v2/developers/evm/oft)
- [LayerZero Explorer](https://layerzeroscan.com/) - Track cross-chain messages
