// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title dotBots Market v2 - escrow market for one collection: listings, offers, collection offers, sweep.
/// @notice No approvals ever. Every action that hands a bot to the market is ONE
///         collection.safeTransferFrom(holder, market, tokenId, data) call; `data` says what to do:
///           - abi.encode(uint256 priceWei)                         list at a fixed price (same as v1)
///           - abi.encode(uint8(1), uint256 priceWei, uint256 0)     list at a fixed price
///           - abi.encode(uint8(2), uint256 offerId, uint256 minPrice) accept offer `offerId` on this bot
///           - abi.encode(uint8(3), uint256 collOfferId, uint256 minPrice) fill one unit of a collection offer
///         Anything else reverts, so the transfer fails and the bot stays with its holder.
///         A bot that is already listed (in escrow) is accepted into an offer by its seller with
///         acceptOfferForListed / acceptCollectionOfferForListed.
///         Offers escrow BNB in this contract. The offerer can cancel and get the BNB back at any time,
///         also while paused; after expiry anyone can trigger the refund to the offerer.
///         Fees: the lower of the fee when the listing/offer was made and the fee now; hard cap 5%.
///         Seller always receives price - fee. If a BNB payment cannot be delivered it is kept for withdraw().
/// @dev Owner powers (owner = team Safe on mainnet): pause / unpause trading; set the fee within MAX_FEE_BPS;
///      change the fee recipient; return a bot that arrived WITHOUT a listing, or a foreign NFT.
///      The owner can never move a listed bot or touch escrowed or deferred BNB. No proxy.
contract DotBotsMarketV2 is IERC721Receiver, Ownable2Step, Pausable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.UintSet;

    string public constant VERSION = "2.0.0";
    uint256 public constant MAX_FEE_BPS = 500; // 5%, can never be raised
    uint256 public constant MAX_PRICE = type(uint128).max;
    uint256 public constant MIN_OFFER = 1e14; // 0.0001 BNB per bot, keeps dust offers out
    uint256 public constant MAX_OFFER_DURATION = 180 days;
    uint256 public constant MAX_COLLECTION_QTY = 100;
    uint256 public constant MAX_BATCH = 50;
    uint256 public constant PAY_GAS = 50_000;

    uint8 internal constant OP_LIST = 1;
    uint8 internal constant OP_ACCEPT_OFFER = 2;
    uint8 internal constant OP_ACCEPT_COLLECTION = 3;

    // sale kinds in Sold
    uint8 public constant KIND_LISTING = 0;
    uint8 public constant KIND_OFFER = 1;
    uint8 public constant KIND_COLLECTION_OFFER = 2;

    // skip reasons in SweepSkipped
    uint8 public constant SKIP_NOT_LISTED = 1;
    uint8 public constant SKIP_PRICE_ABOVE_MAX = 2;
    uint8 public constant SKIP_OWN_LISTING = 3;

    IERC721 public immutable collection;
    address public feeRecipient;
    uint256 public feeBps;

    struct Listing {
        address seller;
        uint96 feeBps;
        uint256 price;
    }

    struct Offer {
        address buyer;
        uint64 expiry;
        uint32 feeBps;
        uint256 tokenId;
        uint256 price;
    }

    struct CollectionOffer {
        address buyer;
        uint64 expiry;
        uint32 feeBps;
        uint128 priceEach;
        uint128 remaining;
    }

    mapping(uint256 => Listing) private _listings;
    EnumerableSet.UintSet private _listed;
    mapping(address => EnumerableSet.UintSet) private _sellerListings;

    uint256 public nextOfferId = 1;
    mapping(uint256 => Offer) private _offers;
    EnumerableSet.UintSet private _activeOffers;
    mapping(uint256 => EnumerableSet.UintSet) private _tokenOffers;
    mapping(address => EnumerableSet.UintSet) private _buyerOffers;

    uint256 public nextCollectionOfferId = 1;
    mapping(uint256 => CollectionOffer) private _collOffers;
    EnumerableSet.UintSet private _activeCollOffers;
    mapping(address => EnumerableSet.UintSet) private _buyerCollOffers;

    /// @notice BNB held for live single-bot offers and collection offers.
    uint256 public totalOfferEscrow;
    mapping(address => uint256) public pendingWithdrawals;
    uint256 public totalPending;

    // stats (for pages without an indexer)
    uint256 public totalVolume;
    uint256 public totalSales;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event PriceUpdated(uint256 indexed tokenId, address indexed seller, uint256 oldPrice, uint256 newPrice);
    event Cancelled(uint256 indexed tokenId, address indexed seller);
    event Sold(
        uint256 indexed tokenId,
        address indexed seller,
        address indexed buyer,
        uint256 price,
        uint256 fee,
        uint8 kind,
        uint256 offerId
    );
    event SweepSkipped(uint256 indexed tokenId, address indexed buyer, uint8 reason);
    event OfferMade(uint256 indexed offerId, uint256 indexed tokenId, address indexed buyer, uint256 price, uint64 expiry);
    event OfferCancelled(uint256 indexed offerId, uint256 indexed tokenId, address indexed buyer, uint256 refund, bool expired);
    event OfferAccepted(uint256 indexed offerId, uint256 indexed tokenId, address indexed seller);
    event CollectionOfferMade(uint256 indexed offerId, address indexed buyer, uint256 priceEach, uint256 quantity, uint64 expiry);
    event CollectionOfferFilled(uint256 indexed offerId, uint256 indexed tokenId, address indexed seller, uint256 remaining);
    event CollectionOfferCancelled(uint256 indexed offerId, address indexed buyer, uint256 refund, bool expired);
    event PaymentDeferred(address indexed to, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event FeeUpdated(uint256 oldBps, uint256 newBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event UnlistedReturned(uint256 indexed tokenId, address indexed to);
    event ForeignNftReturned(address indexed token, uint256 indexed tokenId, address indexed to);

    error WrongCollection();
    error BadPrice();
    error BadData();
    error NotListed();
    error NotSeller();
    error WrongPayment();
    error OwnListing();
    error FeeTooHigh();
    error ZeroAddress();
    error NothingToWithdraw();
    error TransferFailed();
    error IsListed();
    error NotHeld();
    error RenounceDisabled();
    error BadExpiry();
    error BadQuantity();
    error OfferNotActive();
    error OfferExpired();
    error NotOfferer();
    error NotExpired();
    error WrongToken();
    error OwnOffer();
    error PriceBelowMin();
    error TooMany();
    error LengthMismatch();

    constructor(address collection_, address owner_, address feeRecipient_, uint256 feeBps_) Ownable(owner_) {
        if (collection_ == address(0) || owner_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        collection = IERC721(collection_);
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        emit FeeUpdated(0, feeBps_);
        emit FeeRecipientUpdated(address(0), feeRecipient_);
    }

    function version() external pure returns (string memory) {
        return VERSION;
    }

    // ================================================================== receive entry point

    /// @notice Called by the collection during safeTransferFrom(holder, market, id, data). See the contract notice.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata data)
        external
        override
        nonReentrant
        whenNotPaused
        returns (bytes4)
    {
        if (msg.sender != address(collection)) revert WrongCollection();
        if (from == address(0)) revert BadData(); // no direct mints into the market
        if (data.length == 32) {
            _list(from, tokenId, abi.decode(data, (uint256)));
        } else if (data.length == 96) {
            (uint8 op, uint256 a, uint256 b) = abi.decode(data, (uint8, uint256, uint256));
            if (op == OP_LIST) {
                if (b != 0) revert BadData();
                _list(from, tokenId, a);
            } else if (op == OP_ACCEPT_OFFER) {
                _acceptOffer(a, tokenId, from, b);
            } else if (op == OP_ACCEPT_COLLECTION) {
                _acceptCollectionOffer(a, tokenId, from, b);
            } else {
                revert BadData();
            }
        } else {
            revert BadData();
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    // ================================================================== listings

    function _list(address seller, uint256 tokenId, uint256 price) private {
        if (price == 0 || price > MAX_PRICE) revert BadPrice();
        _listings[tokenId] = Listing({seller: seller, feeBps: uint96(feeBps), price: price});
        if (!_listed.add(tokenId)) revert IsListed(); // cannot happen: an escrowed bot cannot arrive twice
        _sellerListings[seller].add(tokenId);
        emit Listed(tokenId, seller, price);
    }

    function _unlist(uint256 tokenId, address seller) private {
        delete _listings[tokenId];
        if (!_listed.remove(tokenId)) revert NotListed();
        _sellerListings[seller].remove(tokenId);
    }

    /// @notice Seller changes the price of a live listing.
    function updatePrice(uint256 tokenId, uint256 newPrice) external nonReentrant whenNotPaused {
        Listing storage l = _listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (l.seller != msg.sender) revert NotSeller();
        if (newPrice == 0 || newPrice > MAX_PRICE) revert BadPrice();
        uint256 old = l.price;
        l.price = newPrice;
        emit PriceUpdated(tokenId, msg.sender, old, newPrice);
    }

    /// @notice Seller takes the bot back. Always available, also while paused.
    function cancel(uint256 tokenId) external nonReentrant {
        _cancel(tokenId);
    }

    /// @notice Cancel several of your listings in one tx. Always available, also while paused.
    function cancelMany(uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length > MAX_BATCH) revert TooMany();
        for (uint256 i; i < tokenIds.length; ++i) _cancel(tokenIds[i]);
    }

    function _cancel(uint256 tokenId) private {
        address seller = _listings[tokenId].seller;
        if (seller == address(0)) revert NotListed();
        if (seller != msg.sender) revert NotSeller();
        _unlist(tokenId, seller);
        emit Cancelled(tokenId, seller);
        collection.transferFrom(address(this), seller, tokenId);
    }

    // ================================================================== buy / sweep

    /// @notice Buy one listed bot. msg.value must equal the listed price exactly.
    function buy(uint256 tokenId) external payable nonReentrant whenNotPaused {
        Listing memory l = _listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (msg.sender == l.seller) revert OwnListing();
        if (msg.value != l.price) revert WrongPayment();
        _executeListingSale(tokenId, l);
    }

    /// @notice Sweep: buy several listings in one tx. For each id, buys it when it is still listed, not yours,
    ///         and priced at or below maxPrices[i]; otherwise skips it (SweepSkipped). Unspent BNB is returned.
    /// @return bought number of bots bought; spent total wei paid for them
    function buyMany(uint256[] calldata tokenIds, uint256[] calldata maxPrices)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 bought, uint256 spent)
    {
        uint256 n = tokenIds.length;
        if (n == 0 || n > MAX_BATCH) revert TooMany();
        if (maxPrices.length != n) revert LengthMismatch();
        for (uint256 i; i < n; ++i) {
            uint256 id = tokenIds[i];
            Listing memory l = _listings[id];
            uint8 reason;
            if (l.seller == address(0)) reason = SKIP_NOT_LISTED;
            else if (l.seller == msg.sender) reason = SKIP_OWN_LISTING;
            else if (l.price > maxPrices[i]) reason = SKIP_PRICE_ABOVE_MAX;
            if (reason != 0) {
                emit SweepSkipped(id, msg.sender, reason);
                continue;
            }
            spent += l.price;
            if (spent > msg.value) revert WrongPayment();
            ++bought;
            _executeListingSale(id, l);
        }
        uint256 refund = msg.value - spent;
        if (refund > 0) _pay(msg.sender, refund);
    }

    function _executeListingSale(uint256 tokenId, Listing memory l) private {
        uint256 fee = (l.price * _minFee(l.feeBps)) / 10_000;
        _unlist(tokenId, l.seller);
        totalVolume += l.price;
        ++totalSales;
        emit Sold(tokenId, l.seller, msg.sender, l.price, fee, KIND_LISTING, 0);
        if (fee > 0) _pay(feeRecipient, fee);
        _pay(l.seller, l.price - fee);
        collection.safeTransferFrom(address(this), msg.sender, tokenId);
    }

    // ================================================================== single-bot offers

    /// @notice Offer msg.value BNB for bot `tokenId`, valid until `expiry` (unix seconds). BNB is escrowed here.
    function makeOffer(uint256 tokenId, uint64 expiry) external payable nonReentrant whenNotPaused returns (uint256 id) {
        if (msg.value < MIN_OFFER || msg.value > MAX_PRICE) revert BadPrice();
        _checkExpiry(expiry);
        address holder = collection.ownerOf(tokenId); // reverts for a bot that does not exist
        if (holder == msg.sender) revert OwnOffer();
        if (holder == address(this) && _listings[tokenId].seller == msg.sender) revert OwnOffer();
        id = nextOfferId++;
        _offers[id] = Offer({buyer: msg.sender, expiry: expiry, feeBps: uint32(feeBps), tokenId: tokenId, price: msg.value});
        _activeOffers.add(id);
        _tokenOffers[tokenId].add(id);
        _buyerOffers[msg.sender].add(id);
        totalOfferEscrow += msg.value;
        emit OfferMade(id, tokenId, msg.sender, msg.value, expiry);
    }

    /// @notice Offerer cancels and gets the BNB back. Always available, also while paused or after expiry.
    function cancelOffer(uint256 offerId) external nonReentrant {
        _cancelOffer(offerId, false);
    }

    /// @notice Cancel several of your offers in one tx. Always available.
    function cancelOffers(uint256[] calldata offerIds) external nonReentrant {
        if (offerIds.length > MAX_BATCH) revert TooMany();
        for (uint256 i; i < offerIds.length; ++i) _cancelOffer(offerIds[i], false);
    }

    /// @notice Anyone may return the BNB of EXPIRED offers to their offerers. Always available.
    function refundExpiredOffers(uint256[] calldata offerIds) external nonReentrant {
        if (offerIds.length > MAX_BATCH) revert TooMany();
        for (uint256 i; i < offerIds.length; ++i) _cancelOffer(offerIds[i], true);
    }

    function _cancelOffer(uint256 offerId, bool expiredPath) private {
        Offer memory o = _offers[offerId];
        if (o.buyer == address(0)) revert OfferNotActive();
        bool expired = block.timestamp > o.expiry;
        if (expiredPath) {
            if (!expired) revert NotExpired();
        } else if (o.buyer != msg.sender) {
            revert NotOfferer();
        }
        _removeOffer(offerId, o);
        emit OfferCancelled(offerId, o.tokenId, o.buyer, o.price, expired);
        _pay(o.buyer, o.price);
    }

    function _removeOffer(uint256 offerId, Offer memory o) private {
        delete _offers[offerId];
        _activeOffers.remove(offerId);
        _tokenOffers[o.tokenId].remove(offerId);
        _buyerOffers[o.buyer].remove(offerId);
        totalOfferEscrow -= o.price;
    }

    /// @notice Seller of a LISTED bot accepts an offer on it: listing closes, bot goes to the offerer.
    function acceptOfferForListed(uint256 offerId, uint256 minPrice) external nonReentrant whenNotPaused {
        Offer memory o = _offers[offerId];
        if (o.buyer == address(0)) revert OfferNotActive();
        Listing memory l = _listings[o.tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (l.seller != msg.sender) revert NotSeller();
        _unlist(o.tokenId, l.seller);
        _acceptOffer(offerId, o.tokenId, l.seller, minPrice);
    }

    /// @dev bot is held by this contract when called; pays `seller`, sends the bot to the offerer
    function _acceptOffer(uint256 offerId, uint256 tokenId, address seller, uint256 minPrice) private {
        Offer memory o = _offers[offerId];
        if (o.buyer == address(0)) revert OfferNotActive();
        if (o.tokenId != tokenId) revert WrongToken();
        if (block.timestamp > o.expiry) revert OfferExpired();
        if (o.buyer == seller) revert OwnOffer();
        if (o.price < minPrice) revert PriceBelowMin();
        uint256 fee = (o.price * _minFee(o.feeBps)) / 10_000;
        _removeOffer(offerId, o);
        totalVolume += o.price;
        ++totalSales;
        emit OfferAccepted(offerId, tokenId, seller);
        emit Sold(tokenId, seller, o.buyer, o.price, fee, KIND_OFFER, offerId);
        collection.safeTransferFrom(address(this), o.buyer, tokenId);
        if (fee > 0) _pay(feeRecipient, fee);
        _pay(seller, o.price - fee);
    }

    // ================================================================== collection offers

    /// @notice Offer `priceEach` BNB for any `quantity` dotBots. msg.value must equal priceEach * quantity.
    function makeCollectionOffer(uint256 priceEach, uint256 quantity, uint64 expiry)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 id)
    {
        if (priceEach < MIN_OFFER || priceEach > MAX_PRICE) revert BadPrice();
        if (quantity == 0 || quantity > MAX_COLLECTION_QTY) revert BadQuantity();
        if (msg.value != priceEach * quantity) revert WrongPayment();
        _checkExpiry(expiry);
        id = nextCollectionOfferId++;
        _collOffers[id] = CollectionOffer({
            buyer: msg.sender,
            expiry: expiry,
            feeBps: uint32(feeBps),
            priceEach: uint128(priceEach),
            remaining: uint128(quantity)
        });
        _activeCollOffers.add(id);
        _buyerCollOffers[msg.sender].add(id);
        totalOfferEscrow += msg.value;
        emit CollectionOfferMade(id, msg.sender, priceEach, quantity, expiry);
    }

    /// @notice Offerer cancels what is left of a collection offer and gets that BNB back. Always available.
    function cancelCollectionOffer(uint256 offerId) external nonReentrant {
        _cancelCollectionOffer(offerId, false);
    }

    /// @notice Anyone may return the remaining BNB of EXPIRED collection offers. Always available.
    function refundExpiredCollectionOffers(uint256[] calldata offerIds) external nonReentrant {
        if (offerIds.length > MAX_BATCH) revert TooMany();
        for (uint256 i; i < offerIds.length; ++i) _cancelCollectionOffer(offerIds[i], true);
    }

    function _cancelCollectionOffer(uint256 offerId, bool expiredPath) private {
        CollectionOffer memory c = _collOffers[offerId];
        if (c.buyer == address(0)) revert OfferNotActive();
        bool expired = block.timestamp > c.expiry;
        if (expiredPath) {
            if (!expired) revert NotExpired();
        } else if (c.buyer != msg.sender) {
            revert NotOfferer();
        }
        uint256 refund = uint256(c.priceEach) * c.remaining;
        delete _collOffers[offerId];
        _activeCollOffers.remove(offerId);
        _buyerCollOffers[c.buyer].remove(offerId);
        totalOfferEscrow -= refund;
        emit CollectionOfferCancelled(offerId, c.buyer, refund, expired);
        _pay(c.buyer, refund);
    }

    /// @notice Seller of a LISTED bot fills one unit of a collection offer with it.
    function acceptCollectionOfferForListed(uint256 offerId, uint256 tokenId, uint256 minPrice)
        external
        nonReentrant
        whenNotPaused
    {
        Listing memory l = _listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (l.seller != msg.sender) revert NotSeller();
        _unlist(tokenId, l.seller);
        _acceptCollectionOffer(offerId, tokenId, l.seller, minPrice);
    }

    function _acceptCollectionOffer(uint256 offerId, uint256 tokenId, address seller, uint256 minPrice) private {
        CollectionOffer storage c = _collOffers[offerId];
        address buyer = c.buyer;
        if (buyer == address(0)) revert OfferNotActive();
        if (block.timestamp > c.expiry) revert OfferExpired();
        if (buyer == seller) revert OwnOffer();
        uint256 price = c.priceEach;
        if (price < minPrice) revert PriceBelowMin();
        uint256 fee = (price * _minFee(c.feeBps)) / 10_000;
        uint256 left = c.remaining - 1;
        if (left == 0) {
            delete _collOffers[offerId];
            _activeCollOffers.remove(offerId);
            _buyerCollOffers[buyer].remove(offerId);
        } else {
            c.remaining = uint128(left);
        }
        totalOfferEscrow -= price;
        totalVolume += price;
        ++totalSales;
        emit CollectionOfferFilled(offerId, tokenId, seller, left);
        emit Sold(tokenId, seller, buyer, price, fee, KIND_COLLECTION_OFFER, offerId);
        collection.safeTransferFrom(address(this), buyer, tokenId);
        if (fee > 0) _pay(feeRecipient, fee);
        _pay(seller, price - fee);
    }

    // ================================================================== payments

    function _checkExpiry(uint64 expiry) private view {
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_OFFER_DURATION) revert BadExpiry();
    }

    /// @dev The seller never pays more than the fee in force when the listing/offer was made; a cut applies at once.
    function _minFee(uint256 snap) private view returns (uint256) {
        return snap < feeBps ? snap : feeBps;
    }

    /// @dev Push the payment with a gas cap; if the receiver reverts or needs more gas, keep it for withdraw().
    function _pay(address to, uint256 amount) private {
        bool ok;
        assembly ("memory-safe") {
            ok := call(PAY_GAS, to, amount, 0, 0, 0, 0)
        }
        if (!ok) {
            pendingWithdrawals[to] += amount;
            totalPending += amount;
            emit PaymentDeferred(to, amount);
        }
    }

    /// @notice Pull a deferred payment. Always available, also while paused.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        totalPending -= amount;
        emit Withdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ================================================================== views

    function getListing(uint256 tokenId) external view returns (address seller, uint256 price, uint256 feeNow) {
        Listing memory l = _listings[tokenId];
        if (l.seller == address(0)) return (address(0), 0, 0);
        return (l.seller, l.price, _minFee(l.feeBps));
    }

    function isListed(uint256 tokenId) external view returns (bool) {
        return _listings[tokenId].seller != address(0);
    }

    function listingCount() external view returns (uint256) {
        return _listed.length();
    }

    function listingsPage(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, address[] memory sellers, uint256[] memory prices, uint256[] memory fees)
    {
        ids = _slice(_listed, offset, limit);
        sellers = new address[](ids.length);
        prices = new uint256[](ids.length);
        fees = new uint256[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            Listing memory l = _listings[ids[i]];
            sellers[i] = l.seller;
            prices[i] = l.price;
            fees[i] = _minFee(l.feeBps);
        }
    }

    function listingsOf(address seller, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        return _slice(_sellerListings[seller], offset, limit);
    }

    function listingCountOf(address seller) external view returns (uint256) {
        return _sellerListings[seller].length();
    }

    /// @return o the offer (buyer = 0 when not active); feeNow = fee a seller would pay if accepted now
    function getOffer(uint256 offerId) external view returns (Offer memory o, uint256 feeNow) {
        o = _offers[offerId];
        feeNow = o.buyer == address(0) ? 0 : _minFee(o.feeBps);
    }

    function offerCount() external view returns (uint256) {
        return _activeOffers.length();
    }

    function offersPage(uint256 offset, uint256 limit) external view returns (uint256[] memory ids, Offer[] memory offers) {
        ids = _slice(_activeOffers, offset, limit);
        offers = _loadOffers(ids);
    }

    function offerCountForToken(uint256 tokenId) external view returns (uint256) {
        return _tokenOffers[tokenId].length();
    }

    function offersForToken(uint256 tokenId, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, Offer[] memory offers)
    {
        ids = _slice(_tokenOffers[tokenId], offset, limit);
        offers = _loadOffers(ids);
    }

    function offersByBuyer(address buyer, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, Offer[] memory offers)
    {
        ids = _slice(_buyerOffers[buyer], offset, limit);
        offers = _loadOffers(ids);
    }

    /// @notice Highest unexpired offer on a bot (0 when none). Loops over that bot's offers.
    function bestOffer(uint256 tokenId) external view returns (uint256 offerId, uint256 price) {
        EnumerableSet.UintSet storage s = _tokenOffers[tokenId];
        uint256 n = s.length();
        for (uint256 i; i < n; ++i) {
            uint256 id = s.at(i);
            Offer storage o = _offers[id];
            if (block.timestamp <= o.expiry && o.price > price) {
                price = o.price;
                offerId = id;
            }
        }
    }

    function getCollectionOffer(uint256 offerId) external view returns (CollectionOffer memory c, uint256 feeNow) {
        c = _collOffers[offerId];
        feeNow = c.buyer == address(0) ? 0 : _minFee(c.feeBps);
    }

    function collectionOfferCount() external view returns (uint256) {
        return _activeCollOffers.length();
    }

    function collectionOffersPage(uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, CollectionOffer[] memory offers)
    {
        ids = _slice(_activeCollOffers, offset, limit);
        offers = _loadColl(ids);
    }

    function collectionOffersByBuyer(address buyer, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, CollectionOffer[] memory offers)
    {
        ids = _slice(_buyerCollOffers[buyer], offset, limit);
        offers = _loadColl(ids);
    }

    /// @notice Highest unexpired collection offer (0 when none).
    function bestCollectionOffer() external view returns (uint256 offerId, uint256 priceEach, uint256 remaining) {
        uint256 n = _activeCollOffers.length();
        for (uint256 i; i < n; ++i) {
            uint256 id = _activeCollOffers.at(i);
            CollectionOffer storage c = _collOffers[id];
            if (block.timestamp <= c.expiry && c.priceEach > priceEach) {
                priceEach = c.priceEach;
                remaining = c.remaining;
                offerId = id;
            }
        }
    }

    /// @notice Fee and seller amount for a given price at the current fee.
    function quote(uint256 price) external view returns (uint256 fee, uint256 sellerGets) {
        fee = (price * feeBps) / 10_000;
        sellerGets = price - fee;
    }

    function _slice(EnumerableSet.UintSet storage s, uint256 offset, uint256 limit)
        private
        view
        returns (uint256[] memory out)
    {
        uint256 n = s.length();
        if (offset >= n) return new uint256[](0);
        uint256 end = limit > n - offset ? n : offset + limit;
        out = new uint256[](end - offset);
        for (uint256 i; i < out.length; ++i) out[i] = s.at(offset + i);
    }

    function _loadOffers(uint256[] memory ids) private view returns (Offer[] memory r) {
        r = new Offer[](ids.length);
        for (uint256 i; i < ids.length; ++i) r[i] = _offers[ids[i]];
    }

    function _loadColl(uint256[] memory ids) private view returns (CollectionOffer[] memory r) {
        r = new CollectionOffer[](ids.length);
        for (uint256 i; i < ids.length; ++i) r[i] = _collOffers[ids[i]];
    }

    // ================================================================== owner (limited)

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setFee(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeUpdated(feeBps, newBps);
        feeBps = newBps;
    }

    function setFeeRecipient(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, r);
        feeRecipient = r;
    }

    /// @notice Return a bot that reached the market by plain transferFrom (never listed). Listed bots: IsListed.
    function returnUnlisted(uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (_listings[tokenId].seller != address(0)) revert IsListed();
        if (collection.ownerOf(tokenId) != address(this)) revert NotHeld();
        emit UnlistedReturned(tokenId, to);
        collection.transferFrom(address(this), to, tokenId);
    }

    function returnForeignNft(address token, uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (token == address(collection)) revert WrongCollection();
        if (to == address(0)) revert ZeroAddress();
        emit ForeignNftReturned(token, tokenId, to);
        IERC721(token).transferFrom(address(this), to, tokenId);
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
