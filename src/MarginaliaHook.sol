// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MarginaliaTypes as T} from "./MarginaliaTypes.sol";
import {MarginaliaPricer} from "./MarginaliaPricer.sol";
import {MarginaliaTreasury} from "./MarginaliaTreasury.sol";
import {MarginaliaRouter} from "./MarginaliaRouter.sol";
import {MarginaliaJudge} from "./MarginaliaJudge.sol";
import {MarginaliaImpls} from "./MarginaliaImpls.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title Marginalia: notes in the margin of every trade
/// @notice A Uniswap v4 hook on the MARG/IMD launch pool. Buying MARG through the router with a note in
/// hookData posts a falsifiable call on any ERC-20: a flat stamp (0.1 IMD-equivalent, to the pot) and a
/// flat deposit (0.5 IMD-equivalent of the bought MARG, locked for the horizon). The call resolves against
/// a manipulation-resistant settlement price (MarginaliaPricer); a right, still-held call gets its deposit back; anything
/// else forfeits it to the pot. The pot pays the best-argued notes of the day, ranked by the IMD oracle
/// panel, which this contract verifies as the attestation's consumer. No owner, no pause, no upgrade.
contract MarginaliaHook is IUnlockCallback {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants

    uint256 public constant STAMP = 0.1 ether; // IMD-equivalent, non-refundable, to the pot
    /// @dev Every note spends this much IMD on MARG through the pool; the rest of the IMD sent, after the stamp,
    /// is the author's bond, held as IMD claims and returned on RIGHT. Noted sells bond BOND_MIN off their output.
    uint256 public constant MARG_BUY = 0.25 ether;
    uint256 public constant BOND_MIN = 0.25 ether;
    uint256 public constant BOND_MAX = 10 ether;
    uint256 public constant SELL_NOTED_BPS = 100;
    uint256 public constant SELL_QUIET_BPS = 300;
    uint32 public constant MIN_TARGET_DELTA_BPS = 1000;
    uint16 public constant MAX_HORIZON_DAYS = 90;
    uint256 public constant TEXT_MAX = 280;
    uint256 public constant THESIS_TEXT_MAX = 8192;
    uint256 public constant THESIS_GRACE = 7 days;
    /// @dev A sealed note reveals no sooner than this after its commit (the key holders' head start) and no
    /// later than SEAL_MAX, after which the seal lapses and the note, if posted, is an ordinary one.
    uint256 public constant SEAL_MIN = 30 minutes;
    uint256 public constant SEAL_MAX = 6 hours;
    uint256 public constant SETTLE_WINDOW = 6 hours;
    uint256 public constant OBS_MIN = 3;
    uint256 public constant OBS_MAX = 16;
    uint256 public constant OBS_GAP_BLOCKS = 20;
    /// @dev Observation timestamps must span at least this long; sampled extremes are not a TWAP.
    uint256 public constant OBS_MIN_SPAN = 1 hours;
    /// @dev The settler's share of a forfeited deposit: the bounty for closing a wrong or broken call.
    uint256 public constant KEEPER_BPS = 1000;
    /// @dev A week's theses are capped at what the judge can put in front of the panel (its MAX_JUDGED), and a
    /// thesis past the cap is refused before its stamp and deposit are taken, never silently unjudgeable.
    uint256 public constant MAX_WEEK_THESES = 120;
    /// @dev One author may occupy at most the size of the panel's ranked head, leaving room for others.
    uint256 public constant MAX_AUTHOR_THESES = 3;
    /// @dev Gas allowed to a note token's balanceOf during an observation; a read that fails is "not held".
    uint256 public constant BALANCE_READ_GAS = 100_000;
    uint256 public constant JUDGE_THRESHOLD = 2 ether; // IMD, in the week's thesis pot
    uint256 public constant JUDGE_PRICE = 0.5 ether; // IMD, the Intake's oracle.request price
    uint256 public constant THESIS_BPS = 7000; // of every accrual: the week's judged thesis prize; the rest is the day's writer refund
    uint256 public constant SWEEP_AFTER = 28 days; // unclaimed pools roll forward after this
    uint256 public constant LP_FEE = 12_500;

    /// @dev The IMD oracle (Ethereum mainnet and Robinhood Chain share these addresses).
    address public constant INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;
    address public constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    /// @dev Ethereum mainnet ETH/IMD hub pool (1% fee, tick spacing 200, no hook): native is token0.

    // ------------------------------------------------------------------ immutables and pool state

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable factory;
    MarginaliaTreasury public immutable treasury;
    MarginaliaRouter public immutable router;
    MarginaliaJudge public immutable judge;

    address public imd;
    bool public initialized;
    bool private imdIs0;
    PoolKey private pool;
    PoolId public poolId;

    // ------------------------------------------------------------------ notes

    uint256 public noteCount;
    mapping(bytes32 => T.Note) private notes;
    mapping(bytes32 => T.Observation[]) private observations;

    struct Record {
        int256 score;
        uint32 posted;
        uint32 right;
        uint32 wrong;
        uint32 broken;
        uint32 retracted;
        uint32 judgedWins;
    }

    mapping(address => Record) public records;

    /// @dev A commitment to a note: the moment, the venue's BUY and SELL baselines priced then, and the author's
    /// X balance then, keyed by the sealer and a hash that binds the author to everything the note will say
    /// (sealKey(sealer, sealHash)), and recording the X and venue it priced (subject). The venue and X are public
    /// from the commit; the side, target, horizon and text are not until the reveal. A reveal uses only the
    /// author's own seal whose subject is the note's X and venue (audit finding f31a482c).
    struct Seal {
        uint64 at;
        uint256 baseBuy;
        uint256 baseSell;
        uint256 balance;
        bytes32 subject;
    }

    mapping(bytes32 => Seal) public seals;

    // ------------------------------------------------------------------ pot and judging

    /// @dev Every IMD accrual (stamps, fees, forfeits, drips) splits three ways at accrual time, all held
    /// as ERC-6909 claims: the week's thesis prize and the day's writer refund. Score is reputation only:
    /// no pool pays for a price outcome, so a venue the author provisions alone has nothing to draw on.
    mapping(uint32 => uint256) public thesisPool; // by week
    mapping(uint32 => uint256) public refundPool; // by day
    /// @dev Forfeited MARG held as claims, converted to IMD by the judge.
    /// @dev Bonds are IMD and forfeits accrue straight to the pools; the deployed judge reads this and finds
    /// nothing to convert.
    uint256 public constant potMarg = 0;
    mapping(uint32 => bool) public judgedPaid;
    mapping(uint32 => uint32) public notesPerDay;
    mapping(bytes32 => bool) public refundClaimed;
    mapping(uint32 => bytes32[]) private weekTheses;
    mapping(uint32 => mapping(address => uint32)) public thesesPerAuthor;

    // ------------------------------------------------------------------ transient-ish scratch

    bytes32 private unlockHash;

    uint8 private constant ACT_PAY = 1; // burn claims, take currency to `to`
    uint8 private constant ACT_FUND = 2; // move ERC-20 IMD into claims

    // ------------------------------------------------------------------ errors and events

    error Unauthorized();
    error InvalidPool();
    error PartialFill();
    error BadHookData();
    error NoteNeedsExactInput();
    error NoteTooSmall();
    error InvalidNote();
    error UnknownNote();
    error NotOpen();
    error TooEarly();
    error TooLate();
    error ObservationTooSoon();
    error NothingToClaim();
    error AlreadyPaid();
    error InvalidUnlock();
    error PotTooSmall();
    error NothingToSweep();

    event PoolBound(PoolId indexed poolId, address indexed imd);
    event SwapFee(bool indexed buy, address indexed trader, uint256 poolImd, uint256 fee, uint256 stamp);
    event NotePosted(
        bytes32 indexed id,
        address indexed author,
        address indexed x,
        uint8 class,
        T.Side side,
        uint32 targetBps,
        uint16 horizonDays,
        bytes32 parentId,
        string text
    );
    event Observed(bytes32 indexed id, uint256 xRead, uint256 balance);
    event Settled(
        bytes32 indexed id, T.Status status, uint256 settlePrice, int256 scoreDelta, address keeper
    );
    event Retracted(bytes32 indexed id, string text);
    event DepositClaimed(bytes32 indexed id, address indexed to, uint256 amount);
    event ThesisReleased(bytes32 indexed id);
    event ThesisForfeited(bytes32 indexed id);
    event PotFunded(uint32 indexed day, uint256 amount, address indexed source);
    event Accrued(uint32 indexed day, uint256 amount);
    event Sealed(bytes32 indexed hash, address indexed author, address indexed x, bytes32 venueRef);
    event Revealed(bytes32 indexed id, bytes32 indexed hash);
    event RefundClaimed(bytes32 indexed id, address indexed wallet, uint256 amount);
    event Swept(uint8 kind, uint32 indexed epoch, uint256 amount);
    event JudgedPaid(uint32 indexed day, uint256[3] amounts);

    // ------------------------------------------------------------------ construction

    /// @dev Chain-state-free by design: the launcher rehearses constructors in an empty EVM, so nothing here
    /// reads code at another address. The implementation addresses are compile-time constants pinned to the
    /// live launch #1240 and exercised by the mainnet-fork rehearsal; were one ever codeless, every companion
    /// call expects return data and would revert on first use, never fail silently.
    constructor(IPoolManager poolManager_, address token_, address factory_) {
        if (address(poolManager_) == address(0) || token_ == address(0) || factory_ == address(0)) {
            revert InvalidUnlock();
        }
        poolManager = poolManager_;
        token = token_;
        factory = factory_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        // Companions are EIP-1167 clones of audited implementations, initialised here and never again.
        MarginaliaTreasury t = MarginaliaTreasury(payable(Clones.clone(MarginaliaImpls.TREASURY_IMPL)));
        t.init(address(this));
        treasury = t;
        MarginaliaRouter r = MarginaliaRouter(Clones.clone(MarginaliaImpls.ROUTER_IMPL));
        r.init(poolManager_, address(this));
        router = r;
        MarginaliaJudge j = MarginaliaJudge(Clones.clone(MarginaliaImpls.JUDGE_IMPL));
        j.init(address(this), INTAKE, ACTION, ORACLE_SIGNER);
        judge = j;
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    // ------------------------------------------------------------------ pool binding

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        onlyManager
        returns (bytes4)
    {
        if (sender != factory || initialized || key.fee != LP_FEE || address(key.hooks) != address(this)) {
            revert InvalidPool();
        }
        address a = Currency.unwrap(key.currency0);
        address b = Currency.unwrap(key.currency1);
        address pair = a == token ? b : (b == token ? a : address(0));
        if (pair == address(0) || pair.code.length == 0) revert InvalidPool();
        imd = pair;
        imdIs0 = (a == pair);
        pool = key;
        poolId = key.toId();
        initialized = true;
        emit PoolBound(poolId, pair);
        return IHooks.beforeInitialize.selector;
    }

    function getPoolKey() external view returns (PoolKey memory) {
        if (!initialized) revert InvalidPool();
        return pool;
    }

    function _checkPool(PoolKey calldata key) private view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert InvalidPool();
    }

    // ------------------------------------------------------------------ swaps

    function _dataKind(address sender, bytes calldata data) private view returns (uint8 kind) {
        if (data.length == 0) return 0;
        kind = abi.decode(data, (uint8));
        if (kind == T.DATA_EXEMPT) {
            if (sender != address(this)) revert BadHookData();
        } else if (kind == T.DATA_NOTE) {
            if (sender != address(router)) revert BadHookData();
        } else {
            revert BadHookData();
        }
    }

    /// @dev Current MARG price in IMD from the bound pool, 1e18 scaled.
    function margPriceInImd() public view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(poolId);
        return pricer().fromSqrt(sqrtP, !imdIs0);
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        bool buy = params.zeroForOne == imdIs0;
        uint8 kind = _dataKind(sender, data);
        uint256 specifiedTake = 0;
        if (buy) {
            if (kind == T.DATA_NOTE) {
                // The stamp and the author's bond come off the specified IMD input; MARG_BUY of it buys MARG.
                if (params.amountSpecified >= 0) revert NoteNeedsExactInput();
                specifiedTake = STAMP + _bondOf(uint256(-params.amountSpecified));
            }
        } else if (kind == T.DATA_NOTE) {
            // A noted sell: the 1% fee, the stamp and a BOND_MIN bond come off the IMD output in afterSwap.
            if (params.amountSpecified >= 0) revert NoteNeedsExactInput();
        } else if (kind != T.DATA_EXEMPT && params.amountSpecified > 0) {
            revert NoteNeedsExactInput(); // quiet sells are exact-input only
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(specifiedTake.toInt128(), 0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external onlyManager returns (bytes4, int128) {
        _checkPool(key);
        bool buy = params.zeroForOne == imdIs0;
        int128 imdDelta = imdIs0 ? delta.amount0() : delta.amount1();
        int128 margDelta = imdIs0 ? delta.amount1() : delta.amount0();
        if ((buy && imdDelta >= 0) || (!buy && imdDelta <= 0)) revert PartialFill();
        uint256 poolImd = buy ? uint256(uint128(-imdDelta)) : uint256(uint128(imdDelta));
        uint8 kind = _dataKind(sender, data);

        if (buy) {
            if (kind != T.DATA_NOTE) return (IHooks.afterSwap.selector, 0);
            uint256 bond = _bondOf(uint256(-params.amountSpecified));
            if (poolImd != MARG_BUY) revert PartialFill();
            uint256 margOut = uint256(uint128(margDelta));
            if (margOut == 0) revert NoteTooSmall();
            poolManager.mint(address(this), _id(imd), STAMP + bond);
            _accrue(STAMP);
            (T.NoteParams memory p, address author, uint256 xResult) = _decodeNote(data);
            _postNote(author, p, xResult, bond, margOut);
            emit SwapFee(true, author, poolImd, 0, STAMP);
            return (IHooks.afterSwap.selector, 0);
        }

        if (kind == T.DATA_EXEMPT) return (IHooks.afterSwap.selector, 0);

        if (kind == T.DATA_NOTE) {
            uint256 fee = poolImd * SELL_NOTED_BPS / 10_000 + STAMP;
            if (poolImd <= fee + BOND_MIN) revert NoteTooSmall();
            poolManager.mint(address(this), _id(imd), fee + BOND_MIN);
            _accrue(fee);
            (T.NoteParams memory p, address author, uint256 xResult) = _decodeNote(data);
            _postNote(author, p, xResult, BOND_MIN, 0);
            emit SwapFee(false, author, poolImd, fee - STAMP, STAMP);
            return (IHooks.afterSwap.selector, (fee + BOND_MIN).toInt128());
        }

        // Quiet sell.
        uint256 quietFee = poolImd * SELL_QUIET_BPS / 10_000;
        int128 returned = quietFee.toInt128();
        if (quietFee > 0) {
            poolManager.mint(address(this), _id(imd), quietFee);
            _accrue(quietFee);
        }
        emit SwapFee(false, tx.origin, poolImd, quietFee, 0);
        return (IHooks.afterSwap.selector, returned);
    }

    /// @dev The author's bond is what they sent beyond the stamp and the MARG buy, inside the band.
    function _bondOf(uint256 imdIn) private pure returns (uint256 bond) {
        if (imdIn < STAMP + MARG_BUY + BOND_MIN) revert NoteTooSmall();
        bond = imdIn - STAMP - MARG_BUY;
        if (bond > BOND_MAX) revert InvalidNote();
    }

    /// @dev Splits an IMD accrual into the two pools.
    function _accrue(uint256 amount) private {
        uint32 day = _today();
        uint256 th = amount * THESIS_BPS / 10_000;
        thesisPool[_week()] += th;
        refundPool[day] += amount - th;
        emit Accrued(day, amount);
    }

    function _decodeNote(bytes calldata data)
        private
        pure
        returns (T.NoteParams memory p, address author, uint256 xResult)
    {
        (, p, author, xResult) = abi.decode(data, (uint8, T.NoteParams, address, uint256));
        if (author == address(0)) revert BadHookData();
    }

    // ------------------------------------------------------------------ notes

    function _postNote(
        address author,
        T.NoteParams memory p,
        uint256 xResult,
        uint256 bond,
        uint256 margToAuthor
    ) private {
        bool thesis = p.targetBps == 0;
        uint256 textLen = bytes(p.text).length;
        if (thesis) {
            if (textLen == 0 || textLen > THESIS_TEXT_MAX) revert InvalidNote();
            if (p.parentId != bytes32(0)) _checkCounter(p, author, true); // a rebuttal of another author's thesis
        } else {
            if (textLen == 0 || textLen > TEXT_MAX) revert InvalidNote();
            if (p.horizonDays == 0 || p.horizonDays > MAX_HORIZON_DAYS) revert InvalidNote();
            if (p.side == T.Side.Buy) {
                if (p.targetBps < 10_000 + MIN_TARGET_DELTA_BPS) revert InvalidNote();
            } else {
                if (p.targetBps >= 10_000 || p.targetBps + MIN_TARGET_DELTA_BPS > 10_000) {
                    revert InvalidNote();
                }
            }
            _checkCallVenue(p.x, p.venue);
        }
        uint8 class = p.class;
        if (class >= uint8(T.Class.Attested)) revert InvalidNote(); // the panel's class is never self-declared
        if (xResult > 0) class = uint8(T.Class.Traded);
        else if (class == uint8(T.Class.Traded)) class = uint8(T.Class.Declared);
        if (author.code.length > 0) class = uint8(T.Class.Agent);

        bytes32 id = bytes32(++noteCount);
        T.Note storage n = notes[id];
        n.author = author;
        n.x = p.x;
        n.venue = p.venue;
        n.side = p.side;
        n.targetBps = p.targetBps;
        n.horizonDays = p.horizonDays;
        n.class = class;
        n.postedAt = uint64(block.timestamp);
        n.day = _today();
        n.deposit = bond;
        n.parentId = p.parentId;
        notesPerDay[n.day] += 1;
        if (thesis) {
            n.status = T.Status.ThesisOpen;
            uint32 w = _week();
            if (weekTheses[w].length >= MAX_WEEK_THESES || thesesPerAuthor[w][author] >= MAX_AUTHOR_THESES) {
                revert InvalidNote();
            }
            thesesPerAuthor[w][author] += 1;
            weekTheses[w].push(id);
        } else {
            bool buy = p.side == T.Side.Buy;
            // The MARG this very swap delivers reaches the author after the callback; count it for a note on MARG.
            n.postBalance = IERC20(p.x).balanceOf(author) + (p.x == token ? margToAuthor : 0);
            bytes32 hash = sealHash(author, p);
            bytes32 key = sealKey(author, hash);
            Seal storage s = seals[key];
            uint256 age = s.at == 0 ? 0 : block.timestamp - uint256(s.at);
            // Only the author's own seal of this note's X and venue counts; any other is no seal.
            bool bound = s.at != 0 && s.subject == keccak256(abi.encode(p.x, p.venue));
            if (bound && age < SEAL_MIN) revert TooEarly(); // the head start is the key holders', not the public's
            if (bound && age <= SEAL_MAX) {
                // A sealed note is a claim about a position already held: priced when it was sealed, and the
                // author's X balance may not have fallen since (SELL calls hold nothing, so nothing to keep).
                if (buy && n.postBalance < s.balance) revert InvalidNote();
                n.postPrice = buy ? s.baseBuy : s.baseSell;
                emit Revealed(id, hash);
            } else {
                n.postPrice = router.postPrice(p.venue, buy);
            }
            // A seal is spent by its note, timely or lapsed (audit finding d492eadc).
            if (s.at != 0) delete seals[key];
            if (n.postPrice == 0) revert InvalidNote(); // the pricer refuses these; never trust a zero baseline
            if (p.parentId != bytes32(0)) {
                T.Note storage parent = notes[p.parentId];
                if (parent.author == author) {
                    // a child call under the author's own open thesis
                    if (
                        parent.status != T.Status.ThesisOpen
                            || block.timestamp > uint256(parent.postedAt) + THESIS_GRACE
                    ) {
                        revert InvalidNote();
                    }
                    parent.children += 1;
                } else {
                    _checkCounter(p, author, false); // a counter-call against another author's call
                }
            }
        }
        records[author].posted += 1;
        emit NotePosted(id, author, p.x, class, p.side, p.targetBps, p.horizonDays, p.parentId, p.text);
    }

    /// @dev A call must be falsifiable in IMD and use the unique address encoding of an accumulator venue.
    /// The immutable router authenticates the pool, but also accepts high-byte aliases of v3/v2 addresses.
    function _checkCallVenue(address x, T.Venue memory v) private view {
        if (x == address(0) || x == imd || x == v.quote || x.code.length == 0) revert InvalidNote();
        if ((v.kind == T.VenueKind.UniV3 || v.kind == T.VenueKind.UniV2) && uint256(v.ref) >> 160 != 0) {
            revert InvalidNote();
        }
    }

    /// @dev A counter argues against another author's live note: a thesis against an open thesis, a call
    /// against an open call on the same X from the other side. Deposits never change hands between them;
    /// the scores already move in opposite directions, and a duel's outcome is the pair of Settled events
    /// (the link is NotePosted.parentId pointing at another author's note), kept off-chain for code size.
    function _checkCounter(T.NoteParams memory p, address author, bool thesis) private view {
        T.Note storage t = notes[p.parentId];
        if (t.author == address(0) || t.author == author) revert InvalidNote();
        if (thesis) {
            if (t.status != T.Status.ThesisOpen) revert InvalidNote();
        } else if (t.status != T.Status.Open || t.x != p.x || t.side == p.side) {
            revert InvalidNote();
        }
    }

    function pricer() public pure returns (MarginaliaPricer) {
        return MarginaliaPricer(MarginaliaImpls.PRICER);
    }

    function horizonEnd(bytes32 id) public view returns (uint256) {
        T.Note storage n = _note(id);
        return uint256(n.postedAt) + uint256(n.horizonDays) * 1 days;
    }

    /// @notice Anyone records an observation inside the settlement window: the venue's accumulator (v3 / v2)
    /// or spot (v4), the quote leg's spot, and the author's balance. Series slots are spaced by blocks and
    /// capped, but a slot is never owned: while it is taken, a reading more adverse to the call than the
    /// latest one replaces it without moving the slot's opening block. The actual reading's timestamp is
    /// retained for TWAP/span calculations. A favourable pump can be overwritten by an honest reading;
    /// a hostile adverse reading remains even after the price recovers.
    function observe(bytes32 id) external {
        T.Note storage n = _note(id);
        if (n.status != T.Status.Open) revert NotOpen();
        uint256 end = horizonEnd(id);
        if (block.timestamp < end) revert TooEarly();
        if (block.timestamp > end + SETTLE_WINDOW) revert TooLate();
        T.Observation[] storage obs = observations[id];
        (uint256 xRead, uint256 quoteRead) = pricer().observe(poolManager, n.venue, imd);
        uint256 balance = _balanceOf(n.x, n.author);
        T.Observation memory o =
            T.Observation(uint64(block.timestamp), uint64(block.number), xRead, quoteRead, balance);
        uint256 len = obs.length;
        // Reserve the final slot until actual readings span an hour. A replacement of the first
        // reading must not let rapid pushes fill every slot with a permanently too-short series.
        if (
            len > 0
                && (len >= OBS_MAX
                    || block.number < obs[len - 1].blockNumber + OBS_GAP_BLOCKS
                    || (len == OBS_MAX - 1 && block.timestamp < uint256(obs[0].timestamp) + OBS_MIN_SPAN))
        ) {
            if (!_moreAdverse(n, o, obs[len - 1])) revert ObservationTooSoon();
            o.blockNumber = obs[len - 1].blockNumber; // replacements never postpone the next slot
            obs[len - 1] = o;
        } else {
            obs.push(o);
        }
        emit Observed(id, xRead, balance);
    }

    /// @dev The author's X balance by staticcall with bounded gas. A read that reverts, re-enters or returns
    /// nothing is recorded as unverifiable (the sentinel), which the hold rule treats as not held: a token the
    /// author can switch off is never a free option on the settlement.
    function _balanceOf(address x, address who) private view returns (uint256) {
        (bool ok, bytes memory ret) =
            x.staticcall{gas: BALANCE_READ_GAS}(abi.encodeWithSelector(IERC20.balanceOf.selector, who));
        if (!ok || ret.length < 32) return type(uint256).max;
        return abi.decode(ret, (uint256));
    }

    /// @dev Whether an observed balance breaks the hold rule: a BUY call must keep its post balance (the
    /// unverifiable sentinel counts as not held). A SELL call has no hold rule and settles on price alone: an
    /// ERC-20 balance can be raised by anyone, so any "must not grow" rule lets a stranger void a correct call
    /// with a gift (revision finding 80c42ce7).
    function _broken(T.Note storage n, uint256 balance) private view returns (bool) {
        if (n.side == T.Side.Sell) return false;
        return balance == type(uint256).max || balance < n.postBalance;
    }

    /// @dev Whether a reading is more adverse to the call than the one it would replace: a worse price (v4:
    /// the venue spot times the quote leg; v3 / v2: the quote leg, the accumulator being a TWAP input), or a
    /// hold breach the earlier reading did not show. A breach is never replaced by a non-breach.
    function _moreAdverse(T.Note storage n, T.Observation memory o, T.Observation memory last)
        private
        view
        returns (bool)
    {
        bool brokenNew = _broken(n, o.balance);
        bool brokenLast = _broken(n, last.balance);
        if (brokenLast && !brokenNew) return false;
        if (brokenNew && !brokenLast) return true;
        bool v4 = n.venue.kind == T.VenueKind.UniV4;
        uint256 pn = v4 ? FullMath.mulDiv(o.xRead, o.quoteRead, 1e18) : o.quoteRead;
        uint256 pl = v4 ? FullMath.mulDiv(last.xRead, last.quoteRead, 1e18) : last.quoteRead;
        return n.side == T.Side.Buy ? pn < pl : pn > pl;
    }

    /// @notice Anyone settles a note once its window has closed. The keeper earns KEEPER_BPS of a forfeited deposit.
    function settle(bytes32 id) external {
        T.Note storage n = _note(id);
        if (n.status != T.Status.Open) revert NotOpen();
        uint256 end = horizonEnd(id);
        if (block.timestamp <= end + SETTLE_WINDOW) revert TooEarly();
        T.Observation[] memory obs = observations[id];
        uint256 count = obs.length;
        T.Status outcome;
        uint256 settlePrice;
        if (count < OBS_MIN || obs[count - 1].timestamp - obs[0].timestamp < OBS_MIN_SPAN) {
            outcome = T.Status.VoidNoData;
        } else {
            bool held = true;
            for (uint256 i = 0; i < count; ++i) {
                if (_broken(n, obs[i].balance)) held = false;
            }
            settlePrice = _settlementPrice(n, obs);
            if (settlePrice == 0) {
                outcome = T.Status.VoidNoData;
            } else if (!held) {
                outcome = T.Status.VoidSold;
            } else if (n.side == T.Side.Buy) {
                outcome = settlePrice * 10_000 >= n.postPrice * n.targetBps ? T.Status.Right : T.Status.Wrong;
            } else {
                outcome = settlePrice * 10_000 <= n.postPrice * n.targetBps ? T.Status.Right : T.Status.Wrong;
            }
        }
        n.status = outcome;
        int256 scoreDelta = 0;
        Record storage r = records[n.author];
        if (outcome == T.Status.Right) {
            scoreDelta = int256(_difficulty(n));
            r.right += 1;
        } else if (outcome == T.Status.VoidNoData) {
            // Unproven scores as wrong (the deposit still comes back): an author cannot post both sides and
            // observe only the one the market confirmed.
            scoreDelta = -int256(_difficulty(n));
        } else if (outcome == T.Status.Wrong) {
            scoreDelta = -int256(_difficulty(n));
            r.wrong += 1;
            _forfeit(n, msg.sender);
        } else if (outcome == T.Status.VoidSold) {
            scoreDelta = -int256(_difficulty(n));
            r.broken += 1;
            _forfeit(n, msg.sender);
        }
        r.score += scoreDelta;
        _resolveChild(n);
        emit Settled(id, outcome, settlePrice, scoreDelta, msg.sender);
    }

    /// @dev The live pricer takes component-wise extremes on v4. Price each complete observation through
    /// it separately, then retain the adverse product, so both legs always come from the same reading.
    /// Accumulator venues still use the full series: first-to-last TWAP times the adverse hub leg.
    /// Any unpriceable reading/series remains VoidNoData, including multiplication overflow in the pricer.
    function _settlementPrice(T.Note storage n, T.Observation[] memory obs)
        private
        view
        returns (uint256 price)
    {
        bool buy = n.side == T.Side.Buy;
        bool v4 = n.venue.kind == T.VenueKind.UniV4;
        T.Observation[] memory sample = v4 ? new T.Observation[](1) : obs;
        uint256 count = v4 ? obs.length : 1;
        for (uint256 i; i < count; ++i) {
            if (v4) sample[0] = obs[i];
            try pricer().settlePrice(n.venue, buy, sample) returns (uint256 p) {
                if (p == 0) return 0;
                if (i == 0 || (buy ? p < price : p > price)) price = p;
            } catch {
                return 0;
            }
        }
    }

    /// @notice The author withdraws a call before its horizon: the deposit goes to the pot, the reason is public.
    function retract(bytes32 id, string calldata text) external {
        T.Note storage n = _note(id);
        if (msg.sender != n.author) revert Unauthorized();
        if (n.status != T.Status.Open) revert NotOpen();
        if (block.timestamp >= horizonEnd(id)) revert TooLate();
        n.status = T.Status.Retracted;
        // Retraction removes an unclaimed refund from the day's split. A refund already paid is not clawed back.
        if (!refundClaimed[id]) notesPerDay[n.day] -= 1;
        int256 scoreDelta = -int256(_difficulty(n) / 2);
        Record storage r = records[n.author];
        r.retracted += 1;
        r.score += scoreDelta;
        _forfeit(n, address(0));
        _resolveChild(n);
        emit Retracted(id, text);
        emit Settled(id, T.Status.Retracted, 0, scoreDelta, address(0));
    }

    /// @notice A thesis with no child call inside the grace period forfeits its deposit.
    function settleThesis(bytes32 id) external {
        T.Note storage n = _note(id);
        if (n.status != T.Status.ThesisOpen) revert NotOpen();
        if (n.children > 0) revert NotOpen();
        if (block.timestamp <= uint256(n.postedAt) + THESIS_GRACE) revert TooEarly();
        n.status = T.Status.ThesisForfeited;
        _forfeit(n, msg.sender);
        emit ThesisForfeited(id);
    }

    /// @notice A right (or no-data, or released thesis) bond, returned in IMD.
    function claimDeposit(bytes32 id) external {
        T.Note storage n = _note(id);
        if (msg.sender != n.author) revert Unauthorized();
        if (
            n.status != T.Status.Right && n.status != T.Status.VoidNoData && n.status != T.Status.ThesisClosed
        ) revert NothingToClaim();
        uint256 amount = n.deposit;
        if (amount == 0) revert NothingToClaim();
        n.deposit = 0;
        _unlock(ACT_PAY, n.author, amount, uint256(uint160(imd)));
        emit DepositClaimed(id, n.author, amount);
    }

    function _forfeit(T.Note storage n, address keeper) private {
        uint256 amount = n.deposit;
        n.deposit = 0;
        if (amount == 0) return;
        uint256 reward = keeper == address(0) ? 0 : amount * KEEPER_BPS / 10_000;
        if (reward > 0) _unlock(ACT_PAY, keeper, reward, uint256(uint160(imd)));
        _accrue(amount - reward);
    }

    function _resolveChild(T.Note storage n) private {
        if (n.parentId == bytes32(0)) return;
        T.Note storage parent = notes[n.parentId];
        if (parent.status == T.Status.ThesisOpen) {
            parent.status = T.Status.ThesisClosed;
            emit ThesisReleased(n.parentId);
        }
    }

    // ------------------------------------------------------------------ score

    /// @dev log2(claimed multiple) x sqrt(30 / horizon) x mcap tier, scaled 1e4 (MarginaliaPricer). The score
    /// is reputation: no pool pays for it, so a call priced on a venue the author provisions alone (review
    /// finding c7331916) can inflate a number but never draw money. Readers see the venue; the site labels it.
    /// X's totalSupply is read like its balance, by bounded-gas staticcall; a failed read, or a supply whose
    /// market cap overflows, books tier 1 and never blocks settle or retract (audit finding 43fe5339).
    function _difficulty(T.Note storage n) private view returns (uint256) {
        (bool ok, bytes memory ret) =
            n.x.staticcall{gas: BALANCE_READ_GAS}(abi.encodeWithSelector(IERC20.totalSupply.selector));
        uint256 supply = ok && ret.length >= 32 ? abi.decode(ret, (uint256)) : 0;
        uint256 mcap = supply <= type(uint256).max / n.postPrice ? n.postPrice * supply / 1e18 : 0;
        return pricer().difficulty(n.targetBps, n.side == T.Side.Buy, n.horizonDays, mcap);
    }

    // ------------------------------------------------------------------ pot and judging

    function _today() private view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }

    function _week() private view returns (uint32) {
        return uint32(block.timestamp / 7 days);
    }

    function today() external view returns (uint32) {
        return _today();
    }

    function week() external view returns (uint32) {
        return _week();
    }

    /// @notice Every thesis posted in a week, by posting order (the judge filters to those with a child call).
    function thesesOfWeek(uint32 w) external view returns (bytes32[] memory) {
        return weekTheses[w];
    }

    /// @notice Moves ERC-20 IMD from the caller into the pools (the treasury's drip, or anyone's gift).
    function fundPot(uint256 amount) external {
        if (amount == 0) revert PotTooSmall();
        _fund(amount);
        emit PotFunded(_today(), amount, msg.sender);
    }

    function _fund(uint256 amount) private {
        IERC20(imd).safeTransferFrom(msg.sender, address(this), amount);
        _unlock(ACT_FUND, address(0), amount, 0);
        _accrue(amount);
    }

    // ------------------------------------------------------------------ sealed notes

    /// @notice What a seal commits to: everything the revealed note will carry, bound to its author.
    function sealHash(address author, T.NoteParams memory p) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(author, p.x, p.venue, p.side, p.targetBps, p.horizonDays, p.parentId, p.text)
            );
    }

    /// @notice Where a sealer's seal of `hash` is stored in `seals`: no one else can occupy or price it.
    function sealKey(address sealer, bytes32 hash) public pure returns (bytes32) {
        return keccak256(abi.encode(sealer, hash));
    }

    /// @notice Seal a note before posting it: pays one stamp now (non-refundable, so a seal is never a free
    /// option), prices the venue's BUY and SELL baselines now, and snapshots the author's X balance now. The
    /// note itself is posted later through the router, between SEAL_MIN and SEAL_MAX after this, and settles
    /// against these baselines. Between the two, the author's key holders may read what was sealed; everyone
    /// else sees only this event. The venue must already have a mature router checkpoint, as for any post.
    /// A seal past SEAL_MAX has lapsed and may be replaced by a fresh one.
    function seal(address x, T.Venue calldata venue, bytes32 hash) external {
        _checkCallVenue(x, venue);
        bytes32 key = sealKey(msg.sender, hash);
        uint64 at = seals[key].at;
        if ((at != 0 && block.timestamp - at <= SEAL_MAX) || x == address(0) || hash == bytes32(0)) {
            revert InvalidNote();
        }
        uint256 baseBuy = router.postPrice(venue, true);
        uint256 baseSell = router.postPrice(venue, false);
        if (baseBuy == 0 || baseSell == 0) revert InvalidNote();
        _fund(STAMP);
        seals[key] = Seal(
            uint64(block.timestamp),
            baseBuy,
            baseSell,
            _balanceOf(x, msg.sender),
            keccak256(abi.encode(x, venue))
        );
        emit Sealed(hash, msg.sender, x, venue.ref);
    }

    /// @notice The judge draws the oracle's price out of a week's thesis pool. The first draw of a week needs
    /// the threshold and the full child grace after week-end; a retry only needs the price.
    function drawForJudging(uint32 w, uint256 amount, bool retry) external {
        if (msg.sender != address(judge)) revert Unauthorized();
        if (!retry && block.timestamp < (uint256(w) + 1) * 7 days + THESIS_GRACE) revert TooEarly();
        uint256 need = retry ? amount : JUDGE_THRESHOLD;
        if (thesisPool[w] < need || amount > thesisPool[w]) revert PotTooSmall();
        thesisPool[w] -= amount;
        _unlock(ACT_PAY, address(judge), amount, uint256(uint160(imd)));
    }

    /// @notice Who wrote a note and in which week: what the judge needs to filter the panel's ranking.
    function noteMeta(bytes32 id)
        external
        view
        returns (address author, uint32 w, bool thesis, bool hasChild)
    {
        T.Note storage n = notes[id];
        return (n.author, uint32(uint256(n.postedAt) / 7 days), n.targetBps == 0, n.children > 0);
    }

    /// @notice Pays a judged week's thesis pool 50/30/20 to the ranked authors. The judge supplies the ranking.
    function payJudged(uint32 w, bytes32[3] calldata top) external {
        if (msg.sender != address(judge)) revert Unauthorized();
        if (judgedPaid[w]) revert AlreadyPaid();
        judgedPaid[w] = true;
        uint256 pool = thesisPool[w];
        thesisPool[w] = 0;
        uint256[3] memory shares = [pool * 50 / 100, pool * 30 / 100, pool * 20 / 100];
        uint256[3] memory paidAmounts;
        uint256 leftover = pool;
        for (uint256 k = 0; k < 3; ++k) {
            if (top[k] == bytes32(0)) continue;
            address to = notes[top[k]].author;
            records[to].judgedWins += 1;
            _unlock(ACT_PAY, to, shares[k], uint256(uint160(imd)));
            paidAmounts[k] = shares[k];
            leftover -= shares[k];
        }
        if (leftover > 0) thesisPool[_week()] += leftover; // unranked slots roll forward
        emit JudgedPaid(w, paidAmounts);
    }

    /// @notice A writer's refund: the day's pool split equally across its notes, at most one stamp each.
    function claimRefund(bytes32 id) external {
        T.Note storage n = _note(id);
        if (msg.sender != n.author) revert Unauthorized();
        if (n.day >= _today()) revert TooEarly();
        if (refundClaimed[id] || n.status == T.Status.Retracted) revert NothingToClaim();
        uint256 count = notesPerDay[n.day];
        uint256 amount = refundPool[n.day] / count;
        if (amount > STAMP) amount = STAMP;
        if (amount == 0) revert NothingToClaim();
        refundClaimed[id] = true;
        refundPool[n.day] -= amount;
        notesPerDay[n.day] = uint32(count - 1);
        _unlock(ACT_PAY, msg.sender, amount, uint256(uint160(imd)));
        emit RefundClaimed(id, msg.sender, amount);
    }

    /// @notice Rolls what an old pool left unclaimed into the current week's thesis prize, where it reaches
    /// writers. kind 0 = a day's refund pool, 1 = a week's thesis pool (only once the judge confirms nothing is
    /// pending or judged for it). A swept pool is zeroed, so no claim can draw on it.
    function sweep(uint8 kind, uint32 epoch) external {
        uint256 amount;
        if (kind == 0) {
            if (block.timestamp < (uint256(epoch) + 1) * 1 days + SWEEP_AFTER) revert TooEarly();
            amount = refundPool[epoch];
            refundPool[epoch] = 0;
        } else {
            if (block.timestamp < (uint256(epoch) + 1) * 7 days + SWEEP_AFTER) revert TooEarly();
            if (!judge.weekClosed(epoch)) revert NotOpen();
            amount = thesisPool[epoch];
            thesisPool[epoch] = 0;
        }
        if (amount == 0) revert NothingToSweep();
        thesisPool[_week()] += amount;
        emit Swept(kind, epoch, amount);
    }

    // ------------------------------------------------------------------ unlock plumbing

    function _id(address c) private pure returns (uint256) {
        return uint256(uint160(c));
    }

    function _unlock(uint8 action, address to, uint256 amount, uint256 extra)
        private
        returns (uint256 result)
    {
        bytes memory data = abi.encode(action, to, amount, extra);
        unlockHash = keccak256(data);
        bytes memory out = poolManager.unlock(data);
        if (unlockHash != bytes32(0)) revert InvalidUnlock();
        if (out.length == 32) result = abi.decode(out, (uint256));
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (unlockHash == bytes32(0) || keccak256(data) != unlockHash) revert InvalidUnlock();
        delete unlockHash;
        (uint8 action, address to, uint256 amount, uint256 extra) =
            abi.decode(data, (uint8, address, uint256, uint256));
        if (action == ACT_PAY) {
            address currency = address(uint160(extra));
            poolManager.burn(address(this), _id(currency), amount);
            poolManager.take(Currency.wrap(currency), to, amount);
            return "";
        }
        if (action == ACT_FUND) {
            Currency c = Currency.wrap(imd);
            poolManager.sync(c);
            IERC20(imd).safeTransfer(address(poolManager), amount);
            poolManager.settle();
            poolManager.mint(address(this), _id(imd), amount);
            return "";
        }
        revert InvalidUnlock();
    }

    // ------------------------------------------------------------------ views

    function _note(bytes32 id) private view returns (T.Note storage n) {
        n = notes[id];
        if (n.author == address(0)) revert UnknownNote();
    }

    /// @notice The fields a reader needs; venue, text and timestamps are in the NotePosted event.
    function noteOf(bytes32 id) external view returns (T.NoteView memory v) {
        T.Note storage n = _note(id);
        v.author = n.author;
        v.x = n.x;
        v.side = n.side;
        v.targetBps = n.targetBps;
        v.horizonDays = n.horizonDays;
        v.class = n.class;
        v.status = n.status;
        v.postPrice = n.postPrice;
        v.postBalance = n.postBalance;
        v.deposit = n.deposit;
        v.parentId = n.parentId;
        v.children = n.children;
    }
}
