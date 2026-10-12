// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MarginaliaHook} from "../src/MarginaliaHook.sol";
import {MarginaliaTypes as T} from "../src/MarginaliaTypes.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @dev A token whose deployer can make totalSupply revert (finding 43fe5339); balanceOf is unaffected.
contract SupplySwitchToken is ERC20 {
    bool public bricked;

    constructor() ERC20("Brick", "BRK") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function setBrick(bool b) external {
        bricked = b;
    }

    function totalSupply() public view override returns (uint256) {
        require(!bricked, "supply unavailable");
        return super.totalSupply();
    }
}

/// @title Regressions for the audit of the code as it arrived for the hook launch.
contract LaunchAuditFindingsTest is Fixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _setup();
        vm.prank(bob);
        imd.approve(address(hook), type(uint256).max);
    }

    function _observeThree(bytes32 id) internal {
        uint256 end = hook.horizonEnd(id);
        vm.warp(end);
        hook.observe(id);
        vm.warp(end + 30 minutes);
        vm.roll(vm.getBlockNumber() + 150);
        hook.observe(id);
        vm.warp(end + 61 minutes);
        vm.roll(vm.getBlockNumber() + 155);
        hook.observe(id);
        vm.warp(end + hook.SETTLE_WINDOW() + 1);
    }

    /// @dev A hookless Y/IMD v4 pool at 4 IMD per Y (or 1/4, by sort order), checkpointed and mature.
    function _otherVenue() internal returns (address y, T.Venue memory venue) {
        MockERC20 yt = new MockERC20("Y", "Y", 1e27);
        y = address(yt);
        bool y0 = y < address(imd);
        (address c0, address c1) = y0 ? (y, address(imd)) : (address(imd), y);
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        manager.initialize(k, uint160(2 << 96));
        yt.transfer(address(liquidity), 1000 ether);
        imd.transfer(address(liquidity), 1000 ether);
        liquidity.add(k, -887_220, 887_220, 1e18);
        T.NoteParams memory q = _margNote(T.Side.Buy, 11_000, 1, "venue");
        q.x = y;
        q.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(k.toId()), address(0), false);
        venue = router.validateVenue(q, k);
        router.checkpointVenue(q, k);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
    }

    // ---------------------------------------------------------------- f31a482c: a seal binds its sealer, X and venue

    /// @dev A stranger front-runs the author's hash with a seal on another venue: the author's note is neither
    /// blocked (TooEarly) nor priced on the stranger's venue.
    function testAStrangersSealNeitherBlocksNorPricesTheAuthorsNote() public {
        (address y, T.Venue memory venueB) = _otherVenue();
        T.NoteParams memory p = _margNote(T.Side.Buy, 11_000, 1, "front-run me");
        p.venue = router.validateVenue(p, key);
        bytes32 hash = hook.sealHash(alice, p);
        vm.prank(bob);
        hook.seal(y, venueB, hash);
        (uint64 at,,,,) = hook.seals(hook.sealKey(alice, hash));
        assertEq(at, 0, "the stranger's seal is not the author's");
        uint256 live = router.postPrice(p.venue, true);
        (, uint256 strangerBuy,,,) = hook.seals(hook.sealKey(bob, hash));
        assertGt(strangerBuy > live ? strangerBuy - live : live - strangerBuy, live / 2, "the venues differ");
        (bytes32 id,) = _note(alice, p, 10 ether); // not TooEarly
        assertApproxEqRel(hook.noteOf(id).postPrice, live, 0.001e18, "priced on its own venue");
        // the author can still seal the same note for themselves
        T.NoteParams memory p2 = _margNote(T.Side.Buy, 11_000, 1, "front-run me");
        p2.venue = p.venue;
        vm.prank(alice);
        hook.seal(p2.x, p2.venue, hash);
        (at,,,,) = hook.seals(hook.sealKey(alice, hash));
        assertEq(at, vm.getBlockTimestamp());
    }

    /// @dev An author seals a MARG note with another venue's baselines: the reveal ignores that seal.
    function testAnAuthorsSealOnAnotherVenueDoesNotPriceTheNote() public {
        (address y, T.Venue memory venueB) = _otherVenue();
        T.NoteParams memory p = _margNote(T.Side.Sell, 9000, 1, "self-dealing");
        p.venue = router.validateVenue(p, key);
        bytes32 hash = hook.sealHash(alice, p);
        vm.prank(alice);
        hook.seal(y, venueB, hash);
        (,, uint256 sealedSell,,) = hook.seals(hook.sealKey(alice, hash));
        vm.warp(vm.getBlockTimestamp() + hook.SEAL_MIN());
        vm.roll(vm.getBlockNumber() + 150);
        uint256 live = router.postPrice(p.venue, false);
        assertGt(sealedSell > live ? sealedSell - live : live - sealedSell, live / 2, "the venues differ");
        (bytes32 id,) = _note(alice, p, 10 ether);
        assertEq(hook.noteOf(id).postPrice, live, "priced on the note's own venue");
        (uint64 at,,,,) = hook.seals(hook.sealKey(alice, hash));
        assertEq(at, 0, "the mismatched seal is spent");
    }

    // ---------------------------------------------------------------- d492eadc: a lapsed seal can be replaced

    function testALapsedSealCanBeSealedAgain() public {
        T.NoteParams memory p = _margNote(T.Side.Buy, 11_000, 1, "again #d4");
        p.venue = router.validateVenue(p, key);
        bytes32 hash = hook.sealHash(alice, p);
        vm.prank(alice);
        hook.seal(p.x, p.venue, hash);
        vm.warp(vm.getBlockTimestamp() + hook.SEAL_MAX());
        vm.prank(alice);
        vm.expectRevert(MarginaliaHook.InvalidNote.selector);
        hook.seal(p.x, p.venue, hash); // still live at exactly SEAL_MAX
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        router.checkpointVenue(p, key); // the fixture's window expired; restart it and let it mature
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
        vm.prank(alice);
        hook.seal(p.x, p.venue, hash);
        (uint64 at,,,,) = hook.seals(hook.sealKey(alice, hash));
        assertEq(at, vm.getBlockTimestamp(), "a fresh seal replaces the lapsed one");
    }

    // ---------------------------------------------------------------- 43fe5339: X's totalSupply cannot block settle or retract

    function _xCall(address x, uint32 targetBps) internal returns (bytes32 id) {
        bool x0 = x < address(imd);
        (address c0, address c1) = x0 ? (x, address(imd)) : (address(imd), x);
        PoolKey memory k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 3000, 60, IHooks(address(0)));
        manager.initialize(k, uint160(1 << 96));
        ERC20(x).transfer(address(liquidity), 1000 ether);
        imd.transfer(address(liquidity), 1000 ether);
        liquidity.add(k, -887_220, 887_220, 1e18);
        T.NoteParams memory p = _margNote(T.Side.Buy, targetBps, 1, "x call");
        p.x = x;
        p.venue = T.Venue(T.VenueKind.UniV4, PoolId.unwrap(k.toId()), address(0), false);
        router.checkpointVenue(p, k);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 300);
        vm.prank(alice);
        router.note(p, k, 1 ether, 1, vm.getBlockTimestamp() + 1);
        id = bytes32(hook.noteCount());
    }

    function testARevertingTotalSupplyStillSettlesWrongAndPaysTheKeeper() public {
        SupplySwitchToken x = new SupplySwitchToken();
        bytes32 id = _xCall(address(x), 11_000);
        uint256 bond = hook.noteOf(id).deposit;
        _observeThree(id);
        x.setBrick(true);
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
        assertEq(imd.balanceOf(keeper), bond * hook.KEEPER_BPS() / 10_000, "the keeper earns the bounty");
        assertLt(_rec(alice).score, 0, "the wrong call is booked");
    }

    function testARevertingTotalSupplyDoesNotBlockARetraction() public {
        SupplySwitchToken x = new SupplySwitchToken();
        bytes32 id = _xCall(address(x), 11_000);
        x.setBrick(true);
        vm.prank(alice);
        hook.retract(id, "changed my mind");
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Retracted));
    }

    function testAHugeSupplyBooksTierOneInsteadOfOverflowing() public {
        MockERC20 x = new MockERC20("H", "H", 2 ** 200);
        bytes32 id = _xCall(address(x), 11_000);
        _observeThree(id);
        hook.settle(id);
        assertEq(uint8(hook.noteOf(id).status), uint8(T.Status.Wrong));
        // tier 1: the same call's difficulty on a zero market cap
        uint256 d = hook.pricer().difficulty(11_000, true, 1, 0);
        assertEq(_rec(alice).score, -int256(d));
    }

    // ---------------------------------------------------------------- 559dc581: retracted notes leave the day's refund split

    function testARetractedNoteLeavesTheDaysRefundSplit() public {
        (bytes32 a,) = _note(alice, _margNote(T.Side.Buy, 11_000, 1, "alice"), 1 ether);
        (bytes32 b,) = _note(bob, _margNote(T.Side.Sell, 9000, 1, "bob"), 1 ether);
        uint32 day = hook.today();
        assertEq(hook.notesPerDay(day), 2);
        vm.prank(bob);
        hook.retract(b, "out");
        assertEq(hook.notesPerDay(day), 1, "a retracted note never claims, so it is not counted");
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 pool = hook.refundPool(day);
        uint256 expected = pool > hook.STAMP() ? hook.STAMP() : pool;
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        hook.claimRefund(a);
        assertEq(imd.balanceOf(alice) - before, expected, "the sole non-retracted note takes the full split");
    }

    /// @dev A note that claimed its refund and is retracted later does not shrink the count twice.
    function testARetractionAfterTheRefundClaimDoesNotDoubleCount() public {
        (bytes32 a,) = _note(alice, _margNote(T.Side.Buy, 11_000, 3, "alice"), 1 ether);
        _note(bob, _margNote(T.Side.Sell, 9000, 3, "bob"), 1 ether);
        uint32 day = hook.today();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        hook.claimRefund(a);
        assertEq(hook.notesPerDay(day), 1);
        vm.prank(alice);
        hook.retract(a, "later");
        assertEq(hook.notesPerDay(day), 1, "bob's note is still counted");
    }
}
