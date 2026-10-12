// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MarginaliaHook} from "src/MarginaliaHook.sol";
import {MarginaliaRouter} from "src/MarginaliaRouter.sol";
import {MarginaliaTypes as T} from "src/MarginaliaTypes.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Failure paths at the hook boundary, plus transactional rollback through the real manager.
contract HookBoundariesTest is Fixture {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    function setUp() public {
        _setup();
    }

    function _swapParams(bool buy, int256 amount) private view returns (SwapParams memory) {
        return SwapParams(buy ? !margIs0 : margIs0, amount, uint160(1 << 96));
    }

    function _call() private view returns (T.NoteParams memory) {
        return _margNote(T.Side.Buy, 11_000, 1, "a falsifiable call");
    }

    /// @dev Check the nested hook error, not merely that some unrelated router precondition failed.
    function _rejectNote(T.NoteParams memory p, bytes4 reason) private {
        uint256 beforeImd = imd.balanceOf(alice);
        uint256 beforeMarg = token.balanceOf(alice);
        uint256 beforeClaims = _claims(address(hook), address(imd));
        uint256 beforeCount = hook.noteCount();
        uint256 beforePool = hook.thesisPool(hook.week()) + hook.refundPool(hook.today());
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterSwap.selector,
                abi.encodeWithSelector(reason),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        router.note(p, key, 0.6 ether, 1, vm.getBlockTimestamp());
        assertEq(imd.balanceOf(alice), beforeImd, "failed post spent IMD");
        assertEq(token.balanceOf(alice), beforeMarg, "failed post delivered MARG");
        assertEq(_claims(address(hook), address(imd)), beforeClaims, "failed post minted claims");
        assertEq(hook.noteCount(), beforeCount, "failed post consumed an id");
        assertEq(hook.thesisPool(hook.week()) + hook.refundPool(hook.today()), beforePool);
        assertEq(imd.balanceOf(address(router)), 0);
    }

    function testEveryEnabledCallbackRejectsAStranger() public {
        SwapParams memory p = _swapParams(true, -1 ether);
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.beforeInitialize(address(this), key, uint160(1 << 96));
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.beforeSwap(address(router), key, p, "");
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.afterSwap(address(router), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.unlockCallback(abi.encode(uint8(1), alice, 1 ether, uint256(uint160(address(imd)))));
    }

    function testManagerCannotInventAnUnlockOutsideAnActiveOperation() public {
        vm.prank(address(manager));
        vm.expectRevert(MarginaliaHook.InvalidUnlock.selector);
        hook.unlockCallback(abi.encode(uint8(1), alice, 1 ether, uint256(uint160(address(imd)))));
    }

    function testForeignPoolRejectedByBothSwapCallbacks() public {
        PoolKey memory foreign = key;
        foreign.tickSpacing = 120;
        SwapParams memory p = _swapParams(true, -1 ether);
        vm.startPrank(address(manager));
        vm.expectRevert(MarginaliaHook.InvalidPool.selector);
        hook.beforeSwap(alice, foreign, p, "");
        vm.expectRevert(MarginaliaHook.InvalidPool.selector);
        hook.afterSwap(alice, foreign, p, BalanceDelta.wrap(0), "");
        vm.stopPrank();
    }

    function testFactoryCannotBindASecondPool() public {
        PoolKey memory second = key;
        second.tickSpacing = 120;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(MarginaliaHook.InvalidPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(second, uint160(1 << 96));
        assertEq(keccak256(abi.encode(hook.getPoolKey())), keccak256(abi.encode(key)));
    }

    function testForgedNoteAndExemptionAreRejected() public {
        SwapParams memory p = _swapParams(false, -1 ether);
        vm.startPrank(address(manager));
        vm.expectRevert(MarginaliaHook.BadHookData.selector);
        hook.beforeSwap(alice, key, p, abi.encode(uint8(1)));
        vm.expectRevert(MarginaliaHook.BadHookData.selector);
        hook.beforeSwap(address(router), key, p, abi.encode(uint8(2)));
        vm.expectRevert(MarginaliaHook.BadHookData.selector);
        hook.beforeSwap(address(router), key, p, abi.encode(uint8(3)));
        vm.expectRevert(MarginaliaHook.BadHookData.selector);
        hook.beforeSwap(address(router), key, p, abi.encode(uint8(255)));
        vm.stopPrank();
    }

    function testExactOutputQuietSellsAndNotedTradesAreRejected() public {
        SwapParams memory sell = _swapParams(false, 1 ether);
        SwapParams memory buy = _swapParams(true, 1 ether);
        vm.startPrank(address(manager));
        vm.expectRevert(MarginaliaHook.NoteNeedsExactInput.selector);
        hook.beforeSwap(alice, key, sell, "");
        vm.expectRevert(MarginaliaHook.NoteNeedsExactInput.selector);
        hook.beforeSwap(address(router), key, sell, abi.encode(uint8(1)));
        vm.expectRevert(MarginaliaHook.NoteNeedsExactInput.selector);
        hook.beforeSwap(address(router), key, buy, abi.encode(uint8(1)));
        vm.stopPrank();
    }

    function testExactOutputPlainBuyHasNoHookDelta() public {
        SwapParams memory p = _swapParams(true, 1 ether);
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(alice, key, p, "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(delta.getSpecifiedDelta(), 0);
        assertEq(delta.getUnspecifiedDelta(), 0);
        assertEq(fee, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzNotedInputLeavesExactlyQuarterImdForThePool(uint256 bond) public {
        bond = bound(bond, 0.25 ether, 10 ether);
        SwapParams memory p = _swapParams(true, -int256(bond + 0.35 ether));
        vm.prank(address(manager));
        (, BeforeSwapDelta d,) = hook.beforeSwap(address(router), key, p, abi.encode(uint8(1)));
        assertEq(uint256(uint128(d.getSpecifiedDelta())), bond + 0.1 ether);
        assertEq(d.getUnspecifiedDelta(), 0);
        assertEq(uint256(-p.amountSpecified) - uint256(uint128(d.getSpecifiedDelta())), 0.25 ether);
    }

    function testAfterSwapRejectsZeroOrWrongSignedOutput() public {
        SwapParams memory buy = _swapParams(true, -1 ether);
        SwapParams memory sell = _swapParams(false, -1 ether);
        BalanceDelta wrongBuy = toBalanceDelta(1, 1);
        BalanceDelta wrongSell = toBalanceDelta(-1, -1);
        vm.startPrank(address(manager));
        vm.expectRevert(MarginaliaHook.PartialFill.selector);
        hook.afterSwap(alice, key, buy, wrongBuy, "");
        vm.expectRevert(MarginaliaHook.PartialFill.selector);
        hook.afterSwap(alice, key, sell, wrongSell, "");
        vm.expectRevert(MarginaliaHook.PartialFill.selector);
        hook.afterSwap(alice, key, sell, BalanceDelta.wrap(0), "");
        vm.stopPrank();
    }

    function testEmptyCallAndThesisTextAreRejectedAtomically() public {
        T.NoteParams memory p = _call();
        p.text = "";
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
        p.targetBps = 0;
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
    }

    function testTextLimitIsInclusiveForBothForms() public {
        T.NoteParams memory p = _call();
        p.text = string(new bytes(281));
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
        p.text = string(new bytes(280));
        _note(alice, p, 0.6 ether);
        p.targetBps = 0;
        p.text = string(new bytes(8193));
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
        p.text = string(new bytes(8192));
        _note(alice, p, 0.6 ether);
        assertEq(hook.noteCount(), 2);
    }

    function testHorizonEdgesAndTargetEdges() public {
        T.NoteParams memory p = _call();
        p.horizonDays = 0;
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
        p.horizonDays = 91;
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
        p.horizonDays = 90;
        p.targetBps = 10_999;
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
        p.targetBps = 11_000;
        (bytes32 buy,) = _note(alice, p, 0.6 ether);
        assertEq(hook.horizonEnd(buy), vm.getBlockTimestamp() + 90 days);
        p.side = T.Side.Sell;
        p.targetBps = 9001;
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
        p.targetBps = 9000;
        _note(alice, p, 0.6 ether);
    }

    function testMissingParentAndSameSideCounterAreRejectedAtomically() public {
        T.NoteParams memory p = _call();
        p.parentId = keccak256("unknown parent");
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
        p.parentId = bytes32(0);
        (bytes32 id,) = _note(bob, p, 0.6 ether);
        p.parentId = id;
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
        p.side = T.Side.Sell;
        p.targetBps = 9000;
        (bytes32 counter,) = _note(alice, p, 0.6 ether);
        assertEq(hook.noteOf(counter).parentId, id);
        assertEq(hook.noteOf(id).deposit, 0.25 ether, "counter moved the parent's bond");
    }

    function testCallCannotBeAChildOfItsOwnCallOrAClosedThesis() public {
        T.NoteParams memory p = _call();
        (bytes32 callId,) = _note(alice, p, 0.6 ether);
        p.parentId = callId;
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
        p.parentId = 0;
        p.targetBps = 0;
        (bytes32 thesis,) = _note(alice, p, 0.6 ether);
        p.targetBps = 11_000;
        p.parentId = thesis;
        (bytes32 child,) = _note(alice, p, 0.6 ether);
        vm.prank(alice);
        hook.retract(child, "withdrawn");
        _rejectNote(p, MarginaliaHook.InvalidNote.selector);
    }

    function testUnknownNotesFailEveryLifecycleEntry() public {
        bytes32 id = keccak256("never posted");
        vm.expectRevert(MarginaliaHook.UnknownNote.selector);
        hook.observe(id);
        vm.expectRevert(MarginaliaHook.UnknownNote.selector);
        hook.settle(id);
        vm.expectRevert(MarginaliaHook.UnknownNote.selector);
        hook.settleThesis(id);
        vm.expectRevert(MarginaliaHook.UnknownNote.selector);
        hook.claimDeposit(id);
        vm.expectRevert(MarginaliaHook.UnknownNote.selector);
        hook.claimRefund(id);
        vm.expectRevert(MarginaliaHook.UnknownNote.selector);
        hook.retract(id, "unknown");
    }

    function testObservationAndSettlementWindowExactEdges() public {
        (bytes32 id,) = _note(alice, _call(), 0.6 ether);
        uint256 end = hook.horizonEnd(id);
        vm.warp(end - 1);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.observe(id);
        vm.warp(end);
        hook.observe(id);
        vm.warp(end + 1 hours);
        vm.roll(vm.getBlockNumber() + 20);
        hook.observe(id);
        vm.warp(end + 6 hours);
        vm.roll(vm.getBlockNumber() + 20);
        hook.observe(id);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.settle(id);
        vm.warp(end + 6 hours + 1);
        vm.expectRevert(MarginaliaHook.TooLate.selector);
        hook.observe(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
        vm.expectRevert(MarginaliaHook.NotOpen.selector);
        hook.settle(id);
        vm.expectRevert(MarginaliaHook.NotOpen.selector);
        hook.observe(id);
    }

    function testRetractAtHorizonIsTooLateAndBeforeItIsFinal() public {
        (bytes32 id,) = _note(alice, _call(), 0.6 ether);
        (bytes32 second,) = _note(alice, _call(), 0.6 ether);
        uint256 end = hook.horizonEnd(id);
        vm.warp(end - 1);
        vm.prank(alice);
        hook.retract(id, "last second");
        vm.warp(end);
        vm.startPrank(alice);
        vm.expectRevert(MarginaliaHook.TooLate.selector);
        hook.retract(second, "too late");
        vm.expectRevert(MarginaliaHook.NotOpen.selector);
        hook.retract(id, "again");
        vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
        hook.claimDeposit(id);
        vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
        hook.claimRefund(id);
        vm.stopPrank();
    }

    function testNoDataBondCannotBeStolenOrClaimedTwice() public {
        (bytes32 id,) = _note(alice, _call(), 10.35 ether);
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
        hook.claimDeposit(id);
        vm.warp(hook.horizonEnd(id) + 6 hours + 1);
        hook.settle(id);
        vm.prank(bob);
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.claimDeposit(id);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        hook.claimDeposit(id);
        assertEq(imd.balanceOf(alice) - before, 10 ether);
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
        hook.claimDeposit(id);
    }

    function testChildlessThesisForfeitureBoundaryAndKeeperPayment() public {
        T.NoteParams memory p = _call();
        p.targetBps = 0;
        (bytes32 id,) = _note(alice, p, 10.35 ether);
        uint256 graceEnd = vm.getBlockTimestamp() + 7 days;
        vm.warp(graceEnd);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.settleThesis(id);
        vm.warp(graceEnd + 1);
        uint256 before = imd.balanceOf(carol);
        vm.prank(carol);
        hook.settleThesis(id);
        assertEq(imd.balanceOf(carol) - before, 1 ether);
        assertEq(hook.noteOf(id).deposit, 0);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.ThesisForfeited));
        vm.expectRevert(MarginaliaHook.NotOpen.selector);
        hook.settleThesis(id);
    }

    function testChildAtTheSevenDayDeadlineCanReleaseTheThesis() public {
        T.NoteParams memory p = _call();
        p.targetBps = 0;
        (bytes32 parent,) = _note(alice, p, 10.35 ether);
        uint256 deadline = vm.getBlockTimestamp() + 7 days;
        p.targetBps = 11_000;
        p.parentId = parent;
        vm.warp(deadline - 1 hours);
        vm.roll(vm.getBlockNumber() + 50_000);
        router.checkpointVenue(p, key);
        vm.warp(deadline);
        vm.roll(vm.getBlockNumber() + 300);
        (bytes32 child,) = _note(alice, p, 0.6 ether);
        vm.prank(alice);
        hook.retract(child, "withdraw the timely child");
        assertEq(uint8(hook.noteOf(parent).status), uint8(T.Status.ThesisClosed));
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        hook.claimDeposit(parent);
        assertEq(imd.balanceOf(alice) - before, 10 ether);
    }

    function testSealRejectsZeroHashAndDuplicateWithoutTakingAnotherStamp() public {
        T.NoteParams memory p = _call();
        p.venue = router.validateVenue(p, key);
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.InvalidNote.selector);
        hook.seal(p.x, p.venue, bytes32(0));
        bytes32 hash = hook.sealHash(alice, p);
        vm.prank(alice);
        hook.seal(p.x, p.venue, hash);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.InvalidNote.selector);
        hook.seal(p.x, p.venue, hash);
        assertEq(imd.balanceOf(alice), before);
        assertEq(_claims(address(hook), address(imd)), 0.1 ether);
    }

    function testSealMinimumAgeIsInclusiveAndFailedRevealPreservesCommitment() public {
        T.NoteParams memory p = _call();
        p.venue = router.validateVenue(p, key);
        bytes32 hash = hook.sealHash(alice, p);
        bytes32 sealId = hook.sealKey(alice, hash);
        vm.prank(alice);
        hook.seal(p.x, p.venue, hash);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 30 minutes - 1);
        _rejectNote(p, MarginaliaHook.TooEarly.selector);
        (uint64 at,,,,) = hook.seals(sealId);
        assertEq(at, start);
        vm.warp(start + 30 minutes);
        _note(alice, p, 0.6 ether);
        (at,,,,) = hook.seals(sealId);
        assertEq(at, 0);
        assertEq(_claims(address(hook), address(imd)), 0.45 ether, "two stamps plus one bond");
    }

    function testSealMaximumAgeUsesSealedPriceDespiteExpiredPostingCheckpoint() public {
        T.NoteParams memory p = _call();
        p.venue = router.validateVenue(p, key);
        bytes32 hash = hook.sealHash(alice, p);
        bytes32 sealId = hook.sealKey(alice, hash);
        vm.prank(alice);
        hook.seal(p.x, p.venue, hash);
        (uint64 at, uint256 baseline,,,) = hook.seals(sealId);
        _buy(bob, 1_000_000 ether);
        vm.warp(uint256(at) + 6 hours);
        vm.roll(vm.getBlockNumber() + 1800);
        (bytes32 id,) = _note(alice, p, 0.6 ether);
        assertEq(hook.noteOf(id).postPrice, baseline);
        assertGt(hook.margPriceInImd(), baseline);
        (at,,,,) = hook.seals(sealId);
        assertEq(at, 0);
    }

    function testRefundRequiresNextDayAuthorAndSingleUse() public {
        (bytes32 id,) = _note(alice, _call(), 0.6 ether);
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.claimRefund(id);
        vm.warp((uint256(hook.today()) + 1) * 1 days);
        vm.prank(bob);
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.claimRefund(id);
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        hook.claimRefund(id);
        assertEq(imd.balanceOf(alice) - before, 0.03 ether);
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.NothingToClaim.selector);
        hook.claimRefund(id);
    }

    function testSweepBoundaryMovesClaimsWithoutWithdrawingThem() public {
        vm.prank(alice);
        hook.fundPot(10 ether);
        uint32 day = hook.today();
        uint256 claims = _claims(address(hook), address(imd));
        uint256 deadline = (uint256(day) + 1) * 1 days + 28 days;
        vm.warp(deadline - 1);
        vm.expectRevert(MarginaliaHook.TooEarly.selector);
        hook.sweep(0, day);
        vm.warp(deadline);
        hook.sweep(0, day);
        assertEq(hook.refundPool(day), 0);
        assertEq(hook.thesisPool(hook.week()), 3 ether);
        assertEq(_claims(address(hook), address(imd)), claims);
        vm.expectRevert(MarginaliaHook.NothingToSweep.selector);
        hook.sweep(0, day);
    }

    function testOnlyJudgeCanDrawOrPayAndZeroFundingIsRefused() public {
        bytes32[3] memory top;
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.drawForJudging(0, 1 ether, true);
        vm.expectRevert(MarginaliaHook.Unauthorized.selector);
        hook.payJudged(0, top);
        vm.expectRevert(MarginaliaHook.PotTooSmall.selector);
        hook.fundPot(0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzBondRoundTripReturnsOnlyTheBond(uint256 bond) public {
        bond = bound(bond, 0.25 ether, 10 ether);
        uint256 before = imd.balanceOf(alice);
        (bytes32 id,) = _note(alice, _call(), bond + 0.35 ether);
        assertEq(hook.noteOf(id).deposit, bond);
        vm.warp(hook.horizonEnd(id) + 6 hours + 1);
        hook.settle(id);
        vm.prank(alice);
        hook.claimDeposit(id);
        assertEq(before - imd.balanceOf(alice), 0.35 ether, "stamp or MARG purchase was refunded");
        assertEq(_claims(address(hook), address(imd)), 0.1 ether);
    }
}
