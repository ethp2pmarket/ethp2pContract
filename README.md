# Gift Card Marketplace

A decentralized P2P marketplace for trading gift cards built on Ethereum using Solidity and Foundry.

## Overview

This marketplace allows users to:

- **Sellers**: Create, edit, and delist gift card orders with configurable types and descriptions
- **Buyers**: Purchase gift cards by matching existing orders using USDC
- **Platform**: Collect commission fees on successful trades with flexible recipient management
- **Review System**: Buyers can rate sellers with 0.1 precision (1.0-5.0 stars)

The marketplace handles the order logic while buyers and sellers communicate through external channels (e.g., Etherscan private chat) to coordinate the actual gift card transfer.

## Features

### Core Functionality

- ✅ **Order Creation**: Sellers can create orders with types, descriptions, and prices
- ✅ **Order Matching**: Buyers can purchase orders using USDC with automatic commission deduction
- ✅ **Order Management**: Sellers can edit or delist their active orders
- ✅ **Commission System**: Platform collects configurable fees (default: 1%, max: 5%)
- ✅ **Commission Recipient Management**: Flexible commission destination configuration
- ✅ **Review System**: 10-50 rating scale with 0.1 precision (1.0-5.0 stars)
- ✅ **Pause/Resume**: Emergency pause functionality for contract owner
- ✅ **Gas Optimization**: Efficient pagination and data structures

### Security Features

- 🔒 **Reentrancy Protection**: Prevents reentrancy attacks using OpenZeppelin's ReentrancyGuard
- 🔒 **Access Control**: Only order sellers can modify their orders, owner-only admin functions
- 🔒 **Input Validation**: Comprehensive parameter validation with custom error messages
- 🔒 **Emergency Controls**: Owner can pause operations and recover stuck tokens
- 🔒 **SafeERC20**: Secure token transfers using OpenZeppelin's SafeERC20

## Smart Contracts

### 1. GiftCardMarketplace.sol

The main marketplace contract that handles:

- Order lifecycle management with status tracking (Active, Completed, Cancelled, Expired)
- USDC payment processing with SafeERC20
- Commission fee collection and distribution
- Review system with seller credibility tracking
- Access control and security
- Gas-efficient pagination for scalable data retrieval

### 2. MockUSDC.sol

A test USDC token implementation with 6 decimals for development and testing.

## Contract Architecture

```
GiftCardMarketplace
├── Order Management
│   ├── createOrder() - Create new orders with keccak256 ID generation
│   ├── editOrder() - Edit active orders (type, description, price)
│   ├── delistOrder() - Cancel active orders
│   └── matchOrder() - Purchase orders with automatic commission deduction
├── Review System
│   ├── submitReview() - Submit ratings (10-50 scale) for completed orders
│   ├── getSellerCredit() - Get seller aggregate ratings and review counts
│   └── hasReviewed() - Check if order was already reviewed
├── View Functions
│   ├── getOrder() - Get order details
│   ├── getActiveOrders() - Get active orders (backward compatible)
│   ├── getActiveOrdersPaginated() - Paginated active order retrieval
│   ├── getOrdersBySeller() - Get seller's orders with pagination
│   ├── getSellerReviews() - Get seller reviews with pagination
│   └── getStatusCounts() - Get order counts by status
├── Admin Functions
│   ├── updateCommissionFee() - Update commission percentage (1-5%)
│   ├── setCommissionRecipient() - Set commission destination address
│   ├── pause()/unpause() - Emergency pause functionality
│   └── emergencyWithdraw() - Recover stuck ERC20 tokens
└── Security
    ├── ReentrancyGuard - Prevents reentrancy attacks
    ├── Pausable - Emergency pause mechanism
    └── Ownable - Access control for admin functions
```

## Data Structures

### Order Structure

```solidity
struct Order {
    bytes32 orderId;        // Unique keccak256 identifier
    address seller;         // Seller's address
    address buyer;          // Buyer's address (set when matched)
    string orderType;       // Gift card type (e.g., "Amazon", "Walmart")
    string description;     // Gift card description
    uint256 price;         // Price in USDC (6 decimals)
    OrderStatus status;     // Active, Completed, Cancelled, Expired
    uint256 createdAt;     // Creation timestamp
    uint256 updatedAt;     // Last update timestamp
}
```

### Review Structure

```solidity
struct Review {
    address reviewer;       // Buyer's address
    uint256 rating;         // 10-50 scale (1.0 to 5.0 stars with 0.1 precision)
    string comment;         // Review text
    uint256 timestamp;      // Review submission time
}
```

### Seller Credit Structure

```solidity
struct SellerCredit {
    uint256 totalReviews;   // Total number of reviews
    uint256 averageRating;  // Average rating in tenths (10-50)
    uint256 totalRating;    // Sum of all ratings in tenths
}
```

## Rating System

The marketplace uses a **10-50 scale** for ratings, providing **0.1 precision**:

- **10** = 1.0 stars
- **25** = 2.5 stars
- **37** = 3.7 stars
- **42** = 4.2 stars
- **50** = 5.0 stars

This allows for nuanced feedback while maintaining integer storage efficiency.

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

3. **Delist Order** (if needed)
   ```solidity
   marketplace.delistOrder(orderId);
   ```

### For Buyers

1. **Approve USDC Spending**

   ```solidity
   usdc.approve(marketplaceAddress, orderPrice);
   ```

2. **Match Order**

   ```solidity
   marketplace.matchOrder(orderId);
   ```

3. **Submit Review** (after receiving gift card)
   ```solidity
   marketplace.submitReview(orderId, 50, "Excellent service!"); // 5.0 stars
   ```

### For Platform Owners

1. **Update Commission Fee**

   ```solidity
   marketplace.updateCommissionFee(200); // 2%
   ```

2. **Set Commission Recipient**

   ```solidity
   marketplace.setCommissionRecipient(newRecipientAddress);
   ```

3. **Emergency Pause**
   ```solidity
   marketplace.pause();
   ```

## Commission System

- **Default Fee**: 1% (100 basis points)
- **Maximum Fee**: 5% (500 basis points)
- **Fee Collection**: Automatically deducted from buyer's payment
- **Distribution**: Commission goes to configurable recipient, remainder to seller
- **Recipient Management**: Owner can change commission destination address

## Gas Optimization

The contract is highly optimized for gas efficiency:

- **Pagination System**: Efficient data retrieval with offset/limit parameters
- **Status Counters**: O(1) lookup for order counts by status
- **Nested Mappings**: Efficient storage without large arrays
- **Custom Errors**: Gas-efficient error handling
- **SafeERC20**: Secure and efficient token transfers
- **Assembly Usage**: Optimized array resizing for pagination

## Installation & Setup

### Prerequisites

- [Foundry](https://getfoundry.sh/) installed
- Node.js 16+ (for dependencies)

### 1. Clone Repository

```bash
git clone <repository-url>
```

### 2. Install Dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts
```


### 3. Build Contracts

```bash
forge build
```
