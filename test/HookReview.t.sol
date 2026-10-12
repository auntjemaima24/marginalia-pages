// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, LiquidityHelper, MockIntake} from "./helpers/Fixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @dev A constant 1:1 accumulator venue with the canonical factory interface checks.
contract ReviewAccumulatorPool {
    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 3000;
    uint128 public constant liquidity = 1 ether;

    constructor(address x, address quote) {
        token0 = x;
        token1 = quote;
    }

    function observe(uint32[] calldata) external pure returns (int56[] memory c, uint160[] memory l) {
        c = new int56[](1);
        l = new uint160[](1);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (100 ether, 100 ether, uint32(block.timestamp));
    }

    function price0CumulativeLast() external view returns (uint256) {
        return block.timestamp << 112;
    }

    function price1CumulativeLast() external view returns (uint256) {
        return block.timestamp << 112;
    }
}

contract HookReviewTest is Fixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _setup();
    }

    function _warm(T.NoteParams memory p, PoolKey memory k) private {
        router.checkpointVenue(p, k);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
    }

    // 7ee86ab4: a keeper does not have to win a race against an overdue first child.
    function testLateChildCannotRescueThesis() public {
        (bytes32 tid,) = _note(alice, _margNote(T.Side.Buy, 0, 0, "thesis"), 2.35 ether);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        T.NoteParams memory child = _margNote(T.Side.Buy, 11_000, 1, "late child");
        child.parentId = tid;
        _warm(child, key);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        router.note(child, key, 0.6 ether, 1, vm.getBlockTimestamp() + 1);
        assertEq(imd.balanceOf(alice), before, "refusal is atomic");
        vm.prank(carol);
        hook.settleThesis(tid);
        assertEq(uint8(hook.noteOf(tid).status), uint8(T.Status.ThesisForfeited));
        assertEq(hook.noteOf(tid).deposit, 0);
        assertEq(imd.balanceOf(carol), 0.2 ether);
        assertEq(hook.thesisPool(hook.week()), 1.26 ether);
        assertEq(hook.refundPool(hook.today()), 0.54 ether);
    }

    function testChildAtExactlyGraceDeadlineReleasesThesis() public {
        uint256 deadline = vm.getBlockTimestamp() + hook.THESIS_GRACE();
        (bytes32 tid,) = _note(alice, _margNote(T.Side.Buy, 0, 0, "thesis"), 2.35 ether);
        T.NoteParams memory child = _margNote(T.Side.Buy, 11_000, 1, "on time");
        child.parentId = tid;
        vm.warp(deadline - 1 hours);
        _warm(child, key);
        assertEq(vm.getBlockTimestamp(), deadline);
        (bytes32 cid,) = _note(alice, child, 0.6 ether);
        vm.prank(alice);
        hook.retract(cid, "resolved child");
        assertEq(uint8(hook.noteOf(tid).status), uint8(T.Status.ThesisClosed));
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        hook.claimDeposit(tid);
        assertEq(imd.balanceOf(alice) - before, 2 ether);
    }

    // 27af4563: replacements cannot continually postpone the next append.
    function testDustReplacementsCannotMonopolizeObservationWindow() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 15_000, 1, "wrong call"), 10 ether);
        uint256 bond = hook.noteOf(id).deposit;
        uint256 end = hook.horizonEnd(id);
        vm.warp(end);
        hook.observe(id);
        uint256 appended;
        for (uint256 i; i < 94; ++i) {
            vm.roll(vm.getBlockNumber() + 19);
            vm.warp(vm.getBlockTimestamp() + 228);
            vm.prank(carol);
            try hook.observe(id) {
                ++appended;
            } catch {}
            _sell(bob, 1e9);
            vm.prank(bob);
            hook.observe(id);
        }
        assertGe(appended, 2, "honest observations can still append");
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        vm.prank(carol);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
        assertEq(hook.noteOf(id).deposit, 0);
        assertEq(imd.balanceOf(carol), bond / 10);
    }

    function testReplacementDoesNotRestartTwentyBlockGap() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "gap"), 1 ether);
        vm.warp(hook.horizonEnd(id));
        uint256 firstBlock = vm.getBlockNumber();
        hook.observe(id);
        vm.roll(firstBlock + 19);
        vm.warp(vm.getBlockTimestamp() + 19 * 12);
        _sell(bob, 1e9);
        hook.observe(id);
        vm.expectRevert(MarginaliaHook.ObservationTooSoon.selector);
        hook.observe(id); // an equal reading still cannot replace
        vm.roll(firstBlock + 20);
        hook.observe(id); // append at 20 from the push, just 1 from replacement
    }

    function testReplacementCannotLeaveAFullSeriesShortOfOneHour() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "span after replacement"), 1 ether);
        uint256 end = hook.horizonEnd(id);
        uint256 firstBlock = vm.getBlockNumber();
        vm.warp(end);
        hook.observe(id);
        vm.roll(firstBlock + 19);
        vm.warp(end + 228);
        _sell(bob, 1e9);
        hook.observe(id); // first reading now has timestamp end + 228, but its slot still opened at firstBlock
        for (uint256 i = 1; i < hook.OBS_MAX(); ++i) {
            vm.roll(firstBlock + i * 20);
            vm.warp(end + i * 240);
            try hook.observe(id) {} catch {}
        }
        // Do not fill the final slot before the actual readings span an hour. Otherwise the next equal
        // honest reading is refused forever at the cap and the losing author gets a no-data refund.
        vm.roll(firstBlock + 320);
        vm.warp(end + 228 + 1 hours);
        hook.observe(id);
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
    }

    // 5acec328: the global 120-entry limit cannot all be occupied by one author.
    function testOneAuthorCannotFillTheWeeklyThesisSet() public {
        uint32 w = hook.week();
        T.NoteParams memory p = _margNote(T.Side.Buy, 0, 0, "thesis");
        uint256 accepted;
        for (uint256 i; i < 120; ++i) {
            vm.prank(bob);
            try router.note(p, key, 0.6 ether, 1, vm.getBlockTimestamp() + 1) {
                ++accepted;
            } catch {}
        }
        assertEq(accepted, 3, "one author gets at most the size of the judged head");
        assertEq(hook.thesesOfWeek(w).length, 3);
        _note(alice, p, 0.6 ether);
        assertEq(hook.thesesOfWeek(w).length, 4, "another author can enter");
        vm.warp((uint256(w) + 1) * 7 days);
        _note(bob, p, 0.6 ether);
        assertEq(hook.thesesOfWeek(w + 1).length, 1, "the author allowance resets each week");
    }

    // c6e68a4f: the allow-list must not freeze during a late thesis's child grace.
    function testJudgingWaitsForEveryThesisChildGrace() public {
        uint32 w = hook.week();
        uint256 weekEnd = (uint256(w) + 1) * 7 days;
        (bytes32 early,) = _note(bob, _margNote(T.Side.Buy, 0, 0, "early"), 1 ether);
        T.NoteParams memory child = _margNote(T.Side.Buy, 11_000, 1, "child");
        child.parentId = early;
        _note(bob, child, 1 ether);
        vm.prank(alice);
        hook.fundPot(20 ether);
        vm.warp(weekEnd - 1 hours);
        (bytes32 late,) = _note(alice, _margNote(T.Side.Buy, 0, 0, "late"), 1 ether);
        vm.warp(weekEnd + 1);
        uint256 poolBefore = hook.thesisPool(w);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        judge.requestJudging(w);
        assertEq(hook.thesisPool(w), poolBefore);
        assertEq(judge.requestOf(w), bytes32(0));
        assertEq(MockIntake(hook.INTAKE()).requests(), 0);
        vm.warp(weekEnd + 2 days);
        child.parentId = late;
        _warm(child, key);
        _note(alice, child, 1 ether);
        bytes32[] memory eligible = judge.eligibleTheses(w);
        assertEq(eligible.length, 2);
        assertEq(eligible[0], early);
        assertEq(eligible[1], late);
        vm.warp(weekEnd + hook.THESIS_GRACE() - 1);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        judge.requestJudging(w);
        vm.warp(vm.getBlockTimestamp() + 1);
        judge.requestJudging(w);
        assertEq(MockIntake(hook.INTAKE()).lastBody(), bytes(judge.questionBody(w)));
        assertEq(hook.thesisPool(w), poolBefore - 0.5 ether);
    }

    /// @dev Price-series tests control actual StateLibrary slots. The live pricer/router math is used,
    /// without mocking a price result or changing the immutable implementation code.
    function _setPoolState(bytes32 id, uint160 sqrtP) private {
        bytes32 slot = keccak256(abi.encode(id, uint256(6)));
        vm.store(address(manager), slot, bytes32(uint256(sqrtP)));
        vm.store(address(manager), bytes32(uint256(slot) + 3), bytes32(uint256(1 ether)));
    }

    function _nativeVenue(address x) private returns (PoolKey memory k) {
        vm.chainId(1);
        k = PoolKey(Currency.wrap(address(0)), Currency.wrap(x), 3000, 60, IHooks(address(0)));
        manager.initialize(k, uint160(1 << 96));
        _setPoolState(PoolId.unwrap(k.toId()), uint160(1 << 96));
        _setPoolState(hook.pricer().HUB_POOL_ID(), uint160(1 << 96));
    }

    // 6bbdcb1e: IMD-in-IMD is not a falsifiable >=10% call, including through the hub.
    function _identityRefused(T.Side side) private {
        PoolKey memory k = _nativeVenue(address(imd));
        T.NoteParams memory p = _margNote(side, side == T.Side.Buy ? 11_000 : 9000, 1, "identity");
        p.x = address(imd);
        p.venue.ref = PoolId.unwrap(k.toId());
        _warm(p, k);
        p.venue = router.validateVenue(p, k);
        assertEq(router.postPrice(p.venue, side == T.Side.Buy), 1 ether);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        router.note(p, k, 1 ether, 1, vm.getBlockTimestamp() + 1);
        assertEq(imd.balanceOf(alice), before);
        assertEq(hook.noteCount(), 0);
    }

    function testBuyCallOnImdRefusedBeforeTakingBond() public {
        _identityRefused(T.Side.Buy);
    }

    function testSellCallOnImdRefusedBeforeTakingBond() public {
        _identityRefused(T.Side.Sell);
    }

    function testSealOnImdRefusedBeforeTakingStamp() public {
        PoolKey memory k = _nativeVenue(address(imd));
        T.NoteParams memory p = _margNote(T.Side.Buy, 11_000, 1, "identity seal");
        p.x = address(imd);
        p.venue.ref = PoolId.unwrap(k.toId());
        _warm(p, k);
        p.venue = router.validateVenue(p, k);
        bytes32 hash = hook.sealHash(alice, p);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.InvalidNote.selector);
        hook.seal(p.x, p.venue, hash);
        assertEq(imd.balanceOf(alice), before);
    }

    // 5869aec9: paired readings all equal 4, independent component extremes equal 1 / 16.
    function _pairedSettlement(T.Side side) private {
        MockERC20 x = new MockERC20("X", "X", 1e27);
        PoolKey memory k = _nativeVenue(address(x));
        bytes32 hub = hook.pricer().HUB_POOL_ID();
        bool buy = side == T.Side.Buy;
        if (!buy) _setPoolState(hub, uint160(4 << 96));
        T.NoteParams memory p = _margNote(side, buy ? 20_000 : 5000, 1, "opposing leg moves");
        p.x = address(x);
        p.venue.ref = PoolId.unwrap(k.toId());
        _warm(p, k);
        vm.prank(alice);
        router.note(p, k, 1 ether, 1, vm.getBlockTimestamp() + 1);
        bytes32 id = bytes32(hook.noteCount());
        assertEq(hook.noteOf(id).postPrice, buy ? 1 ether : 16 ether);
        uint256 end = hook.horizonEnd(id);
        for (uint256 i; i < 3; ++i) {
            vm.warp(end + i * 31 minutes);
            vm.roll(vm.getBlockNumber() + 155);
            // native is token0, X is token1: sqrt=2 means 0.25 ETH per X.
            _setPoolState(PoolId.unwrap(k.toId()), uint160(i == 1 ? 2 : 1) << 96);
            _setPoolState(hub, uint160(i == 1 ? 4 : 2) << 96);
            hook.observe(id);
        }
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Right), "all actual prices meet the target");
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        hook.claimDeposit(id);
        assertEq(imd.balanceOf(alice) - before, 0.65 ether);
    }

    function testBuySettlementUsesSameObservationForBothLegs() public {
        _pairedSettlement(T.Side.Buy);
    }

    function testSellSettlementUsesSameObservationForBothLegs() public {
        _pairedSettlement(T.Side.Sell);
    }

    // 607bc1b0: aliases still exist in the immutable router but cannot be posted or sealed.
    function _aliasedVenue(T.VenueKind kind, bool sealing) private {
        ReviewAccumulatorPool v = new ReviewAccumulatorPool(address(token), address(imd));
        if (kind == T.VenueKind.UniV3) {
            vm.mockCall(
                router.UNIV3_FACTORY(),
                abi.encodeWithSignature(
                    "getPool(address,address,uint24)", address(token), address(imd), uint24(3000)
                ),
                abi.encode(address(v))
            );
        } else {
            vm.mockCall(
                router.UNIV2_FACTORY(),
                abi.encodeWithSignature("getPair(address,address)", address(token), address(imd)),
                abi.encode(address(v))
            );
        }
        T.NoteParams memory p = _margNote(T.Side.Buy, 11_000, 1, "aliased accumulator");
        p.venue = T.Venue(kind, bytes32(uint256(uint160(address(v)))), address(imd), true);
        uint256 started = vm.getBlockTimestamp();
        router.checkpointVenue(p, key);
        vm.warp(started + 2 hours);
        router.checkpointVenue(p, key);
        (uint64 canonicalStart,,,,,,) = router.priceWindows(keccak256(abi.encode(p.venue)));
        assertEq(canonicalStart, started);
        p.venue.ref |= bytes32(uint256(1) << 200);
        _warm(p, key);
        (uint64 aliasStart,,,,,,) = router.priceWindows(keccak256(abi.encode(p.venue)));
        assertEq(aliasStart, started + 2 hours, "the live router admits an independent alias window");
        bytes32 hash = hook.sealHash(alice, p);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        if (sealing) hook.seal(p.x, p.venue, hash);
        else router.note(p, key, 1 ether, 1, vm.getBlockTimestamp() + 1);
        assertEq(imd.balanceOf(alice), before);
        // The same pool's canonical address encoding remains usable.
        p.venue.ref = bytes32(uint256(uint160(address(v))));
        (bytes32 id,) = _note(alice, p, 1 ether);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Open));
        uint256 end = hook.horizonEnd(id);
        for (uint256 i; i < 3; ++i) {
            vm.warp(end + i * 31 minutes);
            vm.roll(vm.getBlockNumber() + 155);
            hook.observe(id);
        }
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong), "canonical accumulator still settles");
    }

    function testV3AliasPostRefused() public {
        _aliasedVenue(T.VenueKind.UniV3, false);
    }

    function testV2AliasPostRefused() public {
        _aliasedVenue(T.VenueKind.UniV2, false);
    }

    function testV3AliasSealRefused() public {
        _aliasedVenue(T.VenueKind.UniV3, true);
    }

    function testV2AliasSealRefused() public {
        _aliasedVenue(T.VenueKind.UniV2, true);
    }

    // 0def2ef9: retain the requested adverse-extreme rule, document its actual limit.
    function testOneHostileReadingRemainsAdverseAfterPriceRecovers() public {
        (bytes32 id,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "up"), 1 ether);
        _buy(bob, 1_300_000 ether);
        uint256 end = hook.horizonEnd(id);
        vm.warp(end);
        hook.observe(id);
        token.transfer(carol, 3_000_000 ether);
        vm.startPrank(carol);
        token.approve(address(plain), type(uint256).max);
        imd.approve(address(plain), type(uint256).max);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 1);
        uint256 proceeds = _sell(carol, 3_000_000 ether);
        hook.observe(id);
        _buy(carol, proceeds);
        assertGt(hook.margPriceInImd(), 1.1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(MarginaliaHook.ObservationTooSoon.selector);
        hook.observe(id);
        for (uint256 i = 1; i < 3; ++i) {
            vm.warp(end + i * 31 minutes);
            vm.roll(vm.getBlockNumber() + 155);
            hook.observe(id);
        }
        uint256 before = imd.balanceOf(carol);
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
        vm.prank(carol);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
        assertEq(imd.balanceOf(carol) - before, 0.065 ether);
    }

    // 2d57f26d: liquidity exits are outside the explicitly requested swap fee callbacks.
    function testSingleSidedLiquidityExitPaysNoHookSwapFee() public {
        LiquidityHelper lp = new LiquidityHelper(manager);
        token.transfer(address(lp), 100_000 ether);
        int24 lower = margIs0 ? int24(60) : int24(-120);
        int24 upper = margIs0 ? int24(120) : int24(-60);
        lp.add(key, lower, upper, 1e24);
        uint256 margLeft = token.balanceOf(address(lp));
        uint256 claims = _claims(address(hook), address(imd));
        _buy(bob, 200_000 ether);
        lp.add(key, lower, upper, -1e24);
        assertEq(token.balanceOf(address(lp)), margLeft);
        assertGt(imd.balanceOf(address(lp)), 0);
        assertEq(_claims(address(hook), address(imd)), claims);
    }
}
