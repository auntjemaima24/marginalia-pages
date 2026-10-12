// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture, TestSwapRouter} from "./helpers/Fixture.sol";
import {MarginaliaHook} from "src/MarginaliaHook.sol";
import {MarginaliaRouter} from "src/MarginaliaRouter.sol";
import {MarginaliaTreasury} from "src/MarginaliaTreasury.sol";
import {MarginaliaJudge} from "src/MarginaliaJudge.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {MarginaliaTypes as T} from "src/MarginaliaTypes.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev A separate ledger driven by actual user operations on the real PoolManager and hook.
/// No contract storage is injected, no price read is mocked, and valid calls cannot silently revert.
contract HookAccountingHandler is Test {
    using PoolIdLibrary for PoolKey;

    MarginaliaHook public immutable hook;
    MarginaliaRouter public immutable router;
    MarginaliaTreasury public immutable treasury;
    MarginaliaJudge public immutable judge;
    IPoolManager public immutable manager;
    IERC20 public immutable imd;
    IERC20 public immutable marg;
    PoolKey internal key;
    TestSwapRouter public immutable plain;
    bool internal immutable margIs0;
    address[3] public actors;
    address public immutable keeper;

    struct Bond {
        address author;
        uint256 original;
        uint256 outstanding;
        uint256 claimed;
        uint256 forfeited;
        uint256 postedAt;
        uint32 day;
        bool refundPaid;
        T.Status status;
        bytes32 parent;
        uint32 children;
    }

    mapping(bytes32 => Bond) public bonds;
    mapping(bytes32 => bool) public observed;
    mapping(bytes32 => T.Status) public observedOutcome;
    mapping(uint32 => uint256) public expectedThesis;
    mapping(uint32 => uint256) public expectedRefund;
    mapping(uint32 => uint256) public expectedWriters;
    mapping(uint32 => mapping(address => uint256)) public expectedAuthorTheses;
    uint32[] public daysSeen;
    uint32[] public weeksSeen;
    mapping(uint32 => bool) internal daySeen;
    mapping(uint32 => bool) internal weekSeen;
    uint256 public created;
    uint256 public claimsIn;
    uint256 public claimsOut;
    uint256 public refundsPaid;
    uint256 public keeperPaid;
    uint256 public settlements;
    uint256 public retractions;
    uint256 public depositClaims;
    uint256 public sweeps;
    uint256 public sealsMade;
    uint256 public drips;
    uint256 public treasuryGifts;
    uint256 public treasuryDrips;
    uint256 public oracleSpent;
    uint256 public prizesPaid;
    uint256 public judgingRequests;
    uint256 public thesisCapRefusals;
    uint256 public lateChildRefusals;
    uint256 public earlyJudgingRefusals;
    mapping(uint32 => bool) public pending;
    mapping(uint32 => bool) public expectedJudged;
    mapping(uint32 => bool) public expectedPaid;
    mapping(uint32 => bytes32[3]) public expectedHead;

    constructor(MarginaliaHook h, TestSwapRouter p, address[3] memory writers, address k) {
        hook = h;
        router = h.router();
        treasury = h.treasury();
        judge = h.judge();
        manager = h.poolManager();
        imd = IERC20(h.imd());
        marg = IERC20(h.token());
        key = h.getPoolKey();
        margIs0 = Currency.unwrap(key.currency0) == address(marg);
        plain = p;
        actors = writers;
        keeper = k;
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(writers[i]);
            imd.approve(address(router), type(uint256).max);
            marg.approve(address(router), type(uint256).max);
            imd.approve(address(h), type(uint256).max);
            imd.approve(address(p), type(uint256).max);
            marg.approve(address(p), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % 3];
    }

    function _id(uint256 seed) private view returns (bytes32) {
        return bytes32(bound(seed, 1, created));
    }

    function _now() private view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _warp(uint256 timestamp) private {
        if (timestamp <= _now()) return;
        vm.roll(vm.getBlockNumber() + (timestamp - _now()) / 12 + 1);
        vm.warp(timestamp);
    }

    function _trackEpochs() private {
        uint32 day = uint32(_now() / 1 days);
        uint32 week = uint32(_now() / 7 days);
        if (!daySeen[day]) {
            daySeen[day] = true;
            daysSeen.push(day);
        }
        if (!weekSeen[week]) {
            weekSeen[week] = true;
            weeksSeen.push(week);
        }
    }

    function _accrue(uint256 amount) private {
        _trackEpochs();
        uint256 thesis = amount * 7 / 10;
        expectedThesis[uint32(_now() / 7 days)] += thesis;
        expectedRefund[uint32(_now() / 1 days)] += amount - thesis;
    }

    function _params(bool buy, bool thesis) private view returns (T.NoteParams memory p) {
        p.x = address(marg);
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(key.toId()), address(imd), margIs0);
        p.side = buy ? T.Side.Buy : T.Side.Sell;
        p.targetBps = thesis ? 0 : (buy ? 11_000 : 9000);
        p.horizonDays = 1;
        p.class = uint8(T.Class.Declared);
        p.text = "accounting sequence";
    }

    function _mature(T.NoteParams memory p) private {
        router.checkpointVenue(p, key);
        (uint64 startedAt,,,,,,) = router.priceWindows(keccak256(abi.encode(p.venue)));
        _warp(uint256(startedAt) + 1 hours);
    }

    function _record(address author, uint256 bond, bool thesis, bytes32 parent) private {
        ++created;
        assertEq(hook.noteCount(), created);
        bonds[bytes32(created)] = Bond({
            author: author,
            original: bond,
            outstanding: bond,
            claimed: 0,
            forfeited: 0,
            postedAt: _now(),
            day: uint32(_now() / 1 days),
            refundPaid: false,
            status: thesis ? T.Status.ThesisOpen : T.Status.Open,
            parent: parent,
            children: 0
        });
        expectedWriters[uint32(_now() / 1 days)]++;
        if (thesis) expectedAuthorTheses[uint32(_now() / 7 days)][author]++;
        if (parent != bytes32(0)) bonds[parent].children++;
    }

    /// @dev Invalid posts must fail in the hook afterSwap, with all swap effects rolled back.
    function _rejectPost(address author, T.NoteParams memory p, uint256 amount) private {
        uint256 imdBefore = imd.balanceOf(author);
        uint256 margBefore = marg.balanceOf(author);
        uint256 claimsBefore = manager.balanceOf(address(hook), uint160(address(imd)));
        vm.prank(author);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(MarginaliaHook.InvalidNote.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.note(p, key, amount, 1, _now());
        assertEq(imd.balanceOf(author), imdBefore, "refused note spent IMD");
        assertEq(marg.balanceOf(author), margBefore, "refused note delivered MARG");
        assertEq(manager.balanceOf(address(hook), uint160(address(imd))), claimsBefore);
        assertEq(hook.noteCount(), created, "refused note consumed an id");
    }

    function post(uint256 who, uint256 amount, bool buy, bool thesis) public {
        // Keep loops in invariants bounded independently of the configured fuzz depth.
        if (created == 80) return;
        address author = _actor(who);
        uint256 bond = bound(amount, 0.25 ether, 10 ether);
        T.NoteParams memory p = _params(buy, thesis);
        if (thesis && expectedAuthorTheses[uint32(_now() / 7 days)][author] == 3) {
            _rejectPost(author, p, bond + 0.35 ether);
            thesisCapRefusals++;
            return;
        }
        if (!thesis) _mature(p);
        uint256 before = imd.balanceOf(author);
        vm.prank(author);
        router.note(p, key, bond + 0.35 ether, 1, _now());
        assertEq(before - imd.balanceOf(author), bond + 0.35 ether);
        _record(author, bond, thesis, 0);
        claimsIn += bond + 0.1 ether;
        _accrue(0.1 ether);
    }

    function child(uint256 seed) public {
        if (created == 0 || created == 80) return;
        bytes32 parent = _id(seed);
        Bond storage b = bonds[parent];
        if (b.status != T.Status.ThesisOpen) return;
        T.NoteParams memory p = _params(true, false);
        p.parentId = parent;
        _mature(p);
        // Check after checkpoint maturation, which can carry a formerly timely child past its deadline.
        if (_now() > b.postedAt + 7 days) {
            _rejectPost(b.author, p, 0.6 ether);
            lateChildRefusals++;
            return;
        }
        vm.prank(b.author);
        router.note(p, key, 0.6 ether, 1, _now());
        _record(b.author, 0.25 ether, false, parent);
        claimsIn += 0.35 ether;
        _accrue(0.1 ether);
    }

    function notedSell(uint256 who, uint256 amount) public {
        if (created == 80) return;
        address author = _actor(who);
        T.NoteParams memory p = _params(false, false);
        _mature(p);
        uint256 claimsBefore = manager.balanceOf(address(hook), uint160(address(imd)));
        uint256 balanceBefore = imd.balanceOf(author);
        vm.prank(author);
        uint256 received = router.sellWithNote(p, key, bound(amount, 2 ether, 100 ether), 1, _now());
        uint256 taken = manager.balanceOf(address(hook), uint160(address(imd))) - claimsBefore;
        uint256 gross = received + taken;
        uint256 fee = gross / 100 + 0.1 ether;
        assertEq(taken, fee + 0.25 ether, "noted sell fee or bond changed");
        assertEq(imd.balanceOf(author) - balanceBefore, received);
        _record(author, 0.25 ether, false, 0);
        claimsIn += fee + 0.25 ether;
        _accrue(fee);
    }

    function trade(uint256 who, uint256 amount, bool buy) public {
        address author = _actor(who);
        uint256 price = hook.margPriceInImd();
        if ((buy && price > 1.5 ether) || (!buy && price < 0.7 ether)) return;
        // Large enough to generate both right and wrong calls, small enough to stay in the LP range.
        amount = bound(amount, 1 ether, 100_000 ether);
        uint256 before = manager.balanceOf(address(hook), uint160(address(imd)));
        uint256 received = plain.swap(key, buy ? !margIs0 : margIs0, amount, author);
        uint256 taken = manager.balanceOf(address(hook), uint160(address(imd))) - before;
        if (buy) {
            assertEq(taken, 0, "plain buy charged a hook fee");
        } else {
            uint256 fee = (received + taken) * 3 / 100;
            assertEq(taken, fee, "quiet sell must charge exactly 3 percent of gross output");
            claimsIn += fee;
            _accrue(fee);
        }
    }

    function fund(uint256 who, uint256 amount) public {
        amount = bound(amount, 1, 100 ether);
        vm.prank(_actor(who));
        hook.fundPot(amount);
        claimsIn += amount;
        _accrue(amount);
    }

    function giftAndDrip(uint256 who, uint256 amount) public {
        amount = bound(amount, 50, 100 ether);
        vm.prank(_actor(who));
        imd.transfer(address(treasury), amount);
        treasuryGifts += amount;
        uint256 day = _now() / 1 days;
        if (treasury.lastDripDay() == day) return;
        uint256 drip = imd.balanceOf(address(treasury)) / 50;
        treasury.drip();
        treasuryDrips += drip;
        drips++;
        claimsIn += drip;
        _accrue(drip);
    }

    function seal(uint256 who) public {
        T.NoteParams memory p = _params(true, false);
        _mature(p);
        // A unique commitment can lapse but cannot be replayed as a free pool credit.
        vm.prank(_actor(who));
        hook.seal(address(marg), p.venue, keccak256(abi.encode("sequence seal", ++sealsMade)));
        claimsIn += 0.1 ether;
        _accrue(0.1 ether);
    }

    function advance(uint256 secondsForward) public {
        _warp(_now() + bound(secondsForward, 0, 4 days));
    }

    function observeSeries(uint256 seed) public {
        if (created == 0) return;
        bytes32 id = _id(seed);
        Bond storage b = bonds[id];
        if (b.status != T.Status.Open || observed[id]) return;
        uint256 end = hook.horizonEnd(id);
        if (_now() > end + 5 hours) return;
        _warp(end);
        uint256 start = _now();
        uint256 price = hook.margPriceInImd();
        T.NoteView memory n = hook.noteOf(id);
        bool broken = n.side == T.Side.Buy && marg.balanceOf(b.author) < n.postBalance;
        bool right = n.side == T.Side.Buy
            ? price * 10_000 >= n.postPrice * n.targetBps
            : price * 10_000 <= n.postPrice * n.targetBps;
        observedOutcome[id] = broken ? T.Status.VoidSold : (right ? T.Status.Right : T.Status.Wrong);
        for (uint256 i; i < 3; ++i) {
            _warp(start + i * 30 minutes);
            vm.roll(vm.getBlockNumber() + 20);
            hook.observe(id);
        }
        observed[id] = true;
    }

    function _releaseParent(Bond storage b) private {
        if (b.parent != 0 && bonds[b.parent].status == T.Status.ThesisOpen) {
            bonds[b.parent].status = T.Status.ThesisClosed;
        }
    }

    function _forfeit(Bond storage b, bool rewardKeeper) private {
        uint256 amount = b.outstanding;
        uint256 reward = rewardKeeper ? amount / 10 : 0;
        b.outstanding = 0;
        b.forfeited += amount;
        claimsOut += reward;
        keeperPaid += reward;
        _accrue(amount - reward);
    }

    function settle(uint256 seed) public {
        if (created == 0) return;
        bytes32 id = _id(seed);
        Bond storage b = bonds[id];
        if (b.status == T.Status.ThesisOpen && b.children == 0) {
            _warp(b.postedAt + 7 days + 1);
            vm.prank(keeper);
            hook.settleThesis(id);
            b.status = T.Status.ThesisForfeited;
            _forfeit(b, true);
        } else if (b.status == T.Status.Open) {
            _warp(hook.horizonEnd(id) + 6 hours + 1);
            vm.prank(keeper);
            hook.settle(id);
            b.status = observed[id] ? observedOutcome[id] : T.Status.VoidNoData;
            if (b.status == T.Status.Wrong || b.status == T.Status.VoidSold) _forfeit(b, true);
            _releaseParent(b);
        } else {
            return;
        }
        settlements++;
    }

    function retract(uint256 seed) public {
        if (created == 0) return;
        bytes32 id = _id(seed);
        Bond storage b = bonds[id];
        if (b.status != T.Status.Open || _now() >= hook.horizonEnd(id)) return;
        vm.prank(b.author);
        hook.retract(id, "retracted during random sequence");
        b.status = T.Status.Retracted;
        if (!b.refundPaid) expectedWriters[b.day]--;
        _forfeit(b, false);
        _releaseParent(b);
        retractions++;
    }

    function claimDeposit(uint256 seed) public {
        if (created == 0) return;
        bytes32 id = _id(seed);
        Bond storage b = bonds[id];
        if (b.outstanding == 0) return;
        if (
            b.status != T.Status.Right && b.status != T.Status.VoidNoData && b.status != T.Status.ThesisClosed
        ) return;
        uint256 before = imd.balanceOf(b.author);
        vm.prank(b.author);
        hook.claimDeposit(id);
        assertEq(imd.balanceOf(b.author) - before, b.outstanding, "bond refund was not exact");
        claimsOut += b.outstanding;
        b.claimed += b.outstanding;
        b.outstanding = 0;
        depositClaims++;
    }

    function claimRefund(uint256 seed) public {
        if (created == 0) return;
        bytes32 id = _id(seed);
        Bond storage b = bonds[id];
        if (b.refundPaid || b.status == T.Status.Retracted || b.day >= _now() / 1 days) return;
        uint256 amount = expectedRefund[b.day] / expectedWriters[b.day];
        if (amount > 0.1 ether) amount = 0.1 ether;
        if (amount == 0) return;
        uint256 before = imd.balanceOf(b.author);
        vm.prank(b.author);
        hook.claimRefund(id);
        assertEq(imd.balanceOf(b.author) - before, amount, "writer refund differs from equal capped share");
        b.refundPaid = true;
        expectedWriters[b.day]--;
        expectedRefund[b.day] -= amount;
        claimsOut += amount;
        refundsPaid += amount;
    }

    function sweep(uint256 seed, bool weekly) public {
        if (daysSeen.length == 0) return;
        uint32 epoch;
        uint256 amount;
        if (weekly) {
            epoch = weeksSeen[seed % weeksSeen.length];
            amount = expectedThesis[epoch];
            if (amount == 0 || pending[epoch] || expectedJudged[epoch]) return;
            _warp((uint256(epoch) + 1) * 7 days + 28 days);
            hook.sweep(1, epoch);
            expectedThesis[epoch] = 0;
        } else {
            epoch = daysSeen[seed % daysSeen.length];
            amount = expectedRefund[epoch];
            if (amount == 0) return;
            _warp((uint256(epoch) + 1) * 1 days + 28 days);
            hook.sweep(0, epoch);
            expectedRefund[epoch] = 0;
        }
        _trackEpochs();
        expectedThesis[uint32(_now() / 7 days)] += amount;
        sweeps++;
    }

    function requestJudging(uint256 seed) public {
        uint32 w = weeksSeen[seed % weeksSeen.length];
        if (expectedJudged[w] || judge.eligibleTheses(w).length == 0) return;
        bool retry = judge.requestOf(w) != bytes32(0);
        if (expectedThesis[w] < (retry ? 0.5 ether : 2 ether)) return;
        _warp((uint256(w) + 1) * 7 days);
        if (!retry && _now() < (uint256(w) + 2) * 7 days) {
            uint256 claimsBefore = manager.balanceOf(address(hook), uint160(address(imd)));
            vm.expectRevert(MarginaliaHook.TooEarly.selector);
            judge.requestJudging(w);
            assertEq(judge.requestOf(w), bytes32(0), "early request consumed a request id");
            assertEq(judge.requestedAt(w), 0, "early request started the retry clock");
            assertEq(hook.thesisPool(w), expectedThesis[w], "early judging spent prize funds");
            assertEq(manager.balanceOf(address(hook), uint160(address(imd))), claimsBefore);
            assertEq(imd.balanceOf(hook.INTAKE()), oracleSpent, "early judging paid the Intake");
            earlyJudgingRefusals++;
            _warp((uint256(w) + 2) * 7 days);
        }
        if (retry) _warp(uint256(judge.requestedAt(w)) + 3 days);
        judge.requestJudging(w);
        expectedThesis[w] -= 0.5 ether;
        oracleSpent += 0.5 ether;
        claimsOut += 0.5 ether;
        pending[w] = true;
        judgingRequests++;
    }

    function answerJudging(uint256 seed, bool empty, bool reverse) public {
        uint32 w = weeksSeen[seed % weeksSeen.length];
        if (!pending[w]) return;
        bytes32[] memory eligible = judge.eligibleTheses(w);
        uint256 size = empty ? 0 : (eligible.length < 3 ? eligible.length : 3);
        bytes32[] memory ranked = new bytes32[](size);
        for (uint256 i; i < size; ++i) {
            ranked[i] = eligible[reverse ? eligible.length - i - 1 : i];
            expectedHead[w][i] = ranked[i];
        }
        OracleAttestation.Attestation memory a;
        bytes32 requestId = judge.requestOf(w);
        a.requestId = keccak256(abi.encode("accounting oracle response", requestId));
        a.chainId = block.chainid;
        a.answerType = 5;
        a.answer = abi.encode(ranked);
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        a.issuedAt = uint64(_now());
        a.expiresAt = uint64(_now() + 1 days);
        // Fixture's ERC-1271 signer accepts this response; signature verification has its own suite.
        vm.prank(hook.INTAKE());
        judge.onOracleResult(requestId, a, "");
        pending[w] = false;
        expectedJudged[w] = true;
    }

    function payJudging(uint256 seed) public {
        uint32 w = weeksSeen[seed % weeksSeen.length];
        if (!expectedJudged[w] || expectedPaid[w]) return;
        uint256 pool = expectedThesis[w];
        uint256 remainder = pool;
        uint256[3] memory shares = [pool / 2, pool * 3 / 10, pool / 5];
        uint256[3] memory beforeBalances;
        for (uint256 i; i < 3; ++i) {
            beforeBalances[i] = imd.balanceOf(actors[i]);
        }
        judge.payJudged(w);
        uint256[3] memory rewards;
        for (uint256 i; i < 3; ++i) {
            bytes32 id = expectedHead[w][i];
            if (id == 0) continue;
            for (uint256 j; j < 3; ++j) {
                if (bonds[id].author == actors[j]) rewards[j] += shares[i];
            }
            remainder -= shares[i];
        }
        for (uint256 i; i < 3; ++i) {
            assertEq(imd.balanceOf(actors[i]) - beforeBalances[i], rewards[i], "wrong ranked author's payout");
        }
        expectedThesis[w] = 0;
        _trackEpochs();
        expectedThesis[uint32(_now() / 7 days)] += remainder;
        expectedPaid[w] = true;
        claimsOut += pool - remainder;
        prizesPaid += pool - remainder;
    }

    function abandonJudging(uint256 seed) public {
        uint32 w = weeksSeen[seed % weeksSeen.length];
        if (!pending[w]) return;
        _warp(uint256(judge.requestedAt(w)) + 3 days);
        judge.abandonRequest(w);
        pending[w] = false;
    }

    function unauthorizedClaim(uint256 seed, uint256 who) public {
        if (created == 0) return;
        bytes32 id = _id(seed);
        address caller = _actor(who);
        if (caller == bonds[id].author) caller = keeper;
        vm.startPrank(caller);
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.claimDeposit(id);
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.claimRefund(id);
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.retract(id, "stolen");
        vm.stopPrank();
    }

    function assertLedger() external view {
        uint256 obligations;
        for (uint256 i; i < weeksSeen.length; ++i) {
            uint32 w = weeksSeen[i];
            assertEq(hook.thesisPool(w), expectedThesis[w], "weekly pool diverged from independent ledger");
            assertEq(judge.judgedSet(w), expectedJudged[w]);
            assertEq(judge.paid(w), expectedPaid[w]);
            assertEq(hook.judgedPaid(w), expectedPaid[w]);
            uint256 thesisCount;
            for (uint256 j; j < actors.length; ++j) {
                uint256 count = expectedAuthorTheses[w][actors[j]];
                assertLe(count, 3, "one author exceeded the weekly thesis limit");
                assertEq(hook.thesesPerAuthor(w, actors[j]), count, "weekly author count drifted");
                thesisCount += count;
            }
            assertEq(hook.thesesOfWeek(w).length, thesisCount, "weekly thesis set drifted");
            obligations += expectedThesis[w];
        }
        for (uint256 i; i < daysSeen.length; ++i) {
            uint32 d = daysSeen[i];
            assertEq(hook.refundPool(d), expectedRefund[d], "daily pool diverged from independent ledger");
            assertEq(hook.notesPerDay(d), expectedWriters[d], "writer denominator drifted");
            obligations += expectedRefund[d];
        }
        for (uint256 i = 1; i <= created; ++i) {
            Bond storage b = bonds[bytes32(i)];
            T.NoteView memory n = hook.noteOf(bytes32(i));
            assertEq(n.deposit, b.outstanding, "bond balance differs from lifecycle ledger");
            assertEq(uint8(n.status), uint8(b.status), "incorrect or reopened terminal status");
            assertEq(n.children, b.children);
            assertEq(n.author, b.author);
            assertEq(hook.refundClaimed(bytes32(i)), b.refundPaid);
            assertEq(b.outstanding + b.claimed + b.forfeited, b.original, "bond value created or lost");
            assertLe(b.claimed, b.original, "a bond paid more than deposited");
            obligations += b.outstanding;
        }
        uint256 held = manager.balanceOf(address(hook), uint160(address(imd)));
        assertEq(held, obligations, "IMD claims do not equal all bonds and pools");
        assertEq(held, claimsIn - claimsOut, "claims were created or destroyed without a matching flow");
        assertGe(imd.balanceOf(address(manager)), held, "manager lacks claim backing");
        assertEq(imd.balanceOf(keeper), keeperPaid, "keeper paid other than ten percent of forfeits");
        assertEq(imd.balanceOf(address(treasury)), treasuryGifts - treasuryDrips);
        assertEq(
            imd.balanceOf(hook.INTAKE()), oracleSpent, "oracle received something other than request prices"
        );
        assertEq(imd.balanceOf(address(judge)), 0, "judge stranded request funds");
        assertEq(imd.allowance(address(judge), hook.INTAKE()), 0, "judge left a spending approval");
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 80
/// forge-config: default.invariant.fail-on-revert = true
contract HookAccountingInvariantTest is Fixture {
    HookAccountingHandler internal handler;
    address internal keeper = makeAddr("accounting keeper");

    function setUp() public {
        _setup();
        address[3] memory actors = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            imd.transfer(actors[i], 25_000_000 ether);
            token.transfer(actors[i], 25_000_000 ether);
        }
        handler = new HookAccountingHandler(hook, plain, actors, keeper);
        // Seed reachable state so no run can pass with only rejected calls or an empty ledger.
        handler.post(0, 1 ether, true, false);
        handler.post(1, 2 ether, false, false);
        handler.post(2, 3 ether, true, true);
        handler.child(3);
        handler.fund(0, 10 ether);
        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = handler.post.selector;
        selectors[1] = handler.child.selector;
        selectors[2] = handler.notedSell.selector;
        selectors[3] = handler.trade.selector;
        selectors[4] = handler.fund.selector;
        selectors[5] = handler.giftAndDrip.selector;
        selectors[6] = handler.seal.selector;
        selectors[7] = handler.advance.selector;
        selectors[8] = handler.observeSeries.selector;
        selectors[9] = handler.settle.selector;
        selectors[10] = handler.retract.selector;
        selectors[11] = handler.claimDeposit.selector;
        selectors[12] = handler.claimRefund.selector;
        selectors[13] = handler.sweep.selector;
        selectors[14] = handler.unauthorizedClaim.selector;
        selectors[15] = handler.post.selector;
        selectors[16] = handler.requestJudging.selector;
        selectors[17] = handler.answerJudging.selector;
        selectors[18] = handler.payJudging.selector;
        selectors[19] = handler.abandonJudging.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_everyImdClaimHasExactlyOneObligation() public view {
        handler.assertLedger();
        assertEq(imd.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(_claims(address(hook), address(token)), 0, "MARG claims must never be retained");
        assertEq(hook.potMarg(), 0);
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(hook.noteCount(), handler.created());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        uint256 balances = token.balanceOf(address(this)) + token.balanceOf(address(liquidity))
            + token.balanceOf(address(manager)) + token.balanceOf(alice) + token.balanceOf(bob)
            + token.balanceOf(carol);
        assertEq(balances, token.totalSupply(), "random trading minted, burned or lost MARG");
    }

    function testAccountingHandlerModelsThesisCapAcrossClosureAndWeekRollover() public {
        uint32 w = hook.week();
        handler.post(2, 1 ether, true, true);
        handler.post(2, 1 ether, true, true);
        assertEq(handler.expectedAuthorTheses(w, carol), 3);
        handler.post(2, 1 ether, true, true);
        assertEq(handler.thesisCapRefusals(), 1);
        assertEq(handler.created(), 6);

        // Resolving an admitted thesis must not let the same author recycle a slot this week.
        handler.retract(4);
        assertEq(uint8(hook.noteOf(bytes32(uint256(3))).status), uint8(T.Status.ThesisClosed));
        handler.post(2, 1 ether, true, true);
        assertEq(handler.thesisCapRefusals(), 2);
        this.invariant_everyImdClaimHasExactlyOneObligation();

        vm.warp((uint256(w) + 1) * 7 days);
        handler.post(2, 1 ether, true, true);
        assertEq(handler.created(), 7);
        assertEq(handler.expectedAuthorTheses(w, carol), 3);
        assertEq(handler.expectedAuthorTheses(w + 1, carol), 1);
        this.invariant_everyImdClaimHasExactlyOneObligation();
    }

    function testAccountingHandlerRefusesChildWhoseCheckpointMaturesAfterGrace() public {
        handler.post(0, 2 ether, true, true);
        bytes32 parent = bytes32(uint256(5));
        uint256 postedAt = vm.getBlockTimestamp();
        vm.warp(postedAt + 7 days - 30 minutes);
        handler.child(5);
        assertEq(vm.getBlockTimestamp(), postedAt + 7 days + 30 minutes);
        assertEq(handler.lateChildRefusals(), 1);
        assertEq(handler.created(), 5);
        assertEq(hook.noteOf(parent).children, 0);
        assertEq(hook.noteOf(parent).deposit, 2 ether);
        this.invariant_everyImdClaimHasExactlyOneObligation();
        handler.settle(5);
        assertEq(uint8(hook.noteOf(parent).status), uint8(T.Status.ThesisForfeited));
        assertEq(handler.keeperPaid(), 0.2 ether);
        this.invariant_everyImdClaimHasExactlyOneObligation();
    }

    function testAccountingHandlerChecksGraceThenAllowsPaidRetry() public {
        uint32 w = hook.week();
        handler.requestJudging(0);
        assertEq(handler.earlyJudgingRefusals(), 1);
        assertEq(handler.judgingRequests(), 1);
        assertEq(judge.requestedAt(w), (uint256(w) + 2) * 7 days);
        bytes32 first = judge.requestOf(w);
        handler.abandonJudging(0);
        handler.requestJudging(0);
        assertNotEq(judge.requestOf(w), first);
        assertEq(handler.judgingRequests(), 2);
        assertEq(handler.oracleSpent(), 1 ether);
        handler.answerJudging(0, true, false);
        handler.payJudging(0);
        assertEq(hook.thesisPool(w), 0);
        assertEq(handler.prizesPaid(), 0, "empty head must roll forward without paying a writer");
        this.invariant_everyImdClaimHasExactlyOneObligation();
    }

    /// @dev A deterministic path makes handler coverage and its accounting assertions reviewable.
    function testAccountingHandlerExercisesPayoutsForfeitsSealsDripsAndSweeps() public {
        handler.observeSeries(1);
        handler.settle(1);
        handler.claimRefund(1);
        handler.settle(2);
        handler.claimDeposit(2);
        handler.settle(4);
        handler.claimDeposit(3);
        handler.requestJudging(0);
        handler.answerJudging(0, false, false);
        handler.payJudging(0);
        handler.post(0, 4 ether, true, false);
        handler.retract(5);
        handler.seal(0);
        handler.giftAndDrip(1, 50 ether);
        handler.sweep(0, false);
        handler.sweep(0, true);
        assertGt(handler.settlements(), 0);
        assertGt(handler.keeperPaid(), 0);
        assertGt(handler.refundsPaid(), 0);
        assertGt(handler.depositClaims(), 0);
        assertGt(handler.retractions(), 0);
        assertGt(handler.sealsMade(), 0);
        assertGt(handler.drips(), 0);
        assertGt(handler.sweeps(), 0);
        assertGt(handler.judgingRequests(), 0);
        assertGt(handler.prizesPaid(), 0);
        this.invariant_everyImdClaimHasExactlyOneObligation();
    }
}
