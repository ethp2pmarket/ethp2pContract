// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title GiftCardMarketplace
 * @notice P2P marketplace for gift cards with escrow and staking-based dispute resolution.
 * @dev Features:
 *      - Escrow mechanism: funds held in contract until delivery confirmed or timeout
 *      - Dispute system: buyers can raise disputes within escrow window
 *      - Staking-based arbitration: arbitrators must stake tokens to participate
 *      - Stake-weighted selection: arbitrators chosen by stake amount (more stake = higher chance)
 *      - Economic incentives: arbitrators earn rewards for correct decisions, get slashed for wrong ones
 *      - Automatic release: funds auto-release to seller after timeout if no disputes
 *      - Delivery confirmation: buyers can confirm delivery for immediate release
 *      - Arbitrator management: minimum stake requirements, unstaking delays, performance tracking
 */
contract GiftCardMarketplace is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC20Metadata;

    // ====== Types / Storage ======

    /// @dev Settlement token (e.g., USDC). Decimals are auto-detected.
    IERC20Metadata public immutable usdcToken;

    /// @dev Staking token for arbitrators (can be same as USDC or different token). Decimals are auto-detected.
    IERC20Metadata public immutable stakingToken;

    /// @dev Cached decimals for gas optimization
    uint8 public immutable usdcDecimals;
    uint8 public immutable stakingDecimals;

    /// @dev Commission in basis points (1% = 100). Capped by MAX_COMMISSION_FEE_BPS.
    uint16 public commissionFeeBps = 100; // default 1%

    /// @dev Maximum commission fee (5%).
    uint16 public constant MAX_COMMISSION_FEE_BPS = 500;

    /// @dev Where commissions are sent on each match; default = owner().
    address public commissionRecipient;

    /// @dev Escrow release timeout in seconds (default 7 days).
    uint256 public escrowTimeout = 7 days;

    /// @dev Maximum escrow timeout (30 days).
    uint256 public constant MAX_ESCROW_TIMEOUT = 30 days;

    /// @dev Minimum stake required to become an arbitrator (in staking token units)
    uint256 public minimumStake; // Set in constructor based on token decimals

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

    /// @dev Mapping of arbitrator address to their stake info
    mapping(address => ArbitratorStake) public arbitratorStakes;

    /// @dev Simple list of active arbitrators
    address[] public activeArbitrators;

    /// @dev Total staked across all arbitrators
    uint256 public totalStaked;

    /// @dev Arbitrator reward percentage in basis points (default 1% of disputed amount)
    uint256 public arbitratorRewardBps = 100;

    /// @dev Slashing percentage for wrong decisions (default 10% of stake)
    uint256 public slashingBps = 1000;

    /// @dev Unstaking delay (7 days to prevent arbitrator exit during disputes)
    uint256 public unstakingDelay = 7 days;

    /// @dev Maximum arbitrators to check in selection (gas limit protection)
    uint256 public maxArbitratorsToCheck = 50;

    /// @dev Arbitrator response timeout (72 hours default)
    uint256 public arbitratorTimeout = 72 hours;

    /// @dev Maximum arbitrator timeout (7 days)
    uint256 public constant MAX_ARBITRATOR_TIMEOUT = 7 days;

    /// @dev Order lifecycle status.
    enum OrderStatus {
        Active, // 0: order is available for purchase
        Escrowed, // 1: funds held in escrow, awaiting delivery confirmation
        Disputed, // 2: buyer raised dispute within timelock
        Completed, // 3: successful transaction
        Cancelled, // 4: order was cancelled by seller
        Refunded, // 5: dispute resolved in buyer's favor
        Expired // 6: reserved for future features

    }

    /// @dev Dispute status for tracking dispute lifecycle.
    enum DisputeStatus {
        None, // 0: no dispute
        Raised, // 1: dispute raised by buyer
        InArbitration, // 2: arbitrator assigned
        Resolved // 3: dispute resolved

    }

    /// @dev Dispute information.
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
        uint256 escrowReleaseTime; // auto-release timestamp
        bool deliveryConfirmed; // buyer confirmed delivery
        DisputeStatus disputeStatus;
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

    // disputes
    mapping(bytes32 => Dispute) public disputes; // orderId → dispute
    mapping(address => uint256) public disputeCount; // arbitrator → count
    mapping(bytes32 => uint256) public disputeStakeRequirement; // orderId → required stake lock

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
    event OrderMatched(
        bytes32 indexed orderId, address indexed buyer, address indexed seller, uint256 price, uint256 releaseTime
    );
    event OrderEdited(bytes32 indexed orderId, string orderType, string description, uint256 price);
    event OrderDelisted(bytes32 indexed orderId, address indexed seller);
    event DeliveryConfirmed(bytes32 indexed orderId, address indexed buyer);
    event FundsReleased(bytes32 indexed orderId, address indexed recipient, uint256 amount, string reason);

    event DisputeRaised(bytes32 indexed orderId, address indexed buyer, address indexed arbitrator, string reason);
    event DisputeResolved(bytes32 indexed orderId, address indexed arbitrator, bool buyerWins, string resolution);

    event ReviewSubmitted(
        bytes32 indexed orderId, address indexed reviewer, address indexed seller, uint256 rating, string comment
    );

    event CommissionFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event CommissionRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event EscrowTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);
    event ArbitratorStaked(address indexed arbitrator, uint256 amount, uint256 totalStake);
    event ArbitratorUnstaked(address indexed arbitrator, uint256 amount, uint256 remainingStake);
    event ArbitratorRewarded(address indexed arbitrator, uint256 reward, bytes32 indexed orderId);
    event ArbitratorSlashed(address indexed arbitrator, uint256 slashed, bytes32 indexed orderId);
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
    error FundRecoveryFailed();
    error InsufficientAvailableStakeForSlashing();

    // ====== Constructor ======

    /**
     * @param _usdcToken Settlement token address (e.g., USDC)
     * @param _stakingToken Token used for arbitrator staking (can be same as USDC)
     * @param _owner Initial contract owner
     */
    constructor(address _usdcToken, address _stakingToken, address _owner) Ownable(_owner) {
        if (_usdcToken == address(0)) revert ZeroAddress();
        if (_stakingToken == address(0)) revert ZeroAddress();

        usdcToken = IERC20Metadata(_usdcToken);
        stakingToken = IERC20Metadata(_stakingToken);

        // Cache decimals for gas optimization
        usdcDecimals = IERC20Metadata(_usdcToken).decimals();
        stakingDecimals = IERC20Metadata(_stakingToken).decimals();

        // Set minimum stake to 1000 tokens (in token's native units)
        minimumStake = 1000 * (10 ** stakingDecimals);

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
     * @dev Update escrow timeout in seconds. Max = 30 days.
     */
    function updateEscrowTimeout(uint256 newTimeout) external onlyOwner {
        if (newTimeout > MAX_ESCROW_TIMEOUT) revert EscrowTimeoutTooHigh();
        uint256 old = escrowTimeout;
        escrowTimeout = newTimeout;
        emit EscrowTimeoutUpdated(old, newTimeout);
    }

    /**
     * @dev Update minimum stake required to become an arbitrator.
     */
    function updateMinimumStake(uint256 newMinimumStake) external onlyOwner {
        if (newMinimumStake == 0) revert StakingAmountTooLow();
        uint256 oldStake = minimumStake;
        minimumStake = newMinimumStake;
        emit MinimumStakeUpdated(oldStake, newMinimumStake);
    }

    /**
     * @dev Update arbitrator reward percentage.
     */
    function updateArbitratorReward(uint256 newRewardBps) external onlyOwner {
        if (newRewardBps > 1000) revert ArbitratorRewardTooHigh(); // Max 10%
        uint256 oldRewardBps = arbitratorRewardBps;
        arbitratorRewardBps = newRewardBps;
        emit ArbitratorRewardUpdated(oldRewardBps, newRewardBps);
    }

    /**
     * @dev Update slashing percentage for wrong decisions.
     */
    function updateSlashingRate(uint256 newSlashingBps) external onlyOwner {
        if (newSlashingBps > 5000) revert SlashingRateTooHigh(); // Max 50%
        uint256 oldSlashingBps = slashingBps;
        slashingBps = newSlashingBps;
        emit SlashingRateUpdated(oldSlashingBps, newSlashingBps);
    }

    /**
     * @dev Update maximum arbitrators to check during selection (gas optimization).
     */
    function updateMaxArbitratorsToCheck(uint256 newMax) external onlyOwner {
        if (newMax == 0 || newMax > 200) revert LimitOutOfRange();
        maxArbitratorsToCheck = newMax;
    }

    /**
     * @dev Update arbitrator response timeout.
     */
    function updateArbitratorTimeout(uint256 newTimeout) external onlyOwner {
        if (newTimeout > MAX_ARBITRATOR_TIMEOUT) revert ArbitratorTimeoutTooHigh();
        if (newTimeout == 0) revert ArbitratorTimeoutTooHigh();
        uint256 oldTimeout = arbitratorTimeout;
        arbitratorTimeout = newTimeout;
        emit ArbitratorTimeoutUpdated(oldTimeout, newTimeout);
    }

    // ====== Seller-facing ======

    /**
     * @notice Create a new order.
     * @param orderType Type/brand of gift card, free text (e.g., "Amazon")
     * @param description Additional details
     * @param price Settlement amount in token smallest units (USDC 6dp)
     */
    function createOrder(string memory orderType, string memory description, uint256 price) external whenNotPaused {
        if (bytes(orderType).length == 0 || bytes(orderType).length > 100) revert InvalidDescription();
        if (bytes(description).length == 0 || bytes(description).length > 1000) revert InvalidDescription();
        if (price == 0 || price > type(uint128).max) revert InvalidPrice(); // Prevent extremely large prices

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
            updatedAt: block.timestamp,
            escrowReleaseTime: 0,
            deliveryConfirmed: false,
            disputeStatus: DisputeStatus.None
        });

        orders[orderId] = newOrder;

        // Per-seller index
        uint256 sellerIdx = sellerOrderCount[msg.sender];
        sellerOrderByIndex[msg.sender][sellerIdx] = orderId;
        sellerOrderCount[msg.sender] = sellerIdx + 1;

        // Global pagination index
        orderIdByIndex[_orderCounter] = orderId;
        _orderCounter++;

        // Initialize status counter (no transition since this is creation)
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
        if (bytes(newOrderType).length == 0 || bytes(newOrderType).length > 100) revert InvalidDescription();
        if (bytes(newDescription).length == 0 || bytes(newDescription).length > 1000) revert InvalidDescription();
        if (newPrice == 0 || newPrice > type(uint128).max) revert InvalidPrice();

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

        _transitionOrderStatus(orderId, OrderStatus.Cancelled);

        emit OrderDelisted(orderId, msg.sender);
    }

    // ====== Arbitrator Staking ======

    /**
     * @notice Stake tokens to become an arbitrator.
     * @param amount Amount of staking tokens to stake
     */
    function stakeAsArbitrator(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert StakingAmountTooLow();

        ArbitratorStake storage stake = arbitratorStakes[msg.sender];

        // Transfer staking tokens to contract
        IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), amount);

        stake.stakedAmount += amount;
        stake.stakingTime = block.timestamp;
        totalStaked += amount;

        // Activate arbitrator if they meet minimum stake
        if (!stake.isActive && stake.stakedAmount >= minimumStake) {
            stake.isActive = true;
            activeArbitrators.push(msg.sender);
        }

        emit ArbitratorStaked(msg.sender, amount, stake.stakedAmount);
    }

    /**
     * @notice Unstake tokens and cease being an arbitrator.
     * @param amount Amount of staking tokens to unstake
     */
    function unstakeAsArbitrator(uint256 amount) external nonReentrant {
        ArbitratorStake storage stake = arbitratorStakes[msg.sender];

        if (amount == 0) revert StakingAmountTooLow();
        if (stake.stakedAmount < amount) revert InsufficientStake();
        if (stake.lockedAmount > 0) revert InsufficientStake(); // Cannot unstake with locked funds
        if (block.timestamp < stake.stakingTime + unstakingDelay) revert UnstakingDelayNotMet();

        stake.stakedAmount -= amount;
        totalStaked -= amount;

        // Deactivate if below minimum stake
        if (stake.isActive && stake.stakedAmount < minimumStake) {
            stake.isActive = false;
            _removeFromActiveArbitrators(msg.sender);
        }

        // Transfer tokens back
        IERC20(stakingToken).safeTransfer(msg.sender, amount);

        emit ArbitratorUnstaked(msg.sender, amount, stake.stakedAmount);
    }

    // ====== Buyer-facing ======

    /**
     * @notice Buy (match) an active order. Holds funds in escrow with automatic release timeout.
     * @dev Requires prior ERC20 approval from buyer to this contract for at least `price`.
     */
    function matchOrder(bytes32 orderId) external nonReentrant whenNotPaused {
        Order storage order = orders[orderId];
        if (order.orderId == 0) revert OrderNotFound();
        if (order.status != OrderStatus.Active) revert OrderNotActive();
        if (msg.sender == order.seller) revert CannotBuyOwnOrder();

        uint256 price = order.price;
        uint256 releaseTime = block.timestamp + escrowTimeout;

        // Pull funds into contract escrow
        IERC20(usdcToken).safeTransferFrom(msg.sender, address(this), price);

        order.buyer = msg.sender;
        order.escrowReleaseTime = releaseTime;
        order.deliveryConfirmed = false;
        order.disputeStatus = DisputeStatus.None;

        _transitionOrderStatus(orderId, OrderStatus.Escrowed);

        emit OrderMatched(orderId, msg.sender, order.seller, price, releaseTime);
    }

    /**
     * @notice Confirm delivery of gift card. Releases funds to seller immediately.
     * @dev Only the buyer can confirm delivery.
     */
    function confirmDelivery(bytes32 orderId) external nonReentrant whenNotPaused {
        Order storage order = orders[orderId];
        if (order.orderId == 0) revert OrderNotFound();
        if (order.status != OrderStatus.Escrowed) revert OrderNotEscrowed();
        if (msg.sender != order.buyer) revert NotOrderBuyer();
        if (order.deliveryConfirmed) revert DeliveryAlreadyConfirmed();
        if (order.disputeStatus != DisputeStatus.None) revert DisputeAlreadyRaised();

        order.deliveryConfirmed = true;
        _transitionOrderStatus(orderId, OrderStatus.Completed);
        _releaseFundsToSeller(orderId);

        emit DeliveryConfirmed(orderId, msg.sender);
    }

    /**
     * @notice Raise a dispute for an escrowed order. Must be within dispute window.
     * @param orderId The order to dispute
     * @param reason Description of the dispute
     */
    function raiseDispute(bytes32 orderId, string memory reason) external whenNotPaused {
        Order storage order = orders[orderId];
        if (order.orderId == 0) revert OrderNotFound();
        if (order.status != OrderStatus.Escrowed) revert OrderNotEscrowed();
        if (msg.sender != order.buyer) revert NotOrderBuyer();
        if (order.disputeStatus != DisputeStatus.None) revert DisputeAlreadyRaised();
        if (block.timestamp >= order.escrowReleaseTime) revert DisputeWindowExpired();
        if (bytes(reason).length == 0 || bytes(reason).length > 500) revert InvalidDescription();

        // Calculate required stake for this dispute (percentage of order value) with overflow protection
        uint256 requiredStake;
        if (order.price > type(uint256).max / 500) {
            requiredStake = type(uint256).max; // Prevent overflow
        } else {
            requiredStake = (order.price * 500) / 10_000; // 5% of order value
        }
        disputeStakeRequirement[orderId] = requiredStake;

        address arbitrator = _assignArbitrator(requiredStake);
        if (arbitrator == address(0)) revert NoActiveArbitrators();

        Dispute memory newDispute = Dispute({
            orderId: orderId,
            buyer: order.buyer,
            seller: order.seller,
            arbitrator: arbitrator,
            reason: reason,
            status: DisputeStatus.InArbitration,
            raisedAt: block.timestamp,
            resolvedAt: 0,
            buyerWins: false,
            challenged: false
        });

        disputes[orderId] = newDispute;
        disputeCount[arbitrator]++;

        order.disputeStatus = DisputeStatus.InArbitration;
        _transitionOrderStatus(orderId, OrderStatus.Disputed);

        emit DisputeRaised(orderId, order.buyer, arbitrator, reason);
    }

    /**
     * @notice Arbitrator resolves a dispute.
     * @param orderId The disputed order
     * @param buyerWins True if buyer should get refund, false if seller should get payment
     * @param resolution Description of the resolution
     */
    function resolveDispute(bytes32 orderId, bool buyerWins, string memory resolution)
        external
        nonReentrant
        whenNotPaused
    {
        Order storage order = orders[orderId];
        Dispute storage dispute = disputes[orderId];
        ArbitratorStake storage arbitratorStake = arbitratorStakes[msg.sender];

        if (order.orderId == 0) revert OrderNotFound();
        if (dispute.orderId == 0) revert NoDisputeFound();
        if (msg.sender != dispute.arbitrator) revert NotAuthorizedArbitrator();
        if (dispute.status != DisputeStatus.InArbitration) revert DisputeNotInArbitration();
        if (!arbitratorStake.isActive) revert ArbitratorNotActive();

        dispute.status = DisputeStatus.Resolved;
        dispute.resolvedAt = block.timestamp;
        dispute.buyerWins = buyerWins;

        // Calculate arbitrator reward with overflow protection
        uint256 reward;
        {
            // Check for multiplication overflow before calculation
            if (order.price > type(uint256).max / arbitratorRewardBps) {
                reward = 0; // Prevent overflow, fallback to zero reward
            } else {
                reward = (order.price * arbitratorRewardBps) / 10_000;
            }
            // Additional check that reward doesn't exceed order price
            if (reward > order.price) {
                reward = order.price; // Cap reward to order price
            }
        }
        uint256 requiredStake = disputeStakeRequirement[orderId];

        // Release locked stake and reward arbitrator
        arbitratorStake.lockedAmount -= requiredStake;
        arbitratorStake.totalRewards += reward;
        arbitratorStake.correctDecisions++; // Assume correct for now, could be challenged later
        arbitratorStake.totalDecisions++;

        order.disputeStatus = DisputeStatus.Resolved;

        // Transfer reward to arbitrator first
        IERC20(usdcToken).safeTransfer(msg.sender, reward);

        // Calculate remaining amount after arbitrator reward
        uint256 remainingAmount = order.price - reward;

        if (buyerWins) {
            _transitionOrderStatus(orderId, OrderStatus.Refunded);
            _refundToBuyer(orderId, remainingAmount);
        } else {
            _transitionOrderStatus(orderId, OrderStatus.Completed);
            _releaseFundsToSeller(orderId, remainingAmount);
        }

        emit ArbitratorRewarded(msg.sender, reward, orderId);
        emit DisputeResolved(orderId, msg.sender, buyerWins, resolution);
    }

    /**
     * @notice Challenge an arbitrator decision (governance function).
     * @dev This would typically be called by a DAO or governance system.
     *      This reverses the dispute resolution and requires manual re-resolution.
     */
    function challengeArbitratorDecision(bytes32 orderId) external onlyOwner nonReentrant {
        Order storage order = orders[orderId];
        Dispute storage dispute = disputes[orderId];
        ArbitratorStake storage arbitratorStake = arbitratorStakes[dispute.arbitrator];

        if (order.orderId == 0) revert OrderNotFound();
        if (dispute.status != DisputeStatus.Resolved) revert DisputeNotResolved();
        if (dispute.challenged) revert DisputeAlreadyChallenged();

        // Cache addresses to prevent reentrancy issues
        address arbitratorAddr = dispute.arbitrator;

        // Mark as challenged to prevent repeat calls
        dispute.challenged = true;

        // Revert order to disputed state for manual re-resolution
        order.disputeStatus = DisputeStatus.InArbitration;
        _transitionOrderStatus(orderId, OrderStatus.Disputed);

        // Reset dispute status to allow re-resolution
        dispute.status = DisputeStatus.InArbitration;
        dispute.resolvedAt = 0;
        dispute.raisedAt = block.timestamp; // Reset timeout for new arbitrator

        // Slash arbitrator stake - only from available (unlocked) portion
        uint256 availableStake = arbitratorStake.stakedAmount - arbitratorStake.lockedAmount;
        if (availableStake == 0) revert InsufficientAvailableStakeForSlashing();

        // Calculate slash amount with overflow protection
        uint256 maxSlashAmount;
        if (arbitratorStake.stakedAmount > type(uint256).max / slashingBps) {
            maxSlashAmount = arbitratorStake.stakedAmount; // Prevent overflow, cap at full stake
        } else {
            maxSlashAmount = (arbitratorStake.stakedAmount * slashingBps) / 10_000;
        }
        uint256 slashAmount = maxSlashAmount > availableStake ? availableStake : maxSlashAmount;

        arbitratorStake.stakedAmount -= slashAmount;
        arbitratorStake.totalSlashed += slashAmount;

        // Validate invariants after slashing
        _validateArbitratorInvariants(arbitratorAddr);

        // Revert the correct decision count with underflow protection
        if (arbitratorStake.correctDecisions > 0) {
            arbitratorStake.correctDecisions--;
        }

        totalStaked -= slashAmount;

        // Deactivate if below minimum stake
        if (arbitratorStake.isActive && arbitratorStake.stakedAmount < minimumStake) {
            arbitratorStake.isActive = false;
            _removeFromActiveArbitrators(arbitratorAddr);
        }

        // Note: Fund recovery from wrong resolution is complex and may require:
        // - Legal/governance processes to recover funds from recipients
        // - Insurance/treasury funds to cover wrongly distributed amounts
        // - Multi-signature approval for fund recovery operations
        // For safety, we don't automatically attempt fund recovery here
        // Instead, this marks the dispute for manual governance intervention

        // Transfer slashed amount to treasury
        IERC20(stakingToken).safeTransfer(owner(), slashAmount);

        emit ArbitratorSlashed(arbitratorAddr, slashAmount, orderId);
    }

    /**
     * @notice Reassign a stale dispute to a new arbitrator when the current one is unresponsive.
     * @param orderId The disputed order to reassign
     * @dev Can be called by anyone after arbitrator timeout expires
     */
    function reassignStaleDispute(bytes32 orderId) external nonReentrant whenNotPaused {
        Order storage order = orders[orderId];
        Dispute storage dispute = disputes[orderId];

        if (order.orderId == 0) revert OrderNotFound();
        if (dispute.status != DisputeStatus.InArbitration) revert DisputeNotInArbitration();
        if (block.timestamp < dispute.raisedAt + arbitratorTimeout) revert ArbitratorTimeoutNotExpired();

        address oldArbitrator = dispute.arbitrator;
        ArbitratorStake storage oldStake = arbitratorStakes[oldArbitrator];
        uint256 requiredStake = disputeStakeRequirement[orderId];

        // Release locked stake from old arbitrator
        oldStake.lockedAmount -= requiredStake;
        disputeCount[oldArbitrator]--;

        // Find new arbitrator
        address newArbitrator = _assignArbitrator(requiredStake);
        if (newArbitrator == address(0)) revert NoActiveArbitrators();

        // Update dispute
        dispute.arbitrator = newArbitrator;
        dispute.raisedAt = block.timestamp; // Reset timeout
        disputeCount[newArbitrator]++;

        emit DisputeReassigned(orderId, oldArbitrator, newArbitrator);
    }

    /**
     * @notice Force resolve a dispute that has been stale for too long (emergency function).
     * @param orderId The disputed order to force resolve
     * @param buyerWins Whether buyer wins the dispute
     * @dev Can only be called by owner after 2x arbitrator timeout
     */
    function forceResolveStaleDispute(bytes32 orderId, bool buyerWins) external onlyOwner nonReentrant {
        Order storage order = orders[orderId];
        Dispute storage dispute = disputes[orderId];

        if (order.orderId == 0) revert OrderNotFound();
        if (dispute.status != DisputeStatus.InArbitration) revert DisputeNotInArbitration();
        if (block.timestamp < dispute.raisedAt + (arbitratorTimeout * 2)) revert DisputeNotStale();

        address arbitrator = dispute.arbitrator;
        ArbitratorStake storage arbitratorStake = arbitratorStakes[arbitrator];
        uint256 requiredStake = disputeStakeRequirement[orderId];

        // Release locked stake but don't reward the absent arbitrator
        arbitratorStake.lockedAmount -= requiredStake;
        arbitratorStake.totalDecisions++; // Count as decision but not correct
        disputeCount[arbitrator]--;

        dispute.status = DisputeStatus.Resolved;
        dispute.resolvedAt = block.timestamp;
        dispute.buyerWins = buyerWins;

        order.disputeStatus = DisputeStatus.Resolved;

        if (buyerWins) {
            _transitionOrderStatus(orderId, OrderStatus.Refunded);
            _refundToBuyer(orderId);
        } else {
            _transitionOrderStatus(orderId, OrderStatus.Completed);
            _releaseFundsToSeller(orderId);
        }

        emit StaleDisputeForceResolved(orderId, arbitrator, buyerWins);
    }

    /**
     * @notice Release escrowed funds automatically after timeout if no dispute.
     * @dev Can be called by anyone after the timeout period.
     */
    function releaseEscrowAfterTimeout(bytes32 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        if (order.orderId == 0) revert OrderNotFound();
        if (order.status != OrderStatus.Escrowed) revert OrderNotEscrowed();
        if (order.disputeStatus != DisputeStatus.None) revert DisputeAlreadyRaised();
        if (block.timestamp < order.escrowReleaseTime) revert EscrowNotReleasable();

        _transitionOrderStatus(orderId, OrderStatus.Completed);
        _releaseFundsToSeller(orderId);
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
        if (bytes(comment).length > 1000) revert InvalidDescription(); // Limit comment length

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

    // ====== Internal Functions ======

    /**
     * @dev Centralized order status transition to prevent statusCounts desync.
     */
    function _transitionOrderStatus(bytes32 orderId, OrderStatus newStatus) internal {
        Order storage order = orders[orderId];
        OrderStatus oldStatus = order.status;

        if (oldStatus == newStatus) return; // No change needed

        // Update counters atomically
        statusCounts[oldStatus]--;
        statusCounts[newStatus]++;

        // Update order
        order.status = newStatus;
        order.updatedAt = block.timestamp;
    }

    /**
     * @dev Validate arbitrator stake invariants to prevent invalid states.
     */
    function _validateArbitratorInvariants(address arbitrator) internal view {
        ArbitratorStake storage stake = arbitratorStakes[arbitrator];
        require(stake.stakedAmount >= stake.lockedAmount, "Invariant violated: staked < locked");
    }

    /**
     * @dev Assign arbitrator using simple stake-weighted selection (gas safe).
     */
    function _assignArbitrator(uint256 requiredStake) internal returns (address) {
        if (activeArbitrators.length == 0) return address(0);

        // Limit checks to prevent gas issues
        uint256 checkCount =
            activeArbitrators.length > maxArbitratorsToCheck ? maxArbitratorsToCheck : activeArbitrators.length;

        // Generate random starting point for fairness when limiting checks
        uint256 randomStart = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, requiredStake)))
            % activeArbitrators.length;

        // Find eligible arbitrators and calculate weights
        address[] memory eligibleArbitrators = new address[](checkCount);
        uint256[] memory weights = new uint256[](checkCount);
        uint256 totalWeight = 0;
        uint256 eligibleCount = 0;

        for (uint256 i = 0; i < checkCount; i++) {
            uint256 index = (randomStart + i) % activeArbitrators.length;
            address arbitrator = activeArbitrators[index];
            ArbitratorStake storage stake = arbitratorStakes[arbitrator];
            uint256 availableStake = stake.stakedAmount - stake.lockedAmount;

            // Check if arbitrator is eligible
            if (stake.isActive && availableStake >= requiredStake) {
                eligibleArbitrators[eligibleCount] = arbitrator;
                weights[eligibleCount] = availableStake; // Stake-weighted
                totalWeight += availableStake;
                eligibleCount++;
            }
        }

        // If we found eligible arbitrators, do weighted selection
        if (eligibleCount > 0) {
            return _selectWeightedArbitrator(eligibleArbitrators, weights, eligibleCount, totalWeight, requiredStake);
        }

        return address(0); // No eligible arbitrator found
    }

    /**
     * @dev Perform stake-weighted random selection from eligible arbitrators.
     */
    function _selectWeightedArbitrator(
        address[] memory eligibleArbitrators,
        uint256[] memory weights,
        uint256 eligibleCount,
        uint256 totalWeight,
        uint256 requiredStake
    ) internal returns (address) {
        // Generate random value for weighted selection with more entropy
        uint256 randomValue = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao,
                    totalWeight,
                    eligibleCount,
                    msg.sender, // Add caller address for entropy
                    gasleft(), // Add remaining gas for entropy
                    blockhash(block.number - 1) // Add previous block hash
                )
            )
        ) % totalWeight;

        uint256 currentWeight = 0;

        // Find the selected arbitrator based on weighted random selection
        for (uint256 i = 0; i < eligibleCount; i++) {
            currentWeight += weights[i];
            if (randomValue < currentWeight) {
                // Lock stake for this dispute
                arbitratorStakes[eligibleArbitrators[i]].lockedAmount += requiredStake;
                return eligibleArbitrators[i];
            }
        }

        // Fallback (should never reach here, but ensures we always return someone)
        arbitratorStakes[eligibleArbitrators[0]].lockedAmount += requiredStake;
        return eligibleArbitrators[0];
    }

    /**
     * @dev Remove arbitrator from active list.
     */
    function _removeFromActiveArbitrators(address arbitrator) internal {
        for (uint256 i = 0; i < activeArbitrators.length; i++) {
            if (activeArbitrators[i] == arbitrator) {
                activeArbitrators[i] = activeArbitrators[activeArbitrators.length - 1];
                activeArbitrators.pop();
                break;
            }
        }
    }

    /**
     * @dev Release funds to seller with commission.
     */
    function _releaseFundsToSeller(bytes32 orderId) internal {
        _releaseFundsToSeller(orderId, orders[orderId].price);
    }

    /**
     * @dev Release funds to seller with commission from specified amount.
     */
    function _releaseFundsToSeller(bytes32 orderId, uint256 amount) internal {
        Order storage order = orders[orderId];

        // Calculate commission with overflow protection based on the full order price
        uint256 commissionAmount;
        if (order.price > type(uint256).max / commissionFeeBps) {
            commissionAmount = order.price; // Prevent overflow, cap at full price
        } else {
            commissionAmount = (order.price * commissionFeeBps) / 10_000;
        }

        // Ensure commission doesn't exceed amount
        if (commissionAmount > amount) {
            commissionAmount = amount;
        }

        uint256 sellerAmount = amount - commissionAmount;

        // Cache addresses to prevent state changes during external calls
        address seller = order.seller;
        address recipient = commissionRecipient;

        // External interactions last (CEI pattern)
        IERC20(usdcToken).safeTransfer(seller, sellerAmount);

        if (commissionAmount > 0) {
            IERC20(usdcToken).safeTransfer(recipient, commissionAmount);
        }

        emit FundsReleased(orderId, seller, sellerAmount, "Released to seller");
    }

    /**
     * @dev Refund full amount to buyer.
     */
    function _refundToBuyer(bytes32 orderId) internal {
        _refundToBuyer(orderId, orders[orderId].price);
    }

    /**
     * @dev Refund specified amount to buyer.
     */
    function _refundToBuyer(bytes32 orderId, uint256 amount) internal {
        Order storage order = orders[orderId];

        // Cache buyer address to prevent state changes during external calls
        address buyer = order.buyer;

        // External interactions last (CEI pattern)
        IERC20(usdcToken).safeTransfer(buyer, amount);

        emit FundsReleased(orderId, buyer, amount, "Refunded to buyer");
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
        returns (
            uint256 activeCount,
            uint256 escrowedCount,
            uint256 disputedCount,
            uint256 completedCount,
            uint256 cancelledCount,
            uint256 refundedCount,
            uint256 expiredCount
        )
    {
        activeCount = statusCounts[OrderStatus.Active];
        escrowedCount = statusCounts[OrderStatus.Escrowed];
        disputedCount = statusCounts[OrderStatus.Disputed];
        completedCount = statusCounts[OrderStatus.Completed];
        cancelledCount = statusCounts[OrderStatus.Cancelled];
        refundedCount = statusCounts[OrderStatus.Refunded];
        expiredCount = statusCounts[OrderStatus.Expired];
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

    /**
     * @notice Get dispute details for an order.
     */
    function getDispute(bytes32 orderId) external view returns (Dispute memory) {
        if (disputes[orderId].orderId == 0) revert NoDisputeFound();
        return disputes[orderId];
    }

    /**
     * @notice Check if an order can be disputed (within dispute window).
     */
    function canRaiseDispute(bytes32 orderId) external view returns (bool) {
        Order storage order = orders[orderId];
        if (order.orderId == 0) return false;
        if (order.status != OrderStatus.Escrowed) return false;
        if (order.disputeStatus != DisputeStatus.None) return false;
        return block.timestamp < order.escrowReleaseTime;
    }

    /**
     * @notice Check if escrow can be released (timeout reached, no dispute).
     */
    function canReleaseEscrow(bytes32 orderId) external view returns (bool) {
        Order storage order = orders[orderId];
        if (order.orderId == 0) return false;
        if (order.status != OrderStatus.Escrowed) return false;
        if (order.disputeStatus != DisputeStatus.None) return false;
        return block.timestamp >= order.escrowReleaseTime;
    }

    /**
     * @notice Get time remaining until escrow auto-release.
     */
    function getEscrowTimeRemaining(bytes32 orderId) external view returns (uint256) {
        Order storage order = orders[orderId];
        if (order.orderId == 0) revert OrderNotFound();
        if (order.status != OrderStatus.Escrowed) return 0;
        if (block.timestamp >= order.escrowReleaseTime) return 0;
        return order.escrowReleaseTime - block.timestamp;
    }

    /**
     * @notice Check if a dispute can be reassigned due to arbitrator timeout.
     */
    function canReassignDispute(bytes32 orderId) external view returns (bool) {
        Order storage order = orders[orderId];
        Dispute storage dispute = disputes[orderId];

        if (order.orderId == 0) return false;
        if (dispute.status != DisputeStatus.InArbitration) return false;
        return block.timestamp >= dispute.raisedAt + arbitratorTimeout;
    }

    /**
     * @notice Check if a dispute can be force resolved due to extended inactivity.
     */
    function canForceResolveDispute(bytes32 orderId) external view returns (bool) {
        Order storage order = orders[orderId];
        Dispute storage dispute = disputes[orderId];

        if (order.orderId == 0) return false;
        if (dispute.status != DisputeStatus.InArbitration) return false;
        return block.timestamp >= dispute.raisedAt + (arbitratorTimeout * 2);
    }

    /**
     * @notice Get time remaining until arbitrator timeout for a dispute.
     */
    function getArbitratorTimeRemaining(bytes32 orderId) external view returns (uint256) {
        Dispute storage dispute = disputes[orderId];

        if (dispute.orderId == 0) revert NoDisputeFound();
        if (dispute.status != DisputeStatus.InArbitration) return 0;

        uint256 deadline = dispute.raisedAt + arbitratorTimeout;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /**
     * @notice Get all active arbitrators (paginated).
     */
    function getActiveArbitratorsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory arbitrators, uint256 total)
    {
        if (limit == 0 || limit > 100) revert LimitOutOfRange();

        total = activeArbitrators.length;

        if (offset >= total) {
            return (new address[](0), total);
        }

        uint256 actual = offset + limit > total ? (total - offset) : limit;
        arbitrators = new address[](actual);

        for (uint256 i = 0; i < actual; i++) {
            arbitrators[i] = activeArbitrators[offset + i];
        }

        return (arbitrators, total);
    }

    /**
     * @notice Get arbitrator staking information.
     */
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
        )
    {
        ArbitratorStake storage stake = arbitratorStakes[arbitrator];
        return (
            stake.stakedAmount,
            stake.lockedAmount,
            stake.totalRewards,
            stake.totalSlashed,
            stake.correctDecisions,
            stake.totalDecisions,
            stake.stakingTime,
            stake.isActive
        );
    }

    /**
     * @notice Check if address is active arbitrator.
     */
    function isActiveArbitrator(address arbitrator) external view returns (bool) {
        return arbitratorStakes[arbitrator].isActive;
    }

    /**
     * @notice Get total staking statistics.
     */
    function getStakingStats()
        external
        view
        returns (
            uint256 totalStakedAmount,
            uint256 activeArbitratorsCount,
            uint256 minimumStakeRequired,
            uint256 arbitratorRewardRate,
            uint256 slashingRate
        )
    {
        return (totalStaked, activeArbitrators.length, minimumStake, arbitratorRewardBps, slashingBps);
    }
}
