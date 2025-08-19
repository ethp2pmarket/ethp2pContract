# Gift Card Marketplace

A decentralized P2P marketplace for trading gift cards with escrow and dispute resolution built on Arbitrum using Solidity and Foundry.

## Overview

This marketplace provides a **trustless trading environment** where users can safely exchange gift cards using an escrow system with staking-based arbitration for dispute resolution.

### Key Participants

- **Sellers**: Create and manage gift card orders
- **Buyers**: Purchase gift cards with automatic escrow protection
- **Arbitrators**: Stake tokens to resolve disputes and earn rewards
- **Platform**: Collects commission fees and manages the ecosystem

## Features

### 🔒 **Escrow & Security System**

- **Automatic Escrow**: Funds are held securely in the contract until delivery is confirmed
- **Delivery Confirmation**: Buyers can confirm delivery for immediate fund release
- **Automatic Release**: Funds auto-release to sellers after timeout (default: 7 days) if no disputes
- **Dispute Window**: Buyers can raise disputes within the escrow period
- **Economic Security**: Arbitrator staking ensures honest dispute resolution

### ⚖️ **Dispute Resolution System**

- **Staking-Based Arbitration**: Arbitrators must stake tokens to participate
- **Stake-Weighted Selection**: Higher stake = higher chance of being selected
- **Economic Incentives**: Arbitrators earn rewards for correct decisions, get slashed for wrong ones
- **Performance Tracking**: Track arbitrator success rates and decision history
- **Challenge Mechanism**: Governance can challenge incorrect arbitrator decisions

### 📊 **Advanced Order Management**

- **Complete Lifecycle**: Active → Escrowed → Completed/Disputed → Resolved
- **Order Editing**: Sellers can modify active orders (type, description, price)
- **Status Tracking**: Real-time order status with comprehensive state management
- **Batch Operations**: Efficient pagination for large datasets

### ⭐ **Review & Reputation System**

- **Precise Ratings**: 10-50 scale providing 0.1 precision (1.0-5.0 stars)
- **Seller Credibility**: Aggregate ratings and review counts
- **One Review Per Order**: Prevents review manipulation
- **Detailed Feedback**: Text comments with star ratings

### 🛡️ **Security & Access Control**

- **Reentrancy Protection**: Comprehensive protection against reentrancy attacks
- **Emergency Controls**: Pause functionality
- **Time-based Security**: Dispute windows and unstaking delays
- **Comprehensive Validation**: Input validation with custom error messages

## Smart Contracts

### 1. GiftCardMarketplace.sol

The main marketplace contract implementing:

- **Escrow Management**: Secure fund holding with automatic release
- **Dispute Resolution**: Complete arbitration system with economic incentives
- **Arbitrator Staking**: Stake management, rewards, and slashing
- **Order Lifecycle**: Full state management from creation to completion
- **Gas Optimization**: Efficient data structures and pagination

### 2. IGiftCardMarketplace.sol

Comprehensive interface defining all marketplace functionality.

### 3. MockUSDC.sol

Test settlement token implementation for development and testing.

## Contract Architecture

```
GiftCardMarketplace
├── 📋 Order Management
│   ├── createOrder() - Create new orders with unique IDs
│   ├── editOrder() - Modify active orders
│   ├── delistOrder() - Cancel active orders
│   └── matchOrder() - Purchase with automatic escrow
├── 🔒 Escrow System
│   ├── confirmDelivery() - Immediate fund release
│   ├── releaseEscrowAfterTimeout() - Automatic release
│   ├── raiseDispute() - Initiate dispute resolution
│   └── resolveDispute() - Arbitrator decision
├── ⚖️ Arbitrator Management
│   ├── stakeAsArbitrator() - Stake tokens to become arbitrator
│   ├── unstakeAsArbitrator() - Withdraw stake with delay
│   ├── challengeArbitratorDecision() - Governance challenge with state reversal
│   ├── reassignStaleDispute() - Reassign unresponsive arbitrators
│   ├── forceResolveStaleDispute() - Emergency dispute resolution
│   └── Automatic Selection - Stake-weighted arbitrator assignment
├── ⭐ Review System
│   ├── submitReview() - Rate completed transactions
│   ├── getSellerCredit() - Aggregate seller ratings
│   └── getSellerReviews() - Paginated review retrieval
├── 📊 View Functions
│   ├── Order Queries - Comprehensive order information
│   ├── Dispute Queries - Dispute status and details
│   ├── Arbitrator Queries - Staking info and statistics
│   └── Pagination Support - Efficient data retrieval
├── 🛠️ Admin Functions
│   ├── Fee Management - Commission and parameter updates
│   ├── Emergency Controls - Pause and recovery functions
│   └── Governance - Challenge and parameter adjustments
└── 🛡️ Security
    ├── ReentrancyGuard - Attack prevention
    ├── Pausable - Emergency pause mechanism
    ├── Ownable - Access control
    └── SafeERC20 - Secure token operations
```

## Data Structures

### Order Structure

```solidity
struct Order {
    bytes32 orderId;              // Unique identifier
    address seller;               // Seller's address
    address buyer;                // Buyer's address (set when matched)
    string orderType;             // Gift card type (e.g., "Amazon", "Walmart")
    string description;           // Gift card description
    uint256 price;               // Price in USDC (6 decimals)
    OrderStatus status;           // Current order status
    uint256 createdAt;           // Creation timestamp
    uint256 updatedAt;           // Last update timestamp
    uint256 escrowReleaseTime;   // Auto-release timestamp
    bool deliveryConfirmed;      // Buyer confirmed delivery
    DisputeStatus disputeStatus; // Current dispute status
}
```

### Order Status Lifecycle

```solidity
enum OrderStatus {
    Active,     // 0: Available for purchase
    Escrowed,   // 1: Funds held in escrow
    Disputed,   // 2: Buyer raised dispute
    Completed,  // 3: Successful transaction
    Cancelled,  // 4: Seller cancelled
    Refunded,   // 5: Dispute resolved in buyer's favor
    Expired     // 6: Reserved for future features
}

enum DisputeStatus {
    None,           // 0: No dispute
    Raised,         // 1: Dispute raised by buyer
    InArbitration,  // 2: Arbitrator assigned
    Resolved        // 3: Dispute resolved
}
```

### Arbitrator Structure

```solidity
struct ArbitratorStake {
    uint256 stakedAmount;     // Total staked tokens
    uint256 lockedAmount;     // Amount locked in active disputes
    uint256 totalRewards;     // Total rewards earned
    uint256 totalSlashed;     // Total amount slashed
    uint256 correctDecisions; // Number of correct decisions
    uint256 totalDecisions;   // Total decisions made
    uint256 stakingTime;      // When staking began
    bool isActive;            // Whether arbitrator is active
}
```

### Dispute Structure

```solidity
struct Dispute {
    bytes32 orderId;      // Associated order ID
    address buyer;        // Buyer who raised dispute
    address seller;       // Order seller
    address arbitrator;   // Assigned arbitrator
    string reason;        // Dispute reason
    DisputeStatus status; // Current dispute status
    uint256 raisedAt;    // When dispute was raised
    uint256 resolvedAt;  // When dispute was resolved
    bool buyerWins;      // Resolution outcome
}
```

## Usage Flow

### For Sellers

1. **Create Order**

```solidity
marketplace.createOrder("Amazon", "Amazon Gift Card $100", 95000000); // 95 USDC
```

2. **Edit Order** (if needed)

```solidity
marketplace.editOrder(orderId, "Walmart", "Updated description", 90000000);
```

3. **Delist Order**

```solidity
marketplace.delistOrder(orderId);
```

### For Buyers

1. **Approve USDC Spending**

```solidity
usdc.approve(marketplaceAddress, orderPrice);
```

2. **Match Order** (enters escrow)

```solidity
marketplace.matchOrder(orderId);
```

3. **Confirm Delivery** (after receiving gift card)

```solidity
marketplace.confirmDelivery(orderId); // Releases funds immediately
```

4. **Raise Dispute** (if issues occur)

```solidity
marketplace.raiseDispute(orderId, "Gift card code doesn't work");
```

5. **Submit Review** (after completion)

```solidity
marketplace.submitReview(orderId, 50, "Excellent service!"); // 5.0 stars
```

### For Arbitrators

1. **Stake Tokens**

```solidity
stakingToken.approve(marketplaceAddress, stakeAmount);
marketplace.stakeAsArbitrator(1000000000); // 1000 USDC minimum
```

2. **Resolve Disputes** (when assigned)

```solidity
marketplace.resolveDispute(orderId, false, "Evidence shows gift card is valid");
// false = seller wins, true = buyer wins (refund)
```

3. **Unstake** (after delay period)

```solidity
marketplace.unstakeAsArbitrator(amount); // 7-day delay required
```

### For Platform Owners

1. **Update Parameters**

```solidity
marketplace.updateCommissionFee(200); // 2%
marketplace.updateMinimumStake(2000000000); // 2000 USDC
marketplace.updateArbitratorReward(150); // 1.5%
```

2. **Emergency Controls**

```solidity
marketplace.pause(); // Pause all operations
marketplace.challengeArbitratorDecision(orderId); // Challenge wrong decisions
```

## Economic Model

### Commission System

- **Default Fee**: 1% (100 basis points)
- **Maximum Fee**: 5% (500 basis points)  
- **Collection**: Automatically deducted from buyer's payment with overflow protection
- **Distribution**: Commission to platform, remainder to seller

### Arbitrator Economics

- **Minimum Stake**: 1000 staking tokens (configurable based on token decimals)
- **Selection Weight**: Proportional to available stake
- **Dispute Lock**: 5% of order value locked during disputes (with bounds checking)
- **Rewards**: 1% of disputed amount (configurable, max 10%) with overflow protection
- **Slashing**: 10% of stake for wrong decisions (configurable, max 50%) with bounds
- **Unstaking Delay**: 7 days to prevent exit during disputes
- **Timeout Protection**: 72-hour response window with reassignment capability

### Escrow Timing

- **Default Timeout**: 7 days (configurable, max 30 days)
- **Dispute Window**: Full escrow period with time remaining queries
- **Auto-release**: Funds automatically released to seller after timeout if no disputes
- **Arbitrator Timeout**: 72 hours default with reassignment capability

## Security Features

### Economic Security

- **Arbitrator Staking**: Economic incentives ensure honest behavior
- **Stake Slashing**: Financial penalties for incorrect decisions
- **Performance Tracking**: Reputation system for arbitrators
- **Challenge Mechanism**: Governance oversight of arbitrator decisions

### Technical Security

- **Reentrancy Protection**: CEI pattern implementation with address caching
- **Integer Overflow Protection**: Bounds checking in all mathematical operations
- **SafeERC20**: Secure token transfers with proper error handling
- **Input Validation**: Length limits and bounds checking on all user inputs
- **String Length Limits**: orderType ≤100, description ≤1000, reason ≤500, comment ≤1000
- **Price Bounds**: Maximum price limits to prevent overflow attacks
- **State Consistency**: Atomic status transitions preventing counter desynchronization
- **Time-based Restrictions**: Dispute windows, unstaking delays, and arbitrator timeouts
- **Emergency Controls**: Pause functionality and force resolution capabilities

### Access Control

- **Role-based Permissions**: Buyers, sellers, arbitrators, and admin roles
- **Owner Functions**: Administrative functions restricted to contract owner
- **Self-service**: Users can manage their own orders and stakes

## Installation & Setup

### Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- Node.js 16+ (for dependencies)

### 1. Clone Repository

```bash
git clone <repository-url>
cd marketplace
```

### 2. Install Dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts
```

### 3. Environment Setup

Create a `.env` file:

```env
PRIVATE_KEY=your_private_key_here
RPC_URL=your_rpc_url_here
```

### 4. Build Contracts

```bash
forge build
```

### 5. Run Tests

```bash
forge test
```

### 6. Deploy to Network

```bash
# Set environment variables
source .env

# Deploy to local network
forge script script/DeployMarketplace.s.sol --rpc-url $RPC_URL --broadcast

# Deploy to Arbitrum testnet/mainnet with verification
forge script script/DeployMarketplace.s.sol --rpc-url $RPC_URL --broadcast --verify

# Example Arbitrum RPC URLs:
# Arbitrum Sepolia: https://sepolia-rollup.arbitrum.io/rpc
# Arbitrum One: https://arb1.arbitrum.io/rpc
```

## Testing

The project includes comprehensive test coverage:

### Test Categories

- ✅ **Constructor & Setup** - Contract initialization and validation
- ✅ **Arbitrator Staking** - Staking, unstaking, and activation
- ✅ **Order Management** - Creation, editing, delisting, and matching
- ✅ **Escrow System** - Delivery confirmation and automatic release
- ✅ **Dispute Resolution** - Complete dispute lifecycle with arbitrators
- ✅ **Economic Incentives** - Rewards, slashing, and performance tracking
- ✅ **Gas Optimization** - Large-scale arbitrator selection efficiency
- ✅ **View Functions** - All query functions with pagination
- ✅ **Admin Functions** - Parameter updates and emergency controls
- ✅ **Edge Cases** - Error conditions and boundary testing

**Test Results**: 29 tests passing with comprehensive coverage including security vulnerability tests

### Run Tests

```bash
# Run all tests
forge test

# Run specific test
forge test --match-test test_RaiseDisputeAndResolve

# Run with verbose output
forge test -vvv

# Run with gas reporting
forge test --gas-report
```

## API Reference

### Core Functions

#### Order Management

- `createOrder(string orderType, string description, uint256 price)` - Create new order
- `editOrder(bytes32 orderId, string newOrderType, string newDescription, uint256 newPrice)` - Edit active order
- `delistOrder(bytes32 orderId)` - Cancel active order
- `matchOrder(bytes32 orderId)` - Purchase order (enters escrow)

#### Escrow & Delivery

- `confirmDelivery(bytes32 orderId)` - Confirm delivery (immediate release)
- `releaseEscrowAfterTimeout(bytes32 orderId)` - Release after timeout

#### Dispute Resolution

- `raiseDispute(bytes32 orderId, string reason)` - Raise dispute
- `resolveDispute(bytes32 orderId, bool buyerWins, string resolution)` - Arbitrator decision
- `challengeArbitratorDecision(bytes32 orderId)` - Owner challenge

#### Arbitrator Functions

- `stakeAsArbitrator(uint256 amount)` - Stake to become arbitrator
- `unstakeAsArbitrator(uint256 amount)` - Withdraw stake (with delay)

#### Review System

- `submitReview(bytes32 orderId, uint256 rating, string comment)` - Submit review (10-50 scale)

### View Functions

#### Order Queries

- `getOrder(bytes32 orderId)` - Get order details
- `getOrdersBySeller(address seller, uint256 offset, uint256 limit)` - Seller's orders
- `getActiveOrdersPaginated(uint256 offset, uint256 limit)` - Active orders
- `getOrdersByStatusPaginated(OrderStatus status, uint256 offset, uint256 limit)` - By status
- `getAllStatusCounts()` - Order counts by status

#### Dispute & Escrow

- `getDispute(bytes32 orderId)` - Dispute details
- `canRaiseDispute(bytes32 orderId)` - Check if dispute window open
- `canReleaseEscrow(bytes32 orderId)` - Check if releasable
- `getEscrowTimeRemaining(bytes32 orderId)` - Time until auto-release

#### Arbitrator Information

- `getActiveArbitratorsPaginated(uint256 offset, uint256 limit)` - Active arbitrators
- `getArbitratorStake(address arbitrator)` - Complete stake information
- `getArbitratorSuccessRate(address arbitrator)` - Success rate in basis points
- `getStakingStats()` - Global staking statistics
- `canArbitrateDispute(address arbitrator, uint256 requiredStake)` - Check eligibility

#### Review Queries

- `getSellerReviews(address seller, uint256 offset, uint256 limit)` - Seller reviews
- `getSellerCredit(address seller)` - Aggregate seller ratings
- `hasReviewed(bytes32 orderId, address reviewer)` - Check if reviewed

### Admin Functions

- `updateCommissionFee(uint16 newFeeBps)` - Update commission (100-500 BP)
- `setCommissionRecipient(address newRecipient)` - Set fee recipient
- `updateEscrowTimeout(uint256 newTimeout)` - Set escrow timeout
- `updateMinimumStake(uint256 newMinimumStake)` - Set minimum arbitrator stake
- `updateArbitratorReward(uint256 newRewardBps)` - Set arbitrator reward rate
- `updateSlashingRate(uint256 newSlashingBps)` - Set slashing percentage
- `pause()` / `unpause()` - Emergency controls

## Gas Optimization

The contract implements several gas optimization techniques:

### Efficient Data Structures

- **Status Counters**: O(1) lookup for order counts by status
- **Nested Mappings**: Efficient storage without large arrays
- **Pagination**: Prevents gas limit issues with large datasets

### Optimized Algorithms

- **Limited Arbitrator Checks**: Maximum 50 arbitrators checked per selection
- **Randomized Selection**: Efficient stake-weighted random selection
- **Assembly Usage**: Optimized array resizing for pagination results

### Gas-Efficient Patterns

- **Custom Errors**: More efficient than string error messages
- **Early Returns**: Gas savings through early validation
- **Batch Operations**: Efficient event emissions and state updates

## Events

### Order Events

- `OrderCreated(bytes32 indexed orderId, address indexed seller, string orderType, string description, uint256 price)`
- `OrderMatched(bytes32 indexed orderId, address indexed buyer, address indexed seller, uint256 price, uint256 releaseTime)`
- `OrderEdited(bytes32 indexed orderId, string orderType, string description, uint256 price)`
- `OrderDelisted(bytes32 indexed orderId, address indexed seller)`
- `DeliveryConfirmed(bytes32 indexed orderId, address indexed buyer)`
- `FundsReleased(bytes32 indexed orderId, address indexed recipient, uint256 amount, string reason)`

### Dispute Events

- `DisputeRaised(bytes32 indexed orderId, address indexed buyer, address indexed arbitrator, string reason)`
- `DisputeResolved(bytes32 indexed orderId, address indexed arbitrator, bool buyerWins, string resolution)`

### Arbitrator Events

- `ArbitratorStaked(address indexed arbitrator, uint256 amount, uint256 totalStake)`
- `ArbitratorUnstaked(address indexed arbitrator, uint256 amount, uint256 remainingStake)`
- `ArbitratorRewarded(address indexed arbitrator, uint256 reward, bytes32 indexed orderId)`
- `ArbitratorSlashed(address indexed arbitrator, uint256 slashed, bytes32 indexed orderId)`

### Admin Events

- `CommissionFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps)`
- `CommissionRecipientUpdated(address indexed oldRecipient, address indexed newRecipient)`
- `EscrowTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout)`
- `MinimumStakeUpdated(uint256 oldStake, uint256 newStake)`
- `ArbitratorRewardUpdated(uint256 oldRewardBps, uint256 newRewardBps)`
- `SlashingRateUpdated(uint256 oldSlashingBps, uint256 newSlashingBps)`
- `TokensRecovered(address indexed token, address indexed to, uint256 amount)`

### Review Events

- `ReviewSubmitted(bytes32 indexed orderId, address indexed reviewer, address indexed seller, uint256 rating, string comment)`

## Network Deployment

### Testnet Addresses

- **Arbitrum Sepolia**: [Contract Address TBD]
- **Arbitrum Goerli**: [Contract Address TBD]

### Mainnet Addresses

- **Arbitrum One**: [Contract Address TBD]

## Security Considerations

### For Users

- **Escrow Protection**: Funds are held securely until delivery or timeout
- **Dispute Resolution**: Fair arbitration system with economic incentives
- **Time Limits**: Be aware of dispute windows and escrow timeouts
- **Review System**: Reviews are tied to specific transactions

### For Arbitrators

- **Economic Risk**: Stake can be slashed for incorrect decisions
- **Time Commitment**: Stake has 7-day unstaking delay
- **Reputation**: Performance is tracked and affects future selection
- **Due Diligence**: Thoroughly investigate disputes before deciding

### For Developers

- **Battle-tested Libraries**: Uses OpenZeppelin's security-audited contracts
- **Comprehensive Testing**: Extensive test suite covering edge cases
- **Economic Security**: Arbitrator staking aligns incentives
- **Emergency Controls**: Admin functions for crisis management

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add comprehensive tests
5. Ensure all tests pass
6. Submit a pull request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

For questions or support:

- Create an issue in the repository
- Check the test files for usage examples
- Review the contract documentation

## Disclaimer

## Security Audit Status

✅ **Security Vulnerabilities Fixed** (v2.1):
- Reentrancy protection implemented using CEI pattern
- Integer overflow prevention in all financial calculations  
- State consistency maintained in challenge mechanism
- Comprehensive input validation and bounds checking
- Arbitrator liveness and timeout protection

## Disclaimer

This software is provided "as is" without warranty. A comprehensive security audit has been conducted and critical vulnerabilities have been addressed. However, users should conduct independent security reviews before using in production environments. The escrow and dispute resolution mechanisms involve economic risks for all participants.

## Changelog

### v2.0 - Current Version

- ✅ **Escrow System**: Secure fund holding with automatic release
- ✅ **Dispute Resolution**: Complete arbitration system with staking and timeouts
- ✅ **Arbitrator Economics**: Rewards, slashing, and performance tracking
- ✅ **Advanced Order States**: Complete lifecycle management with atomic transitions
- ✅ **Stake-weighted Selection**: Fair arbitrator assignment algorithm
- ✅ **Gas Optimization**: Efficient large-scale operations
- ✅ **Comprehensive Testing**: 29 tests covering all functionality including security
- ✅ **Security Hardening**: Reentrancy protection, overflow prevention, input validation
- ✅ **Arbitrator Liveness**: Timeout mechanisms with dispute reassignment
- ✅ **Challenge System**: Governance dispute reversal with proper state management
- ✅ **Dual Token Architecture**: Separate settlement and staking tokens

### v1.0 - Previous Version

- ✅ **Basic P2P Trading**: Simple order creation and matching
- ✅ **Review System**: 10-50 scale ratings with 0.1 precision
- ✅ **Commission System**: Configurable platform fees
- ✅ **SafeERC20 Integration**: Secure token transfers
