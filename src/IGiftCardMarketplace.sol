// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title IGiftCardMarketplace
 * @dev Interface for the GiftCardMarketplace contract with staking-based arbitration
 */
interface IGiftCardMarketplace {
    // ====== Enums ======

    /// @dev Order lifecycle status
    enum OrderStatus {
        Active, // 0: order is available for purchase
        Escrowed, // 1: funds held in escrow, awaiting delivery confirmation
        Disputed, // 2: buyer raised dispute within timelock
        Completed, // 3: successful transaction
        Cancelled, // 4: order was cancelled by seller
        Refunded, // 5: dispute resolved in buyer's favor
        Expired // 6: reserved for future features

    }

    /// @dev Dispute status for tracking dispute lifecycle
    enum DisputeStatus {
        None, // 0: no dispute
        Raised, // 1: dispute raised by buyer
        InArbitration, // 2: arbitrator assigned
        Resolved // 3: dispute resolved

    }

    // ====== Structs ======

    /// @dev Public order data
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
        uint256 escrowReleaseTime; // auto-release timestamp
        bool deliveryConfirmed; // buyer confirmed delivery
        DisputeStatus disputeStatus;
    }

    /// @dev Dispute information
    struct Dispute {
        bytes32 orderId;
        address buyer;
        address seller;
        address arbitrator;
        string reason;
        DisputeStatus status;
        uint256 raisedAt;
        uint256 resolvedAt;
        bool buyerWins; // true if refund, false if release to seller
        bool challenged; // true if arbitrator decision has been challenged
    }

    /// @dev Arbitrator staking information
    struct ArbitratorStake {
        uint256 stakedAmount;
        uint256 lockedAmount; // Amount locked in active disputes
        uint256 totalRewards;
        uint256 totalSlashed;
        uint256 correctDecisions;
        uint256 totalDecisions;
        uint256 stakingTime;
        bool isActive;
    }

    /// @dev Public review record
    struct Review {
        address reviewer;
        uint256 rating; // 10..50 => 1.0..5.0 stars with 0.1 precision
        string comment;
        uint256 timestamp;
    }

    // ====== Events ======

    // Order Events
    event OrderCreated(
        bytes32 indexed orderId, address indexed seller, string orderType, string description, uint256 price
    );
    event OrderMatched(
        bytes32 indexed orderId, address indexed buyer, address indexed seller, uint256 price, uint256 releaseTime
    );
    event OrderEdited(bytes32 indexed orderId, string orderType, string description, uint256 price);
    event OrderDelisted(bytes32 indexed orderId, address indexed seller);
    event DeliveryConfirmed(bytes32 indexed orderId, address indexed buyer);
    event FundsReleased(bytes32 indexed orderId, address indexed recipient, uint256 amount, string reason);

    // Dispute Events
    event DisputeRaised(bytes32 indexed orderId, address indexed buyer, address indexed arbitrator, string reason);
    event DisputeResolved(bytes32 indexed orderId, address indexed arbitrator, bool buyerWins, string resolution);

    // Arbitrator Events
    event ArbitratorStaked(address indexed arbitrator, uint256 amount, uint256 totalStake);
    event ArbitratorUnstaked(address indexed arbitrator, uint256 amount, uint256 remainingStake);
    event ArbitratorRewarded(address indexed arbitrator, uint256 reward, bytes32 indexed orderId);
    event ArbitratorSlashed(address indexed arbitrator, uint256 slashed, bytes32 indexed orderId);

    // Review Events
    event ReviewSubmitted(
        bytes32 indexed orderId, address indexed reviewer, address indexed seller, uint256 rating, string comment
    );

    // Admin Events
    event CommissionFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event CommissionRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event EscrowTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);
    event MinimumStakeUpdated(uint256 oldStake, uint256 newStake);
    event ArbitratorRewardUpdated(uint256 oldRewardBps, uint256 newRewardBps);
    event SlashingRateUpdated(uint256 oldSlashingBps, uint256 newSlashingBps);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event ArbitratorTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);
    event DisputeReassigned(bytes32 indexed orderId, address indexed oldArbitrator, address indexed newArbitrator);
    event StaleDisputeForceResolved(bytes32 indexed orderId, address indexed arbitrator, bool buyerWins);

    // ====== Errors ======

    error OrderNotFound();
    error OrderNotActive();
    error OrderNotCompleted();
    error OrderNotEscrowed();
    error InvalidPrice();
    error InvalidDescription();
    error InvalidRating(); // must be 10..50
    error NotOrderSeller();
    error NotOrderBuyer();
    error OnlyBuyerCanReview();
    error AlreadyReviewedThisOrder();
    error CommissionFeeTooHigh();
    error EscrowTimeoutTooHigh();
    error CannotBuyOwnOrder();
    error ZeroAddress();
    error LimitOutOfRange();
    error DisputeWindowExpired();
    error DisputeAlreadyRaised();
    error NoDisputeFound();
    error NotAuthorizedArbitrator();
    error DisputeNotInArbitration();
    error DeliveryAlreadyConfirmed();
    error CannotConfirmOwnDelivery();
    error EscrowNotReleasable();
    error InsufficientStake();
    error ArbitratorNotActive();
    error StakingAmountTooLow();
    error UnstakingDelayNotMet();
    error InsufficientStakeForDispute();
    error NoActiveArbitrators();
    error DisputeAlreadyChallenged();
    error ArbitratorTimeoutTooHigh();
    error ArbitratorTimeoutNotExpired();
    error DisputeNotStale();
    error ArbitratorRewardTooHigh();
    error SlashingRateTooHigh();
    error DisputeNotResolved();
    error InsufficientAvailableStakeForSlashing();

    // ====== Core Order Functions ======

    function createOrder(string memory orderType, string memory description, uint256 price) external;
    function editOrder(bytes32 orderId, string memory newOrderType, string memory newDescription, uint256 newPrice)
        external;
    function delistOrder(bytes32 orderId) external;
    function matchOrder(bytes32 orderId) external;

    // ====== Escrow & Delivery Functions ======

    function confirmDelivery(bytes32 orderId) external;
    function releaseEscrowAfterTimeout(bytes32 orderId) external;

    // ====== Dispute Resolution Functions ======

    function raiseDispute(bytes32 orderId, string memory reason) external;
    function resolveDispute(bytes32 orderId, bool buyerWins, string memory resolution) external;
    function challengeArbitratorDecision(bytes32 orderId) external;
    function reassignStaleDispute(bytes32 orderId) external;
    function forceResolveStaleDispute(bytes32 orderId, bool buyerWins) external;

    // ====== Arbitrator Staking Functions ======

    function stakeAsArbitrator(uint256 amount) external;
    function unstakeAsArbitrator(uint256 amount) external;

    // ====== Review Functions ======

    function submitReview(bytes32 orderId, uint256 rating, string memory comment) external;

    // ====== View Functions - Orders ======

    function getOrder(bytes32 orderId) external view returns (Order memory);
    function getOrdersBySeller(address seller, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory orderIds, uint256 total);
    function getActiveOrders() external view returns (bytes32[] memory orderIds);
    function getActiveOrdersPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory orderIds, uint256 totalActive);
    function getOrdersByStatus(OrderStatus status) external view returns (bytes32[] memory orderIds);
    function getOrdersByStatusPaginated(OrderStatus status, uint256 offset, uint256 limit)
        external
        view
        returns (bytes32[] memory orderIds, uint256 totalOfStatus);
    function getAllStatusCounts()
        external
        view
        returns (
            uint256 activeCount,
            uint256 escrowedCount,
            uint256 disputedCount,
            uint256 completedCount,
            uint256 cancelledCount,
            uint256 refundedCount,
            uint256 expiredCount
        );

    // ====== View Functions - Disputes ======

    function getDispute(bytes32 orderId) external view returns (Dispute memory);
    function canRaiseDispute(bytes32 orderId) external view returns (bool);
    function canReleaseEscrow(bytes32 orderId) external view returns (bool);
    function getEscrowTimeRemaining(bytes32 orderId) external view returns (uint256);
    function canReassignDispute(bytes32 orderId) external view returns (bool);
    function canForceResolveDispute(bytes32 orderId) external view returns (bool);
    function getArbitratorTimeRemaining(bytes32 orderId) external view returns (uint256);

    // ====== View Functions - Arbitrators ======

    function getActiveArbitrators() external view returns (address[] memory);
    function getActiveArbitratorsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory arbitrators, uint256 total);
    function getArbitratorStake(address arbitrator)
        external
        view
        returns (
            uint256 stakedAmount,
            uint256 lockedAmount,
            uint256 totalRewards,
            uint256 totalSlashed,
            uint256 correctDecisions,
            uint256 totalDecisions,
            uint256 stakingTime,
            bool isActive
        );
    function isActiveArbitrator(address arbitrator) external view returns (bool);

    // ====== View Functions - Staking Stats ======

    function getStakingStats()
        external
        view
        returns (
            uint256 totalStakedAmount,
            uint256 activeArbitratorsCount,
            uint256 minimumStakeRequired,
            uint256 arbitratorRewardRate,
            uint256 slashingRate
        );

    // ====== View Functions - Reviews ======

    function getSellerReviews(address seller, uint256 offset, uint256 limit)
        external
        view
        returns (Review[] memory reviews, uint256 total);
    function getSellerCredit(address seller)
        external
        view
        returns (uint256 totalReviews, uint256 averageRatingTenths, uint256 totalRatingTenths);
    function hasReviewed(bytes32 orderId, address reviewer) external view returns (bool);

    // ====== Admin Functions ======

    function updateCommissionFee(uint16 newFeeBps) external;
    function setCommissionRecipient(address newRecipient) external;
    function updateEscrowTimeout(uint256 newTimeout) external;
    function updateMinimumStake(uint256 newMinimumStake) external;
    function updateArbitratorReward(uint256 newRewardBps) external;
    function updateSlashingRate(uint256 newSlashingBps) external;
    function updateMaxArbitratorsToCheck(uint256 newMax) external;
    function updateArbitratorTimeout(uint256 newTimeout) external;
    function pause() external;
    function unpause() external;

    // ====== State Variables ======

    function usdcToken() external view returns (address);
    function stakingToken() external view returns (address);
    function commissionFeeBps() external view returns (uint16);
    function MAX_COMMISSION_FEE_BPS() external view returns (uint16);
    function commissionRecipient() external view returns (address);
    function escrowTimeout() external view returns (uint256);
    function MAX_ESCROW_TIMEOUT() external view returns (uint256);
    function minimumStake() external view returns (uint256);
    function arbitratorRewardBps() external view returns (uint256);
    function slashingBps() external view returns (uint256);
    function unstakingDelay() external view returns (uint256);
    function maxArbitratorsToCheck() external view returns (uint256);
    function arbitratorTimeout() external view returns (uint256);
    function MAX_ARBITRATOR_TIMEOUT() external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function owner() external view returns (address);
    function paused() external view returns (bool);
}
