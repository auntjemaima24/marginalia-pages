// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, MockIntake} from "./helpers/Fixture.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaJudge} from "../src/MarginaliaJudge.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MarginaliaRouter} from "../src/MarginaliaRouter.sol";

/// @dev A contract that answers slot0() with whatever it likes: the self-priced venue the audit proved.
contract FakePool {
    address public token0;
    address public token1;
    uint24 public fee = 3000;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(1) << 100, 0, 0, 0, 0, 0, true);
    }
}
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract LifecycleTest is Fixture {
    function setUp() public {
        _setup();
    }

    function _pot() internal view returns (uint256) {
        return hook.refundPool(hook.today()) + hook.thesisPool(hook.week());
    }

    function testFlagsAndBinding() public view {
        assertTrue(HookFlags.matches(address(hook), HookFlags.MARGINALIA));
        assertTrue(hook.initialized());
        assertEq(hook.imd(), address(imd));
        assertEq(address(hook.router()), address(router));
        assertEq(hook.margPriceInImd(), 1e18);
    }

    function testCallbackSelectorPinned() public view {
        // Same signature as the protocol's reference consumer (AskOracle), whose documented selector is 0x510379c7.
        assertEq(judge.onOracleResult.selector, bytes4(0x510379c7));
    }

    function testPlainBuyTakesNothing() public {
        uint256 pot = _pot();
        uint256 out = _buy(alice, 10 ether);
        assertGt(out, 9 ether);
        assertEq(_pot(), pot);
        assertEq(hook.noteCount(), 0);
    }

    function testNotedBuyTakesStampAndDeposit() public {
        uint256 margBefore = token.balanceOf(alice);
        (bytes32 id, uint256 received) =
            _note(alice, _margNote(T.Side.Buy, 20_000, 7, "2x: fee pot compounding"), 10 ether);
        T.NoteView memory n = hook.noteOf(id);
        assertEq(n.author, alice);
        assertEq(uint8(n.status), uint8(T.Status.Open));
        assertEq(uint8(n.class), uint8(T.Class.Declared));
        // the author sent 10 IMD: 0.1 stamp, 0.25 bought MARG, the remaining 9.65 is the bond, held as IMD
        assertEq(n.deposit, 10 ether - hook.STAMP() - hook.MARG_BUY());
        assertApproxEqRel(n.postPrice, 1e18, 0.02e18);
        assertEq(_pot(), hook.STAMP());
        assertEq(_claims(address(hook), address(imd)), hook.STAMP() + n.deposit);
        assertEq(_claims(address(hook), address(token)), 0);
        assertEq(token.balanceOf(alice) - margBefore, received);
        assertGt(received, 0.2 ether);
        assertLt(received, hook.MARG_BUY());
    }

    function testNoteTooSmall() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "tiny");
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, key, 0.15 ether, 1, block.timestamp + 1);
        // just under the minimum bond, and just over the maximum (amounts computed first: expectRevert
        // arms against the very next external call, which must be the note itself)
        uint256 floor = hook.STAMP() + hook.MARG_BUY() + hook.BOND_MIN();
        uint256 ceiling = hook.STAMP() + hook.MARG_BUY() + hook.BOND_MAX();
        uint256 deadline = block.timestamp + 1;
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, key, floor - 1, 1, deadline);
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, key, ceiling + 1, 1, deadline);
        // the band's edges post
        (bytes32 lo,) = _note(alice, p, floor);
        assertEq(hook.noteOf(lo).deposit, hook.BOND_MIN());
        p.text = "max";
        (bytes32 hi,) = _note(alice, p, ceiling);
        assertEq(hook.noteOf(hi).deposit, hook.BOND_MAX());
    }

    function testUpOnlyIsRefused() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 10_500, 7, "up");
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, key, 10 ether, 1, block.timestamp + 1);
    }

    function testQuietSellPaysThreePercent() public {
        uint256 potBefore = _pot();
        uint256 out = _sell(bob, 100 ether);
        uint256 fee = _pot() - potBefore;
        // fee = 3% of what the pool paid out; the seller received pool output minus fee
        assertApproxEqRel(fee, (out + fee) * 300 / 10_000, 0.001e18);
        assertEq(_claims(address(hook), address(imd)), fee);
    }

    function testNotedSellPaysOnePercentPlusStamp() public {
        vm.prank(bob);
        token.approve(address(router), type(uint256).max);
        uint256 potBefore = _pot();
        uint256 claimsBefore = _claims(address(hook), address(imd));
        T.NoteParams memory p = _margNote(T.Side.Sell, 7000, 14, "MARG -30%: airdrop supply still unwinding");
        vm.prank(bob);
        uint256 out = router.sellWithNote(p, key, 100 ether, 1, block.timestamp + 1);
        bytes32 id = bytes32(hook.noteCount());
        T.NoteView memory n = hook.noteOf(id);
        assertEq(n.author, bob);
        assertEq(uint8(n.side), uint8(T.Side.Sell));
        assertEq(n.deposit, hook.BOND_MIN(), "a noted sell bonds the minimum, off its IMD output");
        uint256 taken = _pot() - potBefore;
        assertEq(_claims(address(hook), address(imd)) - claimsBefore, taken + n.deposit);
        // the pool paid out (out + taken + bond); 1% of that plus the 0.1 stamp went to the pools
        assertApproxEqRel(taken - hook.STAMP(), (out + taken + n.deposit) * 100 / 10_000, 0.001e18);
        // cheaper than the quiet path on the same size
        uint256 potMid = _pot();
        _sell(bob, 100 ether);
        uint256 quiet = _pot() - potMid;
        assertGt(quiet, taken);
    }

    function testRightCallReturnsDeposit() public {
        (bytes32 id,) = _note(
            alice, _margNote(T.Side.Buy, 11_000, 1, "+10% in a day: the airdrop sells are done"), 10 ether
        );
        // bob pushes the price up more than 10%
        _buy(bob, 1_500_000 ether);
        assertGt(hook.margPriceInImd(), 1.1e18);
        vm.warp(hook.horizonEnd(id));
        uint256 startBlock = block.number;
        uint256 startTs = block.timestamp;
        for (uint256 i = 0; i < 3; ++i) {
            hook.observe(id);
            vm.roll(startBlock + 25 * (i + 1));
            vm.warp(startTs + 30 minutes * (i + 1));
        }
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.settle(id);
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        T.NoteView memory n = hook.noteOf(id);
        assertEq(uint8(n.status), uint8(T.Status.Right));
        MarginaliaHook.Record memory r = _rec(alice);
        assertEq(r.right, 1);
        assertGt(r.score, 0);
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        hook.claimDeposit(id);
        assertEq(imd.balanceOf(alice) - imdBefore, n.deposit, "the bond comes back in IMD, exactly");
        assertEq(_claims(address(hook), address(imd)), hook.STAMP(), "only the stamp remains with the hook");
        assertEq(hook.noteOf(id).deposit, 0);
    }

    function testWrongCallForfeitsWithKeeperReward() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 15_000, 1, "+50%: no"), 10 ether);
        uint256 deposit = hook.noteOf(id).deposit;
        vm.warp(hook.horizonEnd(id));
        uint256 startBlock = block.number;
        uint256 startTs = block.timestamp;
        for (uint256 i = 0; i < 3; ++i) {
            hook.observe(id);
            vm.roll(startBlock + 25 * (i + 1));
            vm.warp(startTs + 30 minutes * (i + 1));
        }
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        uint256 potBefore = _pot();
        vm.prank(carol);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
        uint256 bounty = deposit * hook.KEEPER_BPS() / 10_000;
        assertEq(bounty, deposit / 10);
        assertEq(imd.balanceOf(carol), bounty, "the keeper is paid in IMD");
        assertEq(_pot() - potBefore, deposit - bounty, "the forfeit accrues to the pools as IMD");
        assertLt(_rec(alice).score, 0);
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
        hook.claimDeposit(id);
    }

    function testSellingEarlyBreaksTheCall() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        _buy(bob, 1_500_000 ether);
        _sell(alice, token.balanceOf(alice) / 2);
        vm.warp(hook.horizonEnd(id));
        uint256 startBlock = block.number;
        uint256 startTs = block.timestamp;
        for (uint256 i = 0; i < 3; ++i) {
            hook.observe(id);
            vm.roll(startBlock + 25 * (i + 1));
            vm.warp(startTs + 30 minutes * (i + 1));
        }
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidSold));
        assertEq(_rec(alice).broken, 1);
    }

    function testNoDataRefunds() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        uint256 deposit = hook.noteOf(id).deposit;
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidNoData));
        // Revision finding 0a0c1d10: an unobserved call is not a free option. It scores as a wrong one
        // (so posting both sides and observing only the winner nets zero) but its deposit still comes back.
        assertLt(_rec(alice).score, 0);
        assertEq(_rec(alice).wrong, 0);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        hook.claimDeposit(id);
        assertEq(imd.balanceOf(alice) - before, deposit);
    }

    function testRetract() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 20_000, 7, "2x"), 10 ether);
        uint256 deposit = hook.noteOf(id).deposit;
        vm.prank(bob);
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.retract(id, "not mine");
        uint256 potBefore = _pot();
        vm.prank(alice);
        hook.retract(id, "thesis dead: the dev sold");
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Retracted));
        assertEq(_pot() - potBefore, deposit);
        assertLt(_rec(alice).score, 0);
        assertEq(_rec(alice).retracted, 1);
    }

    function testThesisParentChild() public {
        T.NoteParams memory thesis =
            _margNote(T.Side.Buy, 0, 0, "Privacy re-rates after the next exploit: citations...");
        (bytes32 tid,) = _note(alice, thesis, 10 ether);
        assertEq(uint8(hook.noteOf(tid).status), uint8(T.Status.ThesisOpen));
        T.NoteParams memory child = _margNote(T.Side.Buy, 11_000, 1, "child call");
        child.parentId = tid;
        (bytes32 cid,) = _note(alice, child, 10 ether);
        assertEq(hook.noteOf(tid).children, 1);
        vm.warp(hook.horizonEnd(cid) + hook.SETTLE_WINDOW() + 1);
        hook.settle(cid); // no data, but it resolved
        assertEq(uint8(hook.noteOf(tid).status), uint8(T.Status.ThesisClosed));
        vm.prank(alice);
        hook.claimDeposit(tid);
    }

    function testThesisWithoutChildForfeits() public {
        (bytes32 tid,) = _note(alice, _margNote(T.Side.Buy, 0, 0, "essay"), 10 ether);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.settleThesis(tid);
        vm.warp(block.timestamp + 8 days);
        uint256 deposit = hook.noteOf(tid).deposit;
        uint256 potBefore = _pot();
        hook.settleThesis(tid);
        assertEq(uint8(hook.noteOf(tid).status), uint8(T.Status.ThesisForfeited));
        assertEq(_pot() - potBefore, deposit - deposit * hook.KEEPER_BPS() / 10_000);
    }

    function testTreasuryDrip() public {
        imd.transfer(address(treasury), 1000 ether);
        treasury.drip();
        assertEq(_pot(), 20 ether);
        vm.expectRevert(MarginaliaHook.PotTooSmall.selector);
        hook.fundPot(0);
        vm.expectRevert();
        treasury.drip();
    }

    function testWeeklyThesisJudging() public {
        uint32 w = hook.week();
        (bytes32 a1,) = _note(alice, _margNote(T.Side.Buy, 0, 0, "thesis A: cited, argued"), 10 ether);
        (bytes32 b1,) = _note(bob, _margNote(T.Side.Buy, 0, 0, "thesis B: shorter"), 10 ether);
        T.NoteParams memory ca = _margNote(T.Side.Buy, 20_000, 7, "alice's child call");
        ca.parentId = a1;
        (bytes32 call1,) = _note(alice, ca, 10 ether);
        T.NoteParams memory cb = _margNote(T.Side.Buy, 20_000, 7, "bob's child call");
        cb.parentId = b1;
        _note(bob, cb, 10 ether);
        vm.prank(alice);
        hook.fundPot(20 ether); // 70% of this lands in the thesis pool
        assertEq(hook.thesesOfWeek(w).length, 2);
        assertEq(hook.thesisPool(w), (20 ether + 4 * hook.STAMP()) * 70 / 100);
        vm.expectRevert();
        judge.requestJudging(w); // week not over
        vm.warp((uint256(w) + 1) * 7 days + hook.THESIS_GRACE());
        bytes32 reqId = judge.requestJudging(w);
        MockIntake intake = MockIntake(hook.INTAKE());
        assertEq(intake.requests(), 1);
        assertEq(intake.lastTarget(), address(judge));
        bytes32[] memory ranked = new bytes32[](3);
        ranked[0] = b1;
        ranked[1] = call1; // a short call in the ranking is ignored
        ranked[2] = a1;
        OracleAttestation.Attestation memory att = OracleAttestation.Attestation({
            requestId: bytes32(uint256(0xabc)),
            chainId: block.chainid,
            questionHash: keccak256("q"),
            answerType: 5,
            answer: abi.encode(ranked),
            figure: 0,
            fromBlock: uint64(block.number - 100),
            toBlock: uint64(block.number),
            blockHash: blockhash(block.number - 1),
            panelJobId: bytes32(uint256(0xdef)),
            panelSize: 7,
            quorum: 5,
            agreed: 6,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 1 days)
        });
        vm.prank(hook.INTAKE());
        judge.onOracleResult(reqId, att, hex"01");
        bytes32[3] memory top = judge.judgedOf(w);
        assertEq(top[0], b1);
        assertEq(top[1], a1);
        assertEq(top[2], bytes32(0));
        uint256 pool = hook.thesisPool(w);
        uint256 bobBefore = imd.balanceOf(bob);
        uint256 aliceBefore = imd.balanceOf(alice);
        judge.payJudged(w);
        assertEq(imd.balanceOf(bob) - bobBefore, pool * 50 / 100);
        assertEq(imd.balanceOf(alice) - aliceBefore, pool * 30 / 100);
        assertEq(hook.thesisPool(w), 0);
        assertEq(hook.thesisPool(hook.week()), pool * 20 / 100);
    }

    /// @dev Score is reputation: it nets across calls and no pool pays for it. Accruals split 70% thesis / 30% refund.
    function testScoreIsReputationAndAccrualsSplitSeventyThirty() public {
        uint32 w = hook.week();
        uint32 d = hook.today();
        (bytes32 a,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        (bytes32 b,) = _note(bob, _margNote(T.Side.Buy, 15_000, 1, "+50%"), 10 ether);
        uint256 thesisBefore = hook.thesisPool(w);
        uint256 refundBefore = hook.refundPool(d);
        vm.prank(alice);
        hook.fundPot(100 ether);
        assertEq(hook.thesisPool(w) - thesisBefore, 70 ether);
        assertEq(hook.refundPool(d) - refundBefore, 30 ether);
        _buy(bob, 1_500_000 ether);
        vm.warp(hook.horizonEnd(a));
        uint256 startBlock = block.number;
        uint256 startTs = block.timestamp;
        for (uint256 i = 0; i < 3; ++i) {
            hook.observe(a);
            hook.observe(b);
            vm.roll(startBlock + 25 * (i + 1));
            vm.warp(startTs + 30 minutes * (i + 1));
        }
        vm.warp(hook.horizonEnd(a) + hook.SETTLE_WINDOW() + 1);
        hook.settle(a);
        hook.settle(b);
        assertGt(_rec(alice).score, 0);
        assertLt(_rec(bob).score, 0);
        // an old refund pool sweeps into the current thesis prize, never into a score
        uint256 refundLeft = hook.refundPool(d);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.sweep(0, d);
        vm.warp((uint256(d) + 1) * 1 days + hook.SWEEP_AFTER() + 1);
        uint256 thesisNow = hook.thesisPool(hook.week());
        hook.sweep(0, d);
        assertEq(hook.refundPool(d), 0);
        assertEq(hook.thesisPool(hook.week()) - thesisNow, refundLeft);
    }

    function testFakeVenueIsRefused() public {
        // a note priced by a contract the author controls is refused by the router before anything is pulled
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "self-priced");
        address fake = address(new FakePool(address(token), address(imd)));
        p.venue = T.Venue(T.VenueKind.UniV3, bytes32(uint256(uint160(fake))), address(0), false);
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, key, 10 ether, 1, block.timestamp + 1);
        // a v4 id that does not match the key is refused too
        p = _margNote(T.Side.Buy, 20_000, 7, "wrong id");
        p.venue.ref = bytes32(uint256(1));
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.BadVenue.selector);
        router.note(p, key, 10 ether, 1, block.timestamp + 1);
        // a note about a token the pool does not contain is refused
        p = _margNote(T.Side.Buy, 20_000, 7, "not in pool");
        p.x = address(0xBEEF);
        vm.etch(address(0xBEEF), hex"00");
        vm.prank(alice);
        vm.expectRevert(MarginaliaRouter.BadVenue.selector);
        router.note(p, key, 10 ether, 1, block.timestamp + 1);
    }

    function testAttestedClassCannotBeSelfDeclared() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 20_000, 7, "attested?");
        p.class = uint8(T.Class.Attested);
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, key, 10 ether, 1, block.timestamp + 1);
    }

    function testUnansweredWeekCanBeRetried() public {
        uint32 w = hook.week();
        (bytes32 tid,) = _note(alice, _margNote(T.Side.Buy, 0, 0, "thesis"), 10 ether);
        T.NoteParams memory child = _margNote(T.Side.Buy, 11_000, 1, "child");
        child.parentId = tid;
        _note(alice, child, 10 ether);
        vm.prank(alice);
        hook.fundPot(20 ether);
        vm.warp((uint256(w) + 1) * 7 days + hook.THESIS_GRACE());
        judge.requestJudging(w);
        vm.expectRevert(MarginaliaJudge.AlreadyRequested.selector);
        judge.requestJudging(w);
        assertFalse(judge.weekClosed(w));
        vm.warp(block.timestamp + judge.ANSWER_DEADLINE() + 1);
        bytes32 second = judge.requestJudging(w); // the panel never answered: retry, paying only the price
        assertTrue(second != bytes32(0));
    }

    function testQuietThesisPoolSweeps() public {
        uint32 w = hook.week();
        vm.prank(alice);
        hook.fundPot(10 ether); // 3 IMD into this week's thesis pool, no theses posted
        uint256 pot = hook.thesisPool(w);
        assertGt(pot, 0);
        vm.warp((uint256(w) + 1) * 7 days + hook.SWEEP_AFTER() + 1);
        assertTrue(judge.weekClosed(w));
        uint256 nowPool = hook.thesisPool(hook.week());
        hook.sweep(1, w);
        assertEq(hook.thesisPool(w), 0);
        assertEq(hook.thesisPool(hook.week()) - nowPool, pot);
    }

    function testWriterRefundCappedAtStamp() public {
        uint32 day = hook.today();
        (bytes32 a,) = _note(alice, _margNote(T.Side.Buy, 20_000, 7, "A"), 10 ether);
        (bytes32 b,) = _note(bob, _margNote(T.Side.Buy, 20_000, 7, "B"), 10 ether);
        vm.prank(alice);
        hook.fundPot(50 ether); // 20% = 10 IMD into today's refund pool: plenty, so the cap binds
        assertEq(hook.notesPerDay(day), 2);
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.claimRefund(a);
        vm.warp(block.timestamp + 1 days);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        hook.claimRefund(a);
        assertEq(imd.balanceOf(alice) - before, hook.STAMP());
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
        hook.claimRefund(a);
        // a retracted note cannot claim
        vm.prank(bob);
        hook.retract(b, "changed my mind");
        vm.prank(bob);
        vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
        hook.claimRefund(b);
    }

    /// @dev Bonds are IMD: a forfeit lands in the pools at once and the deployed judge has nothing to convert.
    function testForfeitsAreImdAndNeedNoConversion() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 20_000, 7, "2x"), 10 ether);
        uint256 deposit = hook.noteOf(id).deposit;
        uint256 potBefore = _pot();
        vm.prank(alice);
        hook.retract(id, "out");
        assertEq(_pot() - potBefore, deposit);
        assertEq(hook.potMarg(), 0);
        assertEq(judge.convertForfeits(), 0);
        assertEq(_claims(address(hook), address(token)), 0, "the hook never holds MARG claims");
    }

    /// @dev The parked finding: pump, observe one block later, unwind. The adverse rule settles on the honest
    /// observations around it, so the pumped block is worth nothing to the caller.
    function testTwoBlockPumpObserveUnwindSettlesWrong() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        vm.warp(hook.horizonEnd(id));
        uint256 startBlock = block.number;
        uint256 startTs = block.timestamp;
        hook.observe(id); // honest, flat
        vm.roll(startBlock + 25);
        vm.warp(startTs + 30 minutes);
        _buy(bob, 1_500_000 ether); // pump
        assertGt(hook.margPriceInImd(), 1.1e18);
        vm.roll(startBlock + 26);
        hook.observe(id); // the pumped block
        vm.roll(startBlock + 27);
        _sell(bob, token.balanceOf(bob)); // unwind
        vm.roll(startBlock + 50);
        vm.warp(startTs + 60 minutes);
        hook.observe(id); // honest again
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
    }

    /// @dev Three observations inside one hour are not a series: the call voids as no-data rather than settling.
    function testObservationsMustSpanAnHour() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        _buy(bob, 1_500_000 ether);
        vm.warp(hook.horizonEnd(id));
        uint256 startBlock = block.number;
        uint256 startTs = block.timestamp;
        for (uint256 i = 0; i < 3; ++i) {
            hook.observe(id);
            vm.roll(startBlock + 25 * (i + 1));
            vm.warp(startTs + 10 minutes * (i + 1));
        }
        vm.warp(hook.horizonEnd(id) + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.VoidNoData));
    }

    /// @dev A rebuttal is a thesis that points at another author's open thesis; it needs its own child call
    /// and then sits in the same judged set, where the panel ranks argument against counter-argument.
    function testCounterThesisEntersTheJudgedSet() public {
        _fundCarol();
        uint32 w = hook.week();
        (bytes32 tid,) =
            _note(alice, _margNote(T.Side.Buy, 0, 0, "Privacy re-rates after the next exploit"), 10 ether);
        T.NoteParams memory rebuttal =
            _margNote(T.Side.Sell, 0, 0, "Privacy does not re-rate: every exploit so far was a bridge");
        rebuttal.parentId = tid;
        // the author cannot rebut themself
        vm.prank(alice);
        vm.expectRevert();
        router.note(rebuttal, key, 10 ether, 1, block.timestamp + 1);
        (bytes32 rid,) = _note(bob, rebuttal, 10 ether);
        assertEq(hook.noteOf(rid).parentId, tid);
        // not judged until it stakes a call of its own
        assertEq(judge.eligibleTheses(w).length, 0);
        T.NoteParams memory proof =
            _margNote(T.Side.Sell, 9000, 7, "MARG -10% in 7d: the exploit narrative fades");
        proof.parentId = rid;
        _note(bob, proof, 10 ether);
        bytes32[] memory judged = judge.eligibleTheses(w);
        assertEq(judged.length, 1);
        assertEq(judged[0], rid);
        // a rebuttal of a closed thesis is refused
        T.NoteParams memory late = _margNote(T.Side.Sell, 0, 0, "too late");
        late.parentId = rid; // rid is still ThesisOpen: fine for carol
        _note(carol, late, 10 ether);
        vm.warp(block.timestamp + hook.THESIS_GRACE() + 1);
        hook.settleThesis(tid); // alice's thesis had no child: forfeited
        T.NoteParams memory dead = _margNote(T.Side.Buy, 0, 0, "rebutting a corpse");
        dead.parentId = tid;
        vm.prank(carol);
        vm.expectRevert();
        router.note(dead, key, 10 ether, 1, block.timestamp + 1);
    }

    /// @dev A counter-call is the opposite side on the same token. No deposit changes hands: the loser's
    /// forfeit goes to the pot as always; the duel's outcome is the pair of settlements.
    function testCounterCallDuel() public {
        _buy(bob, 1_500_000 ether); // bob holds MARG at a high
        (bytes32 a,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "+10%"), 10 ether);
        T.NoteParams memory c = _margNote(T.Side.Sell, 9000, 1, "no: -10%, bob is about to sell");
        c.parentId = a;
        // same side as the target is not a counter
        T.NoteParams memory sameSide = _margNote(T.Side.Buy, 12_000, 1, "+20%");
        sameSide.parentId = a;
        vm.prank(bob);
        vm.expectRevert();
        router.note(sameSide, key, 10 ether, 1, block.timestamp + 1);
        (bytes32 b,) = _note(bob, c, 10 ether);
        assertEq(hook.noteOf(b).parentId, a);
        // a SELL baseline is the window minimum (the 1:1 checkpoint), so the dump must go below 90% of that
        token.transfer(bob, 3_000_000 ether);
        _sell(bob, token.balanceOf(bob)); // the dump: bob's SELL call is right, alice's BUY call is wrong
        assertLt(hook.margPriceInImd(), hook.noteOf(b).postPrice * 9 / 10);
        assertLt(hook.margPriceInImd(), hook.noteOf(a).postPrice * 9 / 10);
        vm.warp(hook.horizonEnd(a));
        uint256 startBlock = block.number;
        uint256 startTs = block.timestamp;
        for (uint256 i = 0; i < 3; ++i) {
            hook.observe(a);
            hook.observe(b);
            vm.roll(startBlock + 25 * (i + 1));
            vm.warp(startTs + 30 minutes * (i + 1));
        }
        vm.warp(hook.horizonEnd(a) + hook.SETTLE_WINDOW() + 1);
        hook.settle(b); // either order
        hook.settle(a);
        assertEq(uint8(hook.noteOf(a).status), uint8(T.Status.Wrong));
        assertEq(uint8(hook.noteOf(b).status), uint8(T.Status.Right));
        assertGt(_rec(bob).score, 0);
        assertLt(_rec(alice).score, 0);
        // a counter against a settled call is refused
        _fundCarol();
        T.NoteParams memory stale = _margNote(T.Side.Sell, 9000, 1, "late");
        stale.parentId = a;
        vm.prank(carol);
        vm.expectRevert();
        router.note(stale, key, 10 ether, 1, block.timestamp + 1);
    }

    // ---------------------------------------------------------------- sealed notes

    /// @dev The router rewrites a priced note's venue (quote, orientation) before the hook sees it, so the seal
    /// hashes the derived venue; the site does the same through router.validateVenue.
    function _seal(address who, T.NoteParams memory p) internal returns (bytes32 hash) {
        p.venue = router.validateVenue(p, key);
        hash = hook.sealHash(who, p);
        vm.prank(who);
        hook.seal(p.x, p.venue, hash);
    }

    /// @dev A sealed BUY call settles against the baseline priced at the seal, not at the reveal: holders who
    /// trade on it during the window cannot move the author's own target.
    function testSealedNoteRevealsAgainstTheSealBaseline() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 11_000, 1, "sealed: +10%, airdrop sells are done #7f3a");
        uint256 imdBefore = _claims(address(hook), address(imd));
        bytes32 hash = _seal(alice, p);
        assertEq(
            _claims(address(hook), address(imd)) - imdBefore, hook.STAMP(), "the seal pays one stamp up front"
        );
        (uint64 at, uint256 baseBuy,, uint256 balance,) = hook.seals(hook.sealKey(alice, hash));
        assertEq(at, block.timestamp);
        assertEq(balance, token.balanceOf(alice));
        // the public sees only the seal; a reveal before the head start is refused
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, key, 10 ether, 1, block.timestamp + 1);
        // the key holders trade on it: the live baseline moves well above the sealed one
        _buy(bob, 1_500_000 ether);
        router.checkpointVenue(p, key);
        vm.warp(block.timestamp + hook.SEAL_MIN());
        vm.roll(block.number + 150);
        assertGt(router.postPrice(p.venue, true), baseBuy);
        (bytes32 id,) = _note(alice, p, 10 ether);
        assertEq(hook.noteOf(id).postPrice, baseBuy, "priced at the seal");
        (at,,,,) = hook.seals(hook.sealKey(alice, hash));
        assertEq(at, 0, "a seal reveals once");
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Open));
    }

    /// @dev Position, then seal: a sealed BUY call whose author sold any of X between seal and reveal is refused.
    function testSealedBuyMustKeepItsPositionFromTheSeal() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 11_000, 1, "sealed: +10% #a1");
        _seal(alice, p);
        _sell(alice, token.balanceOf(alice) / 10);
        vm.warp(block.timestamp + hook.SEAL_MIN());
        router.checkpointVenue(p, key);
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, key, 10 ether, 1, block.timestamp + 1);
        // a sealed SELL call holds nothing, so it reveals regardless
        T.NoteParams memory q = _margNote(T.Side.Sell, 9000, 1, "sealed: -10% #b2");
        bytes32 hq = _seal(alice, q);
        (,, uint256 baseSell,,) = hook.seals(hook.sealKey(alice, hq));
        _sell(alice, token.balanceOf(alice) / 10);
        vm.warp(block.timestamp + hook.SEAL_MIN());
        (bytes32 id,) = _note(alice, q, 10 ether);
        assertEq(hook.noteOf(id).postPrice, baseSell);
    }

    /// @dev A seal that is never revealed keeps its stamp in the pools; past SEAL_MAX the note posts as an
    /// ordinary one at the live baseline, and the same text cannot be sealed twice while the seal is live.
    /// Launch audit finding d492eadc: posting the note spends the lapsed seal (it used to stay forever).
    function testUnrevealedSealIsNotAFreeOptionAndLapses() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 11_000, 1, "sealed: +10% #c3");
        bytes32 hash = _seal(alice, p);
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.InvalidNote.selector);
        hook.seal(p.x, p.venue, hash);
        uint256 imdAfterSeal = _claims(address(hook), address(imd));
        (, uint256 sealedBase,,,) = hook.seals(hook.sealKey(alice, hash));
        vm.warp(block.timestamp + hook.SEAL_MAX() + 1);
        _buy(bob, 1_500_000 ether); // the market moved after the seal lapsed
        router.checkpointVenue(p, key);
        vm.warp(block.timestamp + 1 hours);
        vm.roll(block.number + 300);
        uint256 live = router.postPrice(p.venue, true);
        (bytes32 id,) = _note(alice, p, 10 ether);
        assertApproxEqRel(hook.noteOf(id).postPrice, live, 0.001e18, "a lapsed seal does not price the note");
        assertGt(hook.noteOf(id).postPrice, sealedBase * 11 / 10);
        (uint64 at,,,,) = hook.seals(hook.sealKey(alice, hash));
        assertEq(at, 0, "the lapsed seal is spent by the note");
        assertGe(
            _claims(address(hook), address(imd)),
            imdAfterSeal + hook.STAMP(),
            "the reveal pays its own stamp as well"
        );
    }
}
