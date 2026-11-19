// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IAgentIdRegistry {
    function handleOf(address account) external view returns (string memory);
}

interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title dotBots v3 - 2,222 bots, every one carries a .ai name, fully on-chain.
/// @notice - Public mint: one bot per registered .ai Agent ID, handle printed on the chest, rarity rolled at mint.
///           Step price in BNB via Chainlink: bots 1-1,000 $1.50, 1,001-2,000 $2.50, 2,001-2,122 $4.00.
///         - Every mint: 10% is shared equally by all bots alive (claimable by whoever holds them, it
///           travels with the NFT), 10% to the referrer if one holds a bot, the rest to the team.
///         - Team reserve: max 100 bots inside the 2,222, labelled "dotBots team" until gifted (owner assigns, recipient claims) to a
///           .ai Agent ID holder who has not minted yet; the bot then carries their handle.
///         - Fusion: burn 3 bots you hold + fee (default $1, owner-set, max $10) for 1 new bot with better odds. Supply only shrinks.
///         No approvals needed. No blacklist, no transfer lock, no proxy. Art and metadata 100% on-chain.
contract DotBots is ERC721, ERC2981, Ownable2Step, ReentrancyGuard {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 2222;
    uint256 public constant TEAM_RESERVE = 100;
    uint256 public constant PUBLIC_SUPPLY = MAX_SUPPLY - TEAM_RESERVE; // 2,122
    /// @notice Hard ceiling for any price the owner sets: $10 (18 decimals). Can never be raised.
    uint256 public constant MAX_PRICE_USD = 10e18;
    // owner-adjustable USD prices (18 decimals), each capped at MAX_PRICE_USD
    uint256 public tier1Usd = 15e17; // bots 1-1,000: $1.50
    uint256 public tier2Usd = 25e17; // bots 1,001-2,000: $2.50
    uint256 public tier3Usd = 4e18; // bots 2,001-2,122: $4.00
    uint256 public fusionFeeUsd = 1e18; // $1
    uint256 public constant HOLDER_BPS = 1000; // 10%
    uint256 public constant REFERRAL_BPS = 1000; // 10%
    uint256 public constant MAX_PRICE_AGE = 1 days;
    uint256 private constant ACC = 1e18;
    // oracle sanity bounds (8 decimals): a broken or manipulated feed outside $50 - $100,000 halts paid actions
    uint256 public constant MIN_BNB_USD = 50e8;
    uint256 public constant MAX_BNB_USD = 100_000e8;

    IAgentIdRegistry public immutable registry;
    IAggregatorV3 public immutable bnbUsdFeed;
    address public treasury;

    bool public mintOpen;
    bool public fusionOpen;
    uint256 public publicMinted;
    uint256 public teamMinted;
    uint256 public giveaways;
    uint256 public fusions;
    uint256 public liveSupply; // bots currently in existence
    uint256 private _nextId = 1;

    // accounting: the contract balance = teamBalance + referral owed + unclaimed holder share (+ dust)
    uint256 public teamBalance;
    uint256 public accPerBot; // cumulative holder share per bot, scaled by 1e18
    mapping(uint256 => uint256) public debtOf; // accPerBot already settled for a token
    mapping(address => uint256) public referralOwed;

    mapping(uint256 => uint256) public seedOf;
    mapping(uint256 => string) private _handleOfToken;
    mapping(bytes32 => uint256) public tokenOfHandle; // keccak(handle) => tokenId (stays used forever)
    mapping(uint256 => bool) public isTeamBot;
    mapping(uint256 => bool) public isFused;
    mapping(uint256 => address) public giftTo; // team bot => assigned recipient

    event Minted(address indexed to, uint256 indexed tokenId, string handle, uint256 paid, address referrer);
    event TeamMinted(address indexed to, uint256 firstId, uint256 quantity);
    event GivenAway(address indexed to, uint256 indexed tokenId, string handle);
    event GiftAssigned(uint256 indexed tokenId, address indexed to);
    event Fused(address indexed holder, uint256 a, uint256 b, uint256 c, uint256 indexed newId);
    event ShareClaimed(address indexed to, uint256 amount);
    event ReferralClaimed(address indexed to, uint256 amount);

    error BadPrice();
    error MintClosed();
    error FusionClosed();
    error NoAgentId();
    error HandleAlreadyUsed();
    error SoldOut();
    error BadQuantity();
    error Underpaid();
    error StalePrice();
    error TransferFailed();
    error ZeroAddress();
    error ReserveExhausted();
    error NotTeamBot();
    error AlreadyNamed();
    error NotHeldByOwner();
    error NotYourBot();
    error DuplicateToken();
    error NothingToClaim();
    error OnlyWallets();

    constructor(address owner_, address treasury_, address registry_, address feed_)
        ERC721("dotBots", "DOTBOT")
        Ownable(owner_)
    {
        if (owner_ == address(0) || treasury_ == address(0) || registry_ == address(0) || feed_ == address(0)) {
            revert ZeroAddress();
        }
        registry = IAgentIdRegistry(registry_);
        bnbUsdFeed = IAggregatorV3(feed_);
        treasury = treasury_;
        _setDefaultRoyalty(treasury_, 500); // 5%
    }

    // ------------------------------------------------------------------ mint

    /// @notice Mint your bot. Needs a registered .ai Agent ID (one bot per handle, ever).
    ///         referrer: a wallet holding a dotBot (or address(0)). Send >= unitPrice(); overpay is refunded.
    function mint(address referrer) external payable nonReentrant returns (uint256 tokenId) {
        if (!mintOpen) revert MintClosed();
        if (msg.sender != tx.origin) revert OnlyWallets(); // no contracts that revert on a bad roll
        if (publicMinted >= PUBLIC_SUPPLY) revert SoldOut();
        (string memory handle, bytes32 h) = _freshHandle(msg.sender);
        uint256 cost = unitPrice();
        if (msg.value < cost) revert Underpaid();

        // split: holders first (existing bots only), referral, team gets the rest
        uint256 toHolders = cost * HOLDER_BPS / 10_000;
        if (liveSupply > 0) accPerBot += toHolders * ACC / liveSupply;
        else toHolders = 0;
        uint256 toRef;
        if (referrer != address(0) && referrer != msg.sender && balanceOf(referrer) > 0) {
            toRef = cost * REFERRAL_BPS / 10_000;
            referralOwed[referrer] += toRef;
        } else {
            referrer = address(0);
        }
        teamBalance += cost - toHolders - toRef;

        tokenId = _nextId++;
        publicMinted++;
        tokenOfHandle[h] = tokenId;
        _handleOfToken[tokenId] = handle;
        _create(msg.sender, tokenId);
        emit Minted(msg.sender, tokenId, handle, cost, referrer);

        if (msg.value > cost) _send(msg.sender, msg.value - cost);
    }

    function _create(address to, uint256 id) private {
        seedOf[id] = uint256(keccak256(abi.encode(id, to, block.prevrandao, blockhash(block.number - 1))));
        debtOf[id] = accPerBot; // a new bot only earns from later mints
        liveSupply++;
        _safeMint(to, id);
    }

    function _freshHandle(address wallet) private view returns (string memory handle, bytes32 h) {
        handle = registry.handleOf(wallet);
        if (bytes(handle).length == 0) revert NoAgentId();
        h = keccak256(bytes(handle));
        if (tokenOfHandle[h] != 0) revert HandleAlreadyUsed();
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ------------------------------------------------------------------ holder share & referral

    function pendingOf(uint256 tokenId) public view returns (uint256) {
        _requireOwned(tokenId);
        return (accPerBot - debtOf[tokenId]) / ACC;
    }

    function pendingOfMany(uint256[] calldata ids) external view returns (uint256 total) {
        for (uint256 i; i < ids.length; ++i) total += pendingOf(ids[i]);
    }

    /// @notice Claim the holder share of bots you hold.
    function claim(uint256[] calldata ids) external nonReentrant {
        uint256 total = _settle(ids, msg.sender);
        if (total == 0) revert NothingToClaim();
        _send(msg.sender, total);
        emit ShareClaimed(msg.sender, total);
    }

    function _settle(uint256[] memory ids, address holder) private returns (uint256 total) {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (ownerOf(id) != holder) revert NotYourBot();
            total += (accPerBot - debtOf[id]) / ACC;
            debtOf[id] = accPerBot - ((accPerBot - debtOf[id]) % ACC); // keep sub-wei remainder
        }
    }

    function claimReferral() external nonReentrant {
        uint256 amt = referralOwed[msg.sender];
        if (amt == 0) revert NothingToClaim();
        referralOwed[msg.sender] = 0;
        _send(msg.sender, amt);
        emit ReferralClaimed(msg.sender, amt);
    }

    // ------------------------------------------------------------------ fusion

    /// @notice Burn 3 bots you hold, pay fusionPrice(), get 1 new bot with better odds.
    ///         Unclaimed share of the burned bots is paid to you. The new bot keeps the name of bot `a`.
    function fuse(uint256 a, uint256 b, uint256 c) external payable nonReentrant returns (uint256 newId) {
        if (!fusionOpen) revert FusionClosed();
        if (msg.sender != tx.origin) revert OnlyWallets();
        if (a == b || a == c || b == c) revert DuplicateToken();
        uint256 fee = fusionPrice();
        if (msg.value < fee) revert Underpaid();
        uint256[] memory ids = new uint256[](3);
        ids[0] = a; ids[1] = b; ids[2] = c;
        uint256 owed = _settle(ids, msg.sender);
        teamBalance += fee;

        newId = _nextId++;
        string memory handle = _handleOfToken[a];
        if (bytes(handle).length > 0) {
            _handleOfToken[newId] = handle;
            tokenOfHandle[keccak256(bytes(handle))] = newId;
        }
        isTeamBot[newId] = isTeamBot[a] && bytes(handle).length == 0;
        isFused[newId] = true;
        for (uint256 i; i < 3; ++i) {
            _burn(ids[i]);
        }
        liveSupply -= 3;
        fusions++;
        _create(msg.sender, newId);
        emit Fused(msg.sender, a, b, c, newId);

        uint256 back = owed + (msg.value - fee);
        if (back > 0) _send(msg.sender, back);
    }

    // ------------------------------------------------------------------ views for agents

    function _feed() private view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = bnbUsdFeed.latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > MAX_PRICE_AGE) revert StalePrice();
        if (uint256(answer) < MIN_BNB_USD || uint256(answer) > MAX_BNB_USD) revert StalePrice();
        return uint256(answer);
    }

    /// @notice Current USD price (18 decimals) of the next public bot.
    function priceUsd() public view returns (uint256) {
        if (publicMinted < 1000) return tier1Usd;
        if (publicMinted < 2000) return tier2Usd;
        return tier3Usd;
    }

    /// @notice BNB (wei) to send for the next public bot.
    function unitPrice() public view returns (uint256) {
        return (priceUsd() * 1e8) / _feed();
    }

    function fusionPrice() public view returns (uint256) {
        return (fusionFeeUsd * 1e8) / _feed();
    }

    function totalMinted() external view returns (uint256) {
        return publicMinted + teamMinted;
    }

    /// @notice 1 if this wallet can mint right now (open, supply left, unused Agent ID), else 0.
    function canMint(address wallet) external view returns (uint256) {
        if (!mintOpen || publicMinted >= PUBLIC_SUPPLY) return 0;
        string memory handle = registry.handleOf(wallet);
        if (bytes(handle).length == 0 || tokenOfHandle[keccak256(bytes(handle))] != 0) return 0;
        return 1;
    }

    function handleOfToken(uint256 tokenId) external view returns (string memory) {
        _requireOwned(tokenId);
        return _handleOfToken[tokenId];
    }

    // ------------------------------------------------------------------ owner

    function setMintOpen(bool open) external onlyOwner {
        mintOpen = open;
    }

    function setFusionOpen(bool open) external onlyOwner {
        fusionOpen = open;
    }

    event PricesUpdated(uint256 tier1Usd, uint256 tier2Usd, uint256 tier3Usd, uint256 fusionFeeUsd);

    /// @notice Owner sets USD prices (18 decimals). Each must be > 0 and <= $10 (MAX_PRICE_USD).
    function setPrices(uint256 t1, uint256 t2, uint256 t3, uint256 fusionFee) external onlyOwner {
        if (t1 == 0 || t2 == 0 || t3 == 0 || fusionFee == 0) revert BadPrice();
        if (t1 > MAX_PRICE_USD || t2 > MAX_PRICE_USD || t3 > MAX_PRICE_USD || fusionFee > MAX_PRICE_USD) revert BadPrice();
        tier1Usd = t1;
        tier2Usd = t2;
        tier3Usd = t3;
        fusionFeeUsd = fusionFee;
        emit PricesUpdated(t1, t2, t3, fusionFee);
    }

    /// @notice Owner mints from the fixed 100-bot team reserve. Labelled "dotBots team", random rarity.
    function teamMint(address to, uint256 quantity) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (quantity == 0) revert BadQuantity();
        if (teamMinted + quantity > TEAM_RESERVE) revert ReserveExhausted();
        teamMinted += quantity;
        uint256 first = _nextId;
        for (uint256 i; i < quantity; ++i) {
            uint256 id = _nextId++;
            isTeamBot[id] = true;
            _create(to, id);
        }
        emit TeamMinted(to, first, quantity);
    }

    /// @notice Gift a team bot: the owner assigns it to a .ai Agent ID holder who has not minted yet,
    ///         then the recipient pulls it with claimGift(). The owner never sends an NFT transfer itself.
    ///         Assigning again (or to address(0)) changes / cancels the gift before it is claimed.
    function assignGift(uint256 tokenId, address to) external onlyOwner {
        if (!isTeamBot[tokenId]) revert NotTeamBot();
        if (bytes(_handleOfToken[tokenId]).length != 0) revert AlreadyNamed();
        if (ownerOf(tokenId) != msg.sender) revert NotHeldByOwner();
        if (to != address(0)) _freshHandle(to);
        giftTo[tokenId] = to;
        emit GiftAssigned(tokenId, to);
    }

    /// @notice Recipient claims an assigned team bot. It takes their handle; its earlier share goes to the team.
    function claimGift(uint256 tokenId) external nonReentrant {
        if (giftTo[tokenId] != msg.sender || msg.sender == address(0)) revert NotYourBot();
        address from = owner();
        if (!isTeamBot[tokenId] || ownerOf(tokenId) != from) revert NotHeldByOwner();
        (string memory handle, bytes32 h) = _freshHandle(msg.sender);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        teamBalance += _settle(ids, from);
        delete giftTo[tokenId];
        tokenOfHandle[h] = tokenId;
        _handleOfToken[tokenId] = handle;
        isTeamBot[tokenId] = false;
        giveaways++;
        _update(msg.sender, tokenId, address(0)); // contract-level move of an owner-assigned team bot only
        emit GivenAway(msg.sender, tokenId, handle);
    }

    function setTreasury(address t) external onlyOwner {
        if (t == address(0)) revert ZeroAddress();
        treasury = t;
        _setDefaultRoyalty(t, 500);
    }

    /// @notice Sends only the team's part. Holder share and referral money can never be withdrawn by the team.
    function withdraw() external nonReentrant {
        uint256 amt = teamBalance;
        teamBalance = 0;
        _send(treasury, amt);
    }

    // ------------------------------------------------------------------ art

    struct Traits {
        uint256 tier; // 0 Common,1 Uncommon,2 Rare,3 Epic,4 Legendary
        uint256 bg;
        uint256 body;
        uint256 head;
        uint256 eyes;
        uint256 antenna;
        uint256 mouth;
        uint256 accessory;
    }

    string[8] private BG = ["#FDE2E4", "#E2ECE9", "#CDE7F0", "#FFF1C1", "#E8DFF5", "#D7F9D2", "#FCE1C8", "#DDE3EA"];
    string[8] private BODY = ["#4D96FF", "#FF6B6B", "#6BCB77", "#9B5DE5", "#F15BB5", "#00BBF9", "#FF9F1C", "#8D99AE"];
    string[3] private HEAD_N = ["Box", "Dome", "Tall"];
    string[6] private EYES_N = ["Dots", "Visor", "Big", "Laser", "Sleepy", "Heart"];
    string[4] private ANT_N = ["None", "Single", "Double", "Dish"];
    string[4] private MOUTH_N = ["Grill", "Smile", "Flat", "Open"];
    string[5] private ACC_N = ["None", "Headphones", "Bow Tie", "Monocle", "Cap"];
    string[5] private TIER_N = ["Common", "Uncommon", "Rare", "Epic", "Legendary"];

    function traitsOf(uint256 tokenId) public view returns (Traits memory t) {
        _requireOwned(tokenId);
        uint256 s = seedOf[tokenId];
        uint256 r = s % 100;
        t.tier = isFused[tokenId]
            ? (r < 50 ? 1 : r < 80 ? 2 : r < 95 ? 3 : 4) // fusion: Uncommon 50, Rare 30, Epic 15, Legendary 5
            : (r < 60 ? 0 : r < 85 ? 1 : r < 95 ? 2 : r < 99 ? 3 : 4);
        t.bg = (s >> 8) % 8;
        t.body = (s >> 16) % 8;
        t.head = (s >> 24) % 3;
        t.eyes = (s >> 32) % 6;
        t.antenna = (s >> 40) % 4;
        t.mouth = (s >> 48) % 4;
        t.accessory = t.tier >= 1 ? 1 + ((s >> 56) % 4) : 0;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        Traits memory t = traitsOf(tokenId);
        string memory handle = _handleOfToken[tokenId];
        string memory name = bytes(_esc(handle)).length > 0
            ? string.concat(_esc(handle), ".ai bot")
            : string.concat("dotBots team #", tokenId.toString());
        string memory svg = _svg(tokenId, t, handle);
        string memory attrs = string.concat(
            '[{"trait_type":"Tier","value":"', TIER_N[t.tier],
            '"},{"trait_type":"Head","value":"', HEAD_N[t.head],
            '"},{"trait_type":"Eyes","value":"', EYES_N[t.eyes],
            '"},{"trait_type":"Antenna","value":"', ANT_N[t.antenna],
            '"},{"trait_type":"Mouth","value":"', MOUTH_N[t.mouth],
            '"},{"trait_type":"Accessory","value":"', ACC_N[t.accessory],
            '"},{"trait_type":"Type","value":"', bytes(handle).length > 0 ? "Named" : "Team", '"}]'
        );
        string memory json = string.concat(
            '{"name":"', name,
            '","description":"dotBots: 2,222 bots, one per .ai Agent ID, drawn fully on-chain on BNB Chain.","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)), '","attributes":', attrs, "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _rect(uint256 x, uint256 y, uint256 w, uint256 h, string memory fill) private pure returns (string memory) {
        return string.concat(
            '<rect x="', (x * 10).toString(), '" y="', (y * 10).toString(), '" width="', (w * 10).toString(),
            '" height="', (h * 10).toString(), '" fill="', fill, '"/>'
        );
    }

    function _svg(uint256, Traits memory t, string memory handle) private view returns (string memory) {
        string memory body = t.tier == 3 ? "#E9B949" : BODY[t.body];
        string memory bg = BG[t.bg];
        string memory out = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 280" shape-rendering="crispEdges">',
            '<rect width="240" height="280" fill="', bg, '"/>'
        );
        if (t.tier == 2) {
            out = string.concat(out, _rect(3, 3, 1, 1, "#fff"), _rect(20, 5, 1, 1, "#fff"), _rect(5, 17, 1, 1, "#fff"), _rect(19, 15, 1, 1, "#fff"));
        }
        if (t.tier == 4) {
            out = string.concat(
                out, '<rect width="240" height="280" fill="#140F2D"/>',
                _rect(0, 4, 24, 1, "#FF2E88"), _rect(0, 12, 24, 1, "#00F0FF"), _rect(0, 19, 24, 1, "#7CFF4F"),
                '<ellipse cx="120" cy="22" rx="46" ry="9" fill="none" stroke="#FFD84D" stroke-width="6"/>'
            );
        }
        out = string.concat(out, _antenna(t.antenna, body), _head(t.head, body), _eyes(t.eyes), _mouth(t.mouth), _accessory(t.accessory, t.head == 2 ? 5 : 7));
        // body + name plate
        out = string.concat(out, _rect(6, 17, 12, 5, body), _rect(7, 18, 10, 3, "#1B1B1F"));
        string memory clean = _esc(_short(handle));
        string memory label = bytes(clean).length > 0 ? string.concat(clean, ".ai") : "dotBots team";
        out = string.concat(
            out,
            '<text x="120" y="200" font-family="monospace" font-size="',
            bytes(label).length > 14 ? "10" : "13",
            '" fill="#7CFF4F" text-anchor="middle">', label, "</text>",
            '<text x="120" y="262" font-family="monospace" font-size="12" fill="#1B1B1F" text-anchor="middle" opacity="0.6">dotBots</text></svg>'
        );
        return out;
    }

    function _head(uint256 kind, string memory c) private pure returns (string memory) {
        if (kind == 0) return string.concat(_rect(6, 7, 12, 9, c), _rect(5, 10, 1, 3, c), _rect(18, 10, 1, 3, c));
        if (kind == 1) return string.concat(_rect(7, 7, 10, 1, c), _rect(6, 8, 12, 8, c), _rect(5, 10, 1, 3, c), _rect(18, 10, 1, 3, c));
        return string.concat(_rect(7, 5, 10, 11, c), _rect(6, 9, 1, 3, c), _rect(17, 9, 1, 3, c));
    }

    function _antenna(uint256 kind, string memory c) private pure returns (string memory) {
        if (kind == 1) return string.concat(_rect(11, 3, 2, 4, "#1B1B1F"), _rect(10, 2, 4, 2, c));
        if (kind == 2) return string.concat(_rect(8, 3, 1, 4, "#1B1B1F"), _rect(15, 3, 1, 4, "#1B1B1F"), _rect(7, 2, 3, 2, "#FF6B6B"), _rect(14, 2, 3, 2, "#FF6B6B"));
        if (kind == 3) return string.concat(_rect(11, 4, 2, 3, "#1B1B1F"), _rect(9, 2, 6, 2, "#C0C7D1"));
        return "";
    }

    function _eyes(uint256 kind) private pure returns (string memory) {
        if (kind == 0) return string.concat(_rect(8, 10, 2, 2, "#1B1B1F"), _rect(14, 10, 2, 2, "#1B1B1F"));
        if (kind == 1) return _rect(7, 10, 10, 2, "#00F0FF");
        if (kind == 2) return string.concat(_rect(8, 9, 3, 3, "#fff"), _rect(13, 9, 3, 3, "#fff"), _rect(9, 10, 2, 2, "#1B1B1F"), _rect(14, 10, 2, 2, "#1B1B1F"));
        if (kind == 3) return string.concat(_rect(8, 10, 2, 2, "#FF2E2E"), _rect(14, 10, 2, 2, "#FF2E2E"), _rect(16, 10, 8, 1, "#FF2E2E"));
        if (kind == 4) return string.concat(_rect(8, 11, 3, 1, "#1B1B1F"), _rect(13, 11, 3, 1, "#1B1B1F"));
        return string.concat(_rect(8, 10, 1, 1, "#FF3B7F"), _rect(10, 10, 1, 1, "#FF3B7F"), _rect(8, 11, 3, 1, "#FF3B7F"), _rect(14, 10, 1, 1, "#FF3B7F"), _rect(16, 10, 1, 1, "#FF3B7F"), _rect(14, 11, 3, 1, "#FF3B7F"));
    }

    function _mouth(uint256 kind) private pure returns (string memory) {
        if (kind == 0) return string.concat(_rect(9, 13, 6, 2, "#1B1B1F"), _rect(10, 13, 1, 2, "#C0C7D1"), _rect(12, 13, 1, 2, "#C0C7D1"), _rect(14, 13, 1, 2, "#C0C7D1"));
        if (kind == 1) return string.concat(_rect(9, 13, 1, 1, "#1B1B1F"), _rect(14, 13, 1, 1, "#1B1B1F"), _rect(10, 14, 4, 1, "#1B1B1F"));
        if (kind == 2) return _rect(9, 14, 6, 1, "#1B1B1F");
        return string.concat(_rect(10, 13, 4, 2, "#1B1B1F"), _rect(11, 14, 2, 1, "#FF6B6B"));
    }

    function _accessory(uint256 kind, uint256 top) private pure returns (string memory) {
        if (kind == 1) return string.concat(_rect(5, top - 1, 14, 1, "#1B1B1F"), _rect(4, 9, 2, 5, "#1B1B1F"), _rect(18, 9, 2, 5, "#1B1B1F"));
        if (kind == 2) return string.concat(_rect(10, 16, 4, 1, "#FF2E88"), _rect(9, 15, 1, 3, "#FF2E88"), _rect(14, 15, 1, 3, "#FF2E88"));
        if (kind == 3) return string.concat(_rect(13, 8, 4, 1, "#E9B949"), _rect(13, 12, 4, 1, "#E9B949"), _rect(12, 9, 1, 3, "#E9B949"), _rect(17, 9, 1, 3, "#E9B949"));
        if (kind == 4) return string.concat(_rect(6, top - 1, 12, 2, "#2B2D42"), _rect(16, top, 5, 1, "#2B2D42"));
        return "";
    }

    function _short(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length <= 20) return s;
        bytes memory o = new bytes(19);
        for (uint256 i; i < 17; ++i) o[i] = b[i];
        o[17] = ".";
        o[18] = ".";
        return string(o);
    }

    /// @dev keep only safe characters so handles can never break the SVG or JSON
    function _esc(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory o = new bytes(b.length);
        uint256 n;
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            if ((c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == "_" || c == ".") {
                o[n++] = c;
            }
        }
        assembly {
            mstore(o, n)
        }
        return string(o);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(id);
    }
}
