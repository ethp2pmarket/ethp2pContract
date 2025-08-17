// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IGiftCardMarketplace
 * @dev Interface for the GiftCardMarketplace contract
 */
interface IGiftCardMarketplace {
    // Enums
    enum OrderStatus {
        Active, // 0: Order is available for purchase
        Completed, // 1: Order has been purchased
        Cancelled, // 2: Order was cancelled by seller
        Expired // 3: Order has expired (optional future feature)

    }

    // Structs
    struct Order {
        bytes32 orderId;
        address seller;
        address buyer;
        string orderType;
        string description;
        uint256 price;
        OrderStatus status;
        uint256 createdAt;
        uint256 updatedAt;
    }

    struct Review {
        address reviewer;
        uint256 rating;
        string comment;
        uint256 timestamp;
    }

    // Events
    event OrderCreated(
        bytes32 indexed orderId, address indexed seller, string orderType, string description, uint256 price
    );
    event OrderMatched(bytes32 indexed orderId, address indexed buyer, address indexed seller, uint256 price);
    event OrderEdited(bytes32 indexed orderId, string orderType, string description, uint256 price);
    event OrderDelisted(bytes32 indexed orderId, address indexed seller);
    event ReviewSubmitted(
        bytes32 indexed orderId, address indexed reviewer, address indexed seller, uint256 rating, string comment
    );
    event CommissionFeeUpdated(uint256 oldFee, uint256 newFee);
    event CommissionWithdrawn(address indexed owner, uint256 amount);

    // Errors
    error OrderNotFound();
    error OrderNotActive();
    error InsufficientUSDC();
    error InvalidPrice();
    error InvalidDescription();
    error NotOrderSeller();
    error CommissionFeeTooHigh();
    error TransferFailed();
    error OnlyBuyerCanReview();

    // Core Functions
    function createOrder(string memory orderType, string memory description, uint256 price) external;
    function matchOrder(bytes32 orderId) external;
    function editOrder(bytes32 orderId, string memory newOrderType, string memory newDescription, uint256 newPrice)
        external;
    function delistOrder(bytes32 orderId) external;
    function submitReview(bytes32 orderId, uint256 rating, string memory comment) external;

    // View Functions
    function getOrder(bytes32 orderId) external view returns (Order memory);
    function getActiveOrders() external view returns (bytes32[] memory);
    function getOrdersBySeller(address seller, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory, uint256);
    function getSellerReviews(address seller, uint256 offset, uint256 limit)
        external
        view
        returns (Review[] memory, uint256);
    function getSellerCredit(address seller)
        external
        view
        returns (uint256 totalReviews, uint256 averageRating, uint256 totalRating);
    function hasReviewed(bytes32 orderId, address reviewer) external view returns (bool);
    function getSellerReviewCount(address seller) external view returns (uint256);
    function getOrderBuyer(bytes32 orderId) external view returns (address);
    function getOrdersByStatus(OrderStatus status) external view returns (bytes32[] memory);
    function getStatusCount(OrderStatus status) external view returns (uint256);
    function getAllStatusCounts()
        external
        view
        returns (uint256 activeCount, uint256 completedCount, uint256 cancelledCount, uint256 expiredCount);
    function getTotalOrders() external view returns (uint256);

    // Admin Functions
    function updateCommissionFee(uint256 newFee) external;
    function pause() external;
    function unpause() external;
    function emergencyWithdraw(address token, uint256 amount) external;

    // State Variables
    function usdcToken() external view returns (address);
    function commissionFeeBps() external view returns (uint256);
    function MAX_COMMISSION_FEE() external view returns (uint256);
    function owner() external view returns (address);
    function paused() external view returns (bool);
}
