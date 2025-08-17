// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title GiftCardMarketplace
 * @notice Simple P2P listing + matching marketplace for gift cards.
 * @dev IMPORTANT: This contract does NOT provide escrow or delivery enforcement.
 *      On match, buyer funds go directly to the seller and a commission recipient.
 *      Integrations should clearly surface the associated counterparty risk.
 */
contract GiftCardMarketplace is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ====== Types / Storage ======

    /// @dev USDC (or another ERC20) used for settlement. Assumes 6 decimals for UI, not enforced on-chain.
    IERC20 public immutable usdcToken;

    /// @dev Commission in basis points (1% = 100). Capped by MAX_COMMISSION_FEE_BPS.
    uint16 public commissionFeeBps = 100; // default 1%

    /// @dev Maximum commission fee (5%).
    uint16 public constant MAX_COMMISSION_FEE_BPS = 500;

    /// @dev Where commissions are sent on each match; default = owner().
    address public commissionRecipient;

    /// @dev Order lifecycle status.
    enum OrderStatus {
        Active, // 0: order is available for purchase
        Completed, // 1: order has been purchased
        Cancelled, // 2: order was cancelled by seller
        Expired // 3: reserved for future features

    }

    /// @dev Public order data.
    struct Order {
        bytes32 orderId;
        address seller;
        address buyer; // set when matched
        string orderType; // e.g., "Amazon", "Walmart"
        string description; // free text
        uint256 price; // token amount in smallest unit (e.g., USDC 6dp)
        OrderStatus status;
        uint256 createdAt;
        uint256 updatedAt;
    }

    /// @dev Public review record. rating is in "tenths" from 10..50 representing 1.0..5.0 stars.
    struct Review {
        address reviewer;
        uint256 rating; // 10..50 => 1.0..5.0 stars with 0.1 precision
        string comment;
        uint256 timestamp;
    }

    /// @dev Aggregated seller credit. averageRating is also in tenths (10..50).
    struct SellerCredit {
        uint256 totalReviews;
        uint256 averageRating; // tenths 10..50
        uint256 totalRating; // sum of all ratings in tenths
    }

    // orders
    mapping(bytes32 => Order) public orders;

    // seller → sequential index → orderId
    mapping(address => mapping(uint256 => bytes32)) public sellerOrderByIndex;
    mapping(address => uint256) public sellerOrderCount;

    // reviews
    mapping(address => mapping(uint256 => Review)) public sellerReviewByIndex; // seller → idx → review
    mapping(address => uint256) public sellerReviewCount; // seller → count
    mapping(address => SellerCredit) public sellerCredits; // seller → credit

    /// @dev Track whether a specific reviewer has reviewed a specific order.
    mapping(bytes32 => mapping(address => bool)) private _reviewedByOrder; // orderId → reviewer → bool

    // pagination
    uint256 private _orderCounter; // total orders ever created
    mapping(uint256 => bytes32) public orderIdByIndex; // global index → orderId

    // status counters
    mapping(OrderStatus => uint256) public statusCounts;

    // ====== Events ======

    event OrderCreated(
        bytes32 indexed orderId, address indexed seller, string orderType, string description, uint256 price
    );
    event OrderMatched(bytes32 indexed orderId, address indexed buyer, address indexed seller, uint256 price);
    event OrderEdited(bytes32 indexed orderId, string orderType, string description, uint256 price);
    event OrderDelisted(bytes32 indexed orderId, address indexed seller);

    event ReviewSubmitted(
        bytes32 indexed orderId, address indexed reviewer, address indexed seller, uint256 rating, string comment
    );

    event CommissionFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event CommissionRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    // ====== Errors ======

    error OrderNotFound();
    error OrderNotActive();
    error OrderNotCompleted();
    error InvalidPrice();
    error InvalidDescription();
    error InvalidRating(); // must be 10..50
    error NotOrderSeller();
    error OnlyBuyerCanReview();
    error AlreadyReviewedThisOrder();
    error CommissionFeeTooHigh();
    error CannotBuyOwnOrder();
    error ZeroAddress();
    error LimitOutOfRange();

    // ====== Constructor ======

    /**
     * @param _usdcToken Settlement token address (e.g., USDC)
     * @param _owner Initial contract owner
     */
    constructor(address _usdcToken, address _owner) Ownable(_owner) {
        if (_usdcToken == address(0)) revert ZeroAddress();
        usdcToken = IERC20(_usdcToken);
        commissionRecipient = _owner;
        emit CommissionRecipientUpdated(address(0), _owner);
    }

    // ====== Admin ======

    /**
     * @dev Update commission fee in basis points (1% = 100). Max = 500 (5%).
     */
    function updateCommissionFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_COMMISSION_FEE_BPS) revert CommissionFeeTooHigh();
        uint16 old = commissionFeeBps;
        commissionFeeBps = newFeeBps;
        emit CommissionFeeUpdated(old, newFeeBps);
    }

    /**
     * @dev Update the commission recipient address.
     */
    function setCommissionRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        address old = commissionRecipient;
        commissionRecipient = newRecipient;
        emit CommissionRecipientUpdated(old, newRecipient);
    }

    /**
     * @dev Pause the marketplace. Disables create/edit/match/review actions.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpause the marketplace.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Recover ERC20 tokens mistakenly sent to this contract.
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        IERC20(token).safeTransfer(owner(), amount);
        emit TokensRecovered(token, owner(), amount);
    }

    // ====== Seller-facing ======

    /**
     * @notice Create a new order.
     * @param orderType Type/brand of gift card, free text (e.g., "Amazon")
     * @param description Additional details
     * @param price Settlement amount in token smallest units (USDC 6dp)
     */
    function createOrder(string memory orderType, string memory description, uint256 price) external whenNotPaused {
        if (bytes(orderType).length == 0) revert InvalidDescription();
        if (bytes(description).length == 0) revert InvalidDescription();
        if (price == 0) revert InvalidPrice();

        bytes32 orderId =
            keccak256(abi.encodePacked(msg.sender, orderType, description, price, block.timestamp, _orderCounter));
        // Ensure no collision (extremely unlikely)
        require(orders[orderId].orderId == 0, "Order ID collision");

        Order memory newOrder = Order({
            orderId: orderId,
            seller: msg.sender,
            buyer: address(0),
            orderType: orderType,
            description: description,
            price: price,
            status: OrderStatus.Active,
            createdAt: block.timestamp,
            updatedAt: block.timestamp
        });

        orders[orderId] = newOrder;

        // Per-seller index
        uint256 sellerIdx = sellerOrderCount[msg.sender];
        sellerOrderByIndex[msg.sender][sellerIdx] = orderId;
        sellerOrderCount[msg.sender] = sellerIdx + 1;

        // Global pagination index
        orderIdByIndex[_orderCounter] = orderId;
        _orderCounter++;

        // Status counters
        statusCounts[OrderStatus.Active]++;

        emit OrderCreated(orderId, msg.sender, orderType, description, price);
    }

    /**
     * @notice Edit an existing *active* order. Only the seller may edit.
     */
    function editOrder(bytes32 orderId, string memory newOrderType, string memory newDescription, uint256 newPrice)
        external
        whenNotPaused
    {
        Order storage order = orders[orderId];
        if (order.orderId == 0) revert OrderNotFound();
        if (order.status != OrderStatus.Active) revert OrderNotActive();
        if (msg.sender != order.seller) revert NotOrderSeller();
        if (bytes(newOrderType).length == 0) revert InvalidDescription();
        if (bytes(newDescription).length == 0) revert InvalidDescription();
        if (newPrice == 0) revert InvalidPrice();

        order.orderType = newOrderType;
        order.description = newDescription;
        order.price = newPrice;
        order.updatedAt = block.timestamp;

        emit OrderEdited(orderId, newOrderType, newDescription, newPrice);
    }

    /**
     * @notice Delist (cancel) an *active* order. Only the seller may cancel.
     * @dev Allowed even while paused as a safety measure.
     */
    function delistOrder(bytes32 orderId) external {
        Order storage order = orders[orderId];
        if (order.orderId == 0) revert OrderNotFound();
        if (order.status != OrderStatus.Active) revert OrderNotActive();
        if (msg.sender != order.seller) revert NotOrderSeller();

        statusCounts[OrderStatus.Active]--;
        statusCounts[OrderStatus.Cancelled]++;

        order.status = OrderStatus.Cancelled;
        order.updatedAt = block.timestamp;

        emit OrderDelisted(orderId, msg.sender);
    }

    // ====== Buyer-facing ======

    /**
     * @notice Buy (match) an active order. Transfers funds immediately to seller and commission recipient.
     * @dev Requires prior ERC20 approval from buyer to this contract for at least `price`.
     */
    function matchOrder(bytes32 orderId) external nonReentrant whenNotPaused {
        Order storage order = orders[orderId];
        if (order.orderId == 0) revert OrderNotFound();
        if (order.status != OrderStatus.Active) revert OrderNotActive();
        if (msg.sender == order.seller) revert CannotBuyOwnOrder();

        uint256 price = order.price;
        uint256 commissionAmount = (price * commissionFeeBps) / 10_000;
        uint256 sellerAmount = price - commissionAmount;

        // Pull funds atomically
        usdcToken.safeTransferFrom(msg.sender, order.seller, sellerAmount);
        if (commissionAmount > 0) {
            usdcToken.safeTransferFrom(msg.sender, commissionRecipient, commissionAmount);
        }

        statusCounts[OrderStatus.Active]--;
        statusCounts[OrderStatus.Completed]++;

        order.buyer = msg.sender;
        order.status = OrderStatus.Completed;
        order.updatedAt = block.timestamp;

        emit OrderMatched(orderId, msg.sender, order.seller, price);
    }

    /**
     * @notice Submit a review for a completed order. One review per (orderId, reviewer).
     * @param orderId The completed order being reviewed
     * @param rating 10..50 (represents 1.0..5.0 stars in tenths)
     * @param comment Free text feedback
     */
    function submitReview(bytes32 orderId, uint256 rating, string memory comment) external whenNotPaused {
        Order storage order = orders[orderId];
        if (order.orderId == 0) revert OrderNotFound();
        if (order.status != OrderStatus.Completed) revert OrderNotCompleted();
        if (msg.sender != order.buyer) revert OnlyBuyerCanReview();

        if (_reviewedByOrder[orderId][msg.sender]) revert AlreadyReviewedThisOrder();
        if (rating < 10 || rating > 50) revert InvalidRating();

        Review memory newReview =
            Review({reviewer: msg.sender, rating: rating, comment: comment, timestamp: block.timestamp});

        // Append to seller's review list
        uint256 idx = sellerReviewCount[order.seller];
        sellerReviewByIndex[order.seller][idx] = newReview;
        sellerReviewCount[order.seller] = idx + 1;

        // Update aggregate credit
        SellerCredit storage sc = sellerCredits[order.seller];
        _reviewedByOrder[orderId][msg.sender] = true;
        sc.totalReviews++;
        sc.totalRating += rating;
        sc.averageRating = sc.totalRating / sc.totalReviews; // still in tenths (10..50)

        emit ReviewSubmitted(orderId, msg.sender, order.seller, rating, comment);
    }

    // ====== Views (Queries) ======

    /**
     * @notice Get order details.
     */
    function getOrder(bytes32 orderId) external view returns (Order memory) {
        if (orders[orderId].orderId == 0) revert OrderNotFound();
        return orders[orderId];
    }

    /**
     * @notice Get orders by a seller with pagination.
     * @param seller Seller address
     * @param offset Starting index
     * @param limit  Max items to return (1..100)
     */
    function getOrdersBySeller(address seller, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory orderIds, uint256 total)
    {
        if (limit == 0 || limit > 100) revert LimitOutOfRange();

        total = sellerOrderCount[seller];
        if (offset >= total) {
            return (new bytes32[](0), total);
        }

        uint256 actual = offset + limit > total ? (total - offset) : limit;
        orderIds = new bytes32[](actual);
        for (uint256 i = 0; i < actual; i++) {
            orderIds[i] = sellerOrderByIndex[seller][offset + i];
        }
    }

    /**
     * @notice Get seller aggregate credit.
     * @dev averageRating and totalRating are in tenths (10..50).
     */
    function getSellerCredit(address seller)
        external
        view
        returns (uint256 totalReviews, uint256 averageRatingTenths, uint256 totalRatingTenths)
    {
        SellerCredit storage credit = sellerCredits[seller];
        return (credit.totalReviews, credit.averageRating, credit.totalRating);
    }

    /**
     * @notice Whether `reviewer` has already reviewed this specific `orderId`.
     */
    function hasReviewed(bytes32 orderId, address reviewer) external view returns (bool) {
        if (orders[orderId].orderId == 0) revert OrderNotFound();
        return _reviewedByOrder[orderId][reviewer];
    }

    /**
     * @notice Total number of reviews for a seller.
     */
    function getSellerReviewCount(address seller) external view returns (uint256) {
        return sellerReviewCount[seller];
    }

    /**
     * @notice Buyer of an order (address(0) if not matched).
     */
    function getOrderBuyer(bytes32 orderId) external view returns (address) {
        if (orders[orderId].orderId == 0) revert OrderNotFound();
        return orders[orderId].buyer;
    }

    /**
     * @notice Backward-compat: returns up to 50 active orders (prefer paginated versions).
     */
    function getActiveOrders() external view returns (bytes32[] memory orderIds) {
        orderIds = new bytes32[](50);
        uint256 found;
        for (uint256 i = 0; i < _orderCounter && found < 50; i++) {
            bytes32 oid = orderIdByIndex[i];
            if (orders[oid].status == OrderStatus.Active) {
                orderIds[found++] = oid;
            }
        }
        assembly {
            mstore(orderIds, found)
        }
        return orderIds;
    }

    /**
     * @notice Paginated list of active orders.
     * @param offset Starting global order index to scan from
     * @param limit  Max results to return (1..100)
     * @return orderIds Found orderIds
     * @return totalActive Snapshot of total active count
     */
    function getActiveOrdersPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory orderIds, uint256 totalActive)
    {
        if (limit == 0 || limit > 100) revert LimitOutOfRange();
        totalActive = statusCounts[OrderStatus.Active];
        orderIds = new bytes32[](limit);
        uint256 found;
        for (uint256 i = offset; i < _orderCounter && found < limit; i++) {
            bytes32 oid = orderIdByIndex[i];
            if (orders[oid].status == OrderStatus.Active) {
                orderIds[found++] = oid;
            }
        }
        assembly {
            mstore(orderIds, found)
        }
    }

    /**
     * @notice Backward-compat: returns up to 50 orders of a given status (prefer paginated).
     */
    function getOrdersByStatus(OrderStatus status) external view returns (bytes32[] memory orderIds) {
        orderIds = new bytes32[](50);
        uint256 found;
        for (uint256 i = 0; i < _orderCounter && found < 50; i++) {
            bytes32 oid = orderIdByIndex[i];
            if (orders[oid].status == status) {
                orderIds[found++] = oid;
            }
        }
        assembly {
            mstore(orderIds, found)
        }
        return orderIds;
    }

    /**
     * @notice Paginated list filtered by status.
     * @param status Filter status
     * @param offset Starting global order index to scan from
     * @param limit  Max results to return (1..100)
     * @return orderIds Matching orderIds
     * @return totalOfStatus Snapshot of total count for this status
     */
    function getOrdersByStatusPaginated(OrderStatus status, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory orderIds, uint256 totalOfStatus)
    {
        if (limit == 0 || limit > 100) revert LimitOutOfRange();
        totalOfStatus = statusCounts[status];
        orderIds = new bytes32[](limit);
        uint256 found;
        for (uint256 i = offset; i < _orderCounter && found < limit; i++) {
            bytes32 oid = orderIdByIndex[i];
            if (orders[oid].status == status) {
                orderIds[found++] = oid;
            }
        }
        assembly {
            mstore(orderIds, found)
        }
    }

    /**
     * @notice Snapshot counts by status.
     */
    function getAllStatusCounts()
        external
        view
        returns (uint256 activeCount, uint256 completedCount, uint256 cancelledCount, uint256 expiredCount)
    {
        activeCount = statusCounts[OrderStatus.Active];
        completedCount = statusCounts[OrderStatus.Completed];
        cancelledCount = statusCounts[OrderStatus.Cancelled];
        expiredCount = statusCounts[OrderStatus.Expired];
    }

    /**
     * @notice Total orders ever created (global index size).
     */
    function getTotalOrders() external view returns (uint256) {
        return _orderCounter;
    }

    /**
     * @notice Total number of orders for a specific seller.
     */
    function getSellerOrderCount(address seller) external view returns (uint256) {
        return sellerOrderCount[seller];
    }

    /**
     * @notice Paged reviews for a seller.
     * @param seller Seller address
     * @param offset Start index
     * @param limit  Max items to return (1..100)
     */
    function getSellerReviews(address seller, uint256 offset, uint256 limit)
        external
        view
        returns (Review[] memory reviews, uint256 total)
    {
        if (limit == 0 || limit > 100) revert LimitOutOfRange();

        total = sellerReviewCount[seller];
        if (offset >= total) return (new Review[](0), total);

        uint256 actual = offset + limit > total ? (total - offset) : limit;
        reviews = new Review[](actual);
        for (uint256 i = 0; i < actual; i++) {
            reviews[i] = sellerReviewByIndex[seller][offset + i];
        }
    }
}
