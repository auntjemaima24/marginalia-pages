// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture, LiquidityHelper, TestSwapRouter} from "./helpers/Fixture.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Marginalia} from "src/Marginalia.sol";
import {MarginaliaHook} from "src/MarginaliaHook.sol";
import {MarginaliaRouter} from "src/MarginaliaRouter.sol";
import {MarginaliaImpls} from "src/MarginaliaImpls.sol";
import {MarginaliaTypes as T} from "src/MarginaliaTypes.sol";
import {HookFlags} from "src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

contract LaunchBindingTest is Fixture {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _setup();
    }

    function _fresh() private returns (MarginaliaHook h, PoolKey memory k) {
        address t = address(new Marginalia());
        h = _deployHook(manager, t);
        (address a, address b) = t < address(imd) ? (t, address(imd)) : (address(imd), t);
        k = PoolKey(Currency.wrap(a), Currency.wrap(b), 12500, 60, IHooks(address(h)));
    }

    function _refuseInitialize(MarginaliaHook h, PoolKey memory k, address caller) private {
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(h),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(MarginaliaHook.InvalidPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k, uint160(1 << 96));
        assertFalse(h.initialized(), "failed initialization left the pool bound");
    }

    function testOnlyTheSuppliedFactoryCanInitializeAndFailureDoesNotConsumeBinding() public {
        (MarginaliaHook h, PoolKey memory k) = _fresh();
        _refuseInitialize(h, k, alice);
        manager.initialize(k, uint160(1 << 96));
        assertTrue(h.initialized());
        assertEq(h.imd(), address(imd));
        assertEq(keccak256(abi.encode(h.getPoolKey())), keccak256(abi.encode(k)));
    }

    function testWrongFeeIsRefusedBeforeCorrectFeeBinds() public {
        (MarginaliaHook h, PoolKey memory k) = _fresh();
        k.fee = 3000;
        _refuseInitialize(h, k, address(this));
        k.fee = 12500;
        manager.initialize(k, uint160(1 << 96));
        assertTrue(h.initialized());
    }

    function testNativeAndCodelessPairsAreRefused() public {
        (MarginaliaHook h, PoolKey memory k) = _fresh();
        k.currency0 = Currency.wrap(address(0));
        k.currency1 = Currency.wrap(h.token());
        _refuseInitialize(h, k, address(this));
        address absent = makeAddr("codeless pair");
        address t = h.token();
        (address a, address b) = t < absent ? (t, absent) : (absent, t);
        k.currency0 = Currency.wrap(a);
        k.currency1 = Currency.wrap(b);
        _refuseInitialize(h, k, address(this));
    }

    function testPoolMustContainTheConstructorToken() public {
        (MarginaliaHook h, PoolKey memory k) = _fresh();
        k.currency0 = key.currency0;
        k.currency1 = key.currency1;
        _refuseInitialize(h, k, address(this));
    }

    function testPoolCannotBeReadOrSwappedBeforeBinding() public {
        (MarginaliaHook h, PoolKey memory k) = _fresh();
        vm.expectRevert(MarginaliaHook.InvalidPool.selector);
        h.getPoolKey();
        vm.prank(address(manager));
        vm.expectRevert(MarginaliaHook.InvalidPool.selector);
        h.beforeSwap(alice, k, SwapParams(true, -1 ether, uint160(1 << 96)), "");
    }

    function testPermissionsEnableOnlyTheFiveRequiredFlags() public view {
        Hooks.Permissions memory expected;
        expected.beforeInitialize = true;
        expected.beforeSwap = true;
        expected.afterSwap = true;
        expected.beforeSwapReturnDelta = true;
        expected.afterSwapReturnDelta = true;
        assertEq(keccak256(abi.encode(hook.getHookPermissions())), keccak256(abi.encode(expected)));
        assertEq(uint160(address(hook)) & HookFlags.ALL, 0x20cc);
    }

    function testCompanionsAreThePinnedImmutableMinimalProxies() public view {
        _assertClone(address(router), 0x365CcB3cfBC430600485234F56FD5ECb23fd70D1);
        _assertClone(address(judge), 0xC93460730a79a22282f063A0c6BA5E340Ac372b4);
        _assertClone(address(treasury), 0xe2086012f5F9CC7cAECDBC70dE392e263aAe8481);
        assertEq(address(hook.pricer()), 0xEaff9B262341A0cB05579227e662BFE768A71cfb);
    }

    function _assertClone(address clone, address implementation) private view {
        assertEq(
            clone.code,
            abi.encodePacked(hex"363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3")
        );
    }

    function testLiquidityFeesAndFullWithdrawalRemainAvailable() public {
        uint128 beforeLiquidity = manager.getLiquidity(poolId);
        assertEq(beforeLiquidity, 10_000_000 ether);
        _buy(alice, 100 ether);
        _sell(bob, 100 ether);
        uint256 imdBefore = imd.balanceOf(address(liquidity));
        uint256 margBefore = token.balanceOf(address(liquidity));
        liquidity.add(key, -6000, 6000, 0); // collect fees without changing principal
        assertGt(imd.balanceOf(address(liquidity)), imdBefore);
        assertGt(token.balanceOf(address(liquidity)), margBefore);
        assertEq(manager.getLiquidity(poolId), beforeLiquidity);
        uint256 hookClaims = _claims(address(hook), address(imd));
        liquidity.add(key, -6000, 6000, -int256(uint256(beforeLiquidity)));
        assertEq(manager.getLiquidity(poolId), 0);
        assertGt(imd.balanceOf(address(liquidity)), imdBefore);
        assertGt(token.balanceOf(address(liquidity)), margBefore);
        assertEq(_claims(address(hook), address(imd)), hookClaims, "liquidity exit took hook obligations");
    }

    function testNotedBuyOnFreshManagerSeededOnlyWithMarg() public {
        IPoolManager freshManager = IPoolManager(address(new PoolManager(address(this))));
        MarginaliaHook h = _deployHook(freshManager, address(token));
        PoolKey memory k = key;
        k.hooks = IHooks(address(h));
        freshManager.initialize(k, uint160(1 << 96));
        LiquidityHelper lp = new LiquidityHelper(freshManager);
        token.transfer(address(lp), 10_000_000 ether);
        lp.add(k, margIs0 ? int24(60) : int24(-6000), margIs0 ? int24(6000) : int24(-60), 10_000_000 ether);
        assertEq(imd.balanceOf(address(freshManager)), 0, "must start without paired-token reserves");
        assertGt(token.balanceOf(address(freshManager)), 0);
        MarginaliaRouter r = h.router();
        vm.prank(alice);
        imd.approve(address(r), 0.6 ether);
        T.NoteParams memory p = _margNote(T.Side.Buy, 0, 0, "first note on the token-only seed");
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        uint256 received = r.note(p, k, 0.6 ether, 1, vm.getBlockTimestamp());
        assertEq(token.balanceOf(alice) - before, received);
        assertGt(received, 0);
        assertEq(imd.balanceOf(address(freshManager)), 0.6 ether);
        assertEq(freshManager.balanceOf(address(h), uint160(address(imd))), 0.35 ether);
        assertEq(freshManager.balanceOf(address(h), uint160(address(token))), 0);
        assertEq(h.noteOf(bytes32(uint256(1))).deposit, 0.25 ether);
    }

    function testExactFeeAccountingWhenImdIsCurrencyZero() public {
        _checkFeeOrdering(true);
    }

    function testExactFeeAccountingWhenImdIsCurrencyOne() public {
        _checkFeeOrdering(false);
    }

    function _checkFeeOrdering(bool imdFirst) private {
        // Put the paired mock immediately below/above MARG so both currency orientations are deliberate.
        address pairAddress = address(uint160(address(token)) + (imdFirst ? 0 : 1));
        if (imdFirst) pairAddress = address(uint160(address(token)) - 1);
        assertEq(pairAddress.code.length, 0);
        vm.etch(pairAddress, address(imd).code);
        MockERC20 paired = MockERC20(pairAddress);
        IPoolManager m = IPoolManager(address(new PoolManager(address(this))));
        MarginaliaHook h = _deployHook(m, address(token));
        PoolKey memory k = PoolKey(
            Currency.wrap(imdFirst ? pairAddress : address(token)),
            Currency.wrap(imdFirst ? address(token) : pairAddress),
            12500,
            60,
            IHooks(address(h))
        );
        m.initialize(k, uint160(1 << 96));
        LiquidityHelper lp = new LiquidityHelper(m);
        token.transfer(address(lp), 10_000_000 ether);
        paired.mint(address(lp), 10_000_000 ether);
        lp.add(k, -6000, 6000, 10_000_000 ether);
        TestSwapRouter simple = new TestSwapRouter(m);
        MarginaliaRouter r = h.router();
        paired.mint(alice, 1000 ether);
        vm.startPrank(alice);
        paired.approve(address(simple), type(uint256).max);
        token.approve(address(simple), type(uint256).max);
        paired.approve(address(r), type(uint256).max);
        token.approve(address(r), type(uint256).max);
        vm.stopPrank();
        uint256 claimId = uint160(pairAddress);
        simple.swap(k, imdFirst, 100 ether, alice);
        assertEq(m.balanceOf(address(h), claimId), 0, "plain buy fee");

        uint256 out = simple.swap(k, !imdFirst, 100 ether, alice);
        uint256 quiet = m.balanceOf(address(h), claimId);
        assertEq(quiet, (out + quiet) * 3 / 100, "quiet sell did not charge 3 percent");
        T.NoteParams memory p;
        p.text = "fee ordering thesis";
        p.class = uint8(T.Class.Declared);
        vm.prank(alice);
        r.note(p, k, 0.6 ether, 1, vm.getBlockTimestamp());
        assertEq(m.balanceOf(address(h), claimId), quiet + 0.35 ether);

        vm.prank(alice);
        out = r.sellWithNote(p, k, 100 ether, 1, vm.getBlockTimestamp());
        uint256 notedTake = m.balanceOf(address(h), claimId) - quiet - 0.35 ether;
        uint256 notedFee = (out + notedTake) / 100 + 0.1 ether;
        assertEq(notedTake, notedFee + 0.25 ether, "noted sell fee, stamp or bond changed");
        assertEq(h.noteOf(bytes32(uint256(1))).deposit, 0.25 ether);
        assertEq(h.noteOf(bytes32(uint256(2))).deposit, 0.25 ether);
        uint256 prize = quiet * 7 / 10 + uint256(0.1 ether) * 7 / 10 + notedFee * 7 / 10;
        assertEq(h.thesisPool(h.week()), prize);
        assertEq(h.refundPool(h.today()), quiet + 0.1 ether + notedFee - prize);
        assertEq(m.balanceOf(address(h), uint160(address(token))), 0);
        assertEq(paired.balanceOf(address(h)), 0);
        assertEq(paired.balanceOf(address(r)), 0);
    }

    function testHookAndTokenHaveNoCommonAdminOrWithdrawalSurface() public {
        string[10] memory signatures = [
            "owner()",
            "pause()",
            "unpause()",
            "setFee(uint256)",
            "setRouter(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "mint(address,uint256)",
            "withdraw(address,uint256)",
            "setFactory(address)"
        ];
        uint256 supply = token.totalSupply();
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, 10 ether);
            (bool ok,) = address(hook).call(data);
            assertFalse(ok, signatures[i]);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), supply);
        assertEq(supply, 1_000_000_000 ether);
        assertEq(token.name(), "Marginalia");
        assertEq(token.symbol(), "MARG");
        assertEq(token.decimals(), 18);
    }

    function testConstructorWorksWithoutCompanionOrManagerCode() public {
        vm.etch(MarginaliaImpls.ROUTER_IMPL, "");
        vm.etch(MarginaliaImpls.JUDGE_IMPL, "");
        vm.etch(MarginaliaImpls.TREASURY_IMPL, "");
        vm.etch(MarginaliaImpls.PRICER, "");
        address absentManager = makeAddr("empty rehearsal manager");
        address absentToken = makeAddr("empty rehearsal token");
        bytes memory code = abi.encodePacked(
            type(MarginaliaHook).creationCode, abi.encode(absentManager, absentToken, address(this))
        );
        MarginaliaHook h = MarginaliaHook(_createAtFlags(code));
        assertEq(address(h.poolManager()), absentManager);
        assertEq(h.token(), absentToken);
        _assertClone(address(h.router()), MarginaliaImpls.ROUTER_IMPL);
        _assertClone(address(h.judge()), MarginaliaImpls.JUDGE_IMPL);
        _assertClone(address(h.treasury()), MarginaliaImpls.TREASURY_IMPL);
        // Typed first use requires return data: empty implementations cannot fabricate a successful trade.
        MarginaliaRouter r = h.router();
        vm.expectRevert();
        this.firstNote(r);
    }

    /// @dev Catch the caller's ABI-decoding revert, since the minimal proxy's raw call succeeds empty.
    function firstNote(MarginaliaRouter r) external returns (uint256) {
        T.NoteParams memory p;
        return r.note(p, key, 0.6 ether, 1, vm.getBlockTimestamp());
    }

    function _createAtFlags(bytes memory code) private returns (address at) {
        bytes32 hash = keccak256(code);
        for (uint256 i; i < 300_000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash))))
            );
            if (!HookFlags.matches(predicted, 0x20cc)) continue;
            assembly ("memory-safe") { at := create2(0, add(code, 32), mload(code), salt) }
            assertEq(at, predicted, "empty-EVM rehearsal reverted");
            return at;
        }
        revert("no matching hook address");
    }
}
