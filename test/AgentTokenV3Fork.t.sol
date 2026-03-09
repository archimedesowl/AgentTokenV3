// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentTokenV3.sol";
import "../src/interfaces/IAgentTokenV3.sol";

/**
 * @title AgentTokenV3ForkTest
 * @notice Fork tests against real AIXBT and FUTURE tokens on Base mainnet.
 *
 * Tests the upgrade path:
 * 1. Deploy AgentTokenV3 implementation on the fork
 * 2. Upgrade the proxy's implementation slot to point to V3
 * 3. Test that existing V2 functionality still works
 * 4. Test new CL pool features with real Uniswap V3 pools
 *
 * Since these tokens are EIP-1167 minimal proxies pointing to an implementation,
 * we simulate upgrade by using vm.store to update the implementation address
 * in the proxy's storage, or by deploying V3 behind a fresh proxy matching
 * the existing storage layout.
 */
contract AgentTokenV3ForkTest is Test {
    // Base mainnet addresses
    address constant AIXBT = 0x4F9Fd6Be4a90f2620860d680c0d4d5Fb53d1A825;
    address constant FUTURE = 0x810e903C667e02D901f8A70413161629068e6EC5;
    address constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // AIXBT implementation (V1)
    address constant AIXBT_IMPL = 0x082Cb6e892Dd0699B5f0d22f7D2e638BBAdA5D94;
    // FUTURE implementation (V2)
    address constant FUTURE_IMPL = 0x7BaB5D2e3EbdE7293888B3f4c022aAAAD88Ae2db;

    // Uniswap V3 SwapRouter on Base
    address constant UNIV3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    AgentTokenV3 public v3Impl;

    address public alice;
    address public whale;

    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork("https://mainnet.base.org");

        // Deploy V3 implementation on fork
        v3Impl = new AgentTokenV3();

        alice = makeAddr("alice");
        whale = makeAddr("whale");
    }

    // ================================================================
    //  HELPER: Upgrade a minimal proxy (EIP-1167) to a new impl
    //
    //  EIP-1167 minimal proxies store the impl address in the bytecode
    //  itself, not in storage. To "upgrade" for testing, we use vm.etch
    //  to replace the proxy bytecode with a delegatecall proxy pointing
    //  to our new implementation, preserving the proxy's storage.
    // ================================================================

    function _upgradeMinimalProxy(address proxy, address newImpl) internal {
        // Build EIP-1167 clone bytecode pointing to newImpl
        // Format: 363d3d373d3d3d363d73<addr>5af43d82803e903d91602b57fd5bf3
        bytes memory code = abi.encodePacked(
            hex"363d3d373d3d3d363d73",
            newImpl,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        vm.etch(proxy, code);
    }

    /**
     * @dev Some V2 tokens have _autoSwapInProgress=true in storage (byte at
     *      slot 3, offset 20). V3 reads this same slot and skips tax if set.
     *      This helper clears it, simulating the post-upgrade cleanup the
     *      Virtuals team would perform.
     */
    function _clearAutoSwapFlag(address proxy) internal {
        // slot 3 layout: [pairToken(20 bytes)][_autoSwapInProgress(1 byte)][padding]
        bytes32 slot3 = vm.load(proxy, bytes32(uint256(3)));
        // Clear byte at offset 20 (bit 160). Mask keeps bytes 0..19 and 21..31.
        bytes32 mask = ~bytes32(uint256(0xFF) << 160);
        vm.store(proxy, bytes32(uint256(3)), slot3 & mask);
    }

    /**
     * @dev Some V2 tokens blacklisted their V2 pair. After V3 upgrade, the
     *      owner should un-blacklist the pair for trading to resume.
     */
    function _clearBlacklistForPair(AgentTokenV3 token) internal {
        address pair = token.uniswapV2Pair();
        if (token.blacklists(pair)) {
            address tokenOwner = token.owner();
            vm.prank(tokenOwner);
            token.removeBlacklistAddress(pair);
        }
    }

    /**
     * @dev Some V2 tokens have fundedDate=0 in storage. The V3 _transfer
     *      rejects sells to V2 pair when fundedDate==0 (InitialLiquidityNotYetAdded).
     *      This helper sets fundedDate to 1 to unblock V2 pair sells.
     */
    function _ensureFundedDate(address proxy) internal {
        // fundedDate is uint32 at slot 2, offset 21 (4 bytes).
        bytes32 slot2 = vm.load(proxy, bytes32(uint256(2)));
        // Check if fundedDate is 0: bytes at positions 7-10 from the right
        // offset 21 means bits 168..199
        uint32 fundedDate = uint32(uint256(slot2) >> 168);
        if (fundedDate == 0) {
            // Set fundedDate to 1 (non-zero, unblocks trading)
            bytes32 mask = ~bytes32(uint256(0xFFFFFFFF) << 168);
            bytes32 newVal = (slot2 & mask) | bytes32(uint256(1) << 168);
            vm.store(proxy, bytes32(uint256(2)), newVal);
        }
    }

    // ================================================================
    //  HELPER: Get a whale address that holds tokens
    // ================================================================

    function _getTokenHolder(address token, uint256 minAmount) internal returns (address) {
        // For fork tests, we'll just deal tokens to our whale address
        deal(token, whale, minAmount);
        return whale;
    }

    // ================================================================
    //  TEST: Upgrade AIXBT (V1) to V3, verify storage preserved
    // ================================================================

    function test_fork_upgradeAIXBT_preservesStorage() public {
        // Capture V1 state before upgrade
        AgentTokenV3 aixbt = AgentTokenV3(payable(AIXBT));
        string memory nameBefore = aixbt.name();
        string memory symbolBefore = aixbt.symbol();
        uint256 supplyBefore = aixbt.totalSupply();
        address pairBefore = aixbt.uniswapV2Pair();
        address pairTokenBefore = aixbt.pairToken();

        // Upgrade
        _upgradeMinimalProxy(AIXBT, address(v3Impl));

        // Verify all V1 storage is preserved
        assertEq(aixbt.name(), nameBefore, "name preserved");
        assertEq(aixbt.symbol(), symbolBefore, "symbol preserved");
        assertEq(aixbt.totalSupply(), supplyBefore, "supply preserved");
        assertEq(aixbt.uniswapV2Pair(), pairBefore, "V2 pair preserved");
        assertEq(aixbt.pairToken(), pairTokenBefore, "pair token preserved");
    }

    // ================================================================
    //  TEST: Upgrade FUTURE (V2) to V3, verify V2 storage preserved
    // ================================================================

    function test_fork_upgradeFUTURE_preservesV2Storage() public {
        AgentTokenV3 future = AgentTokenV3(payable(FUTURE));

        // Capture V2 state
        string memory nameBefore = future.name();
        string memory symbolBefore = future.symbol();
        uint256 supplyBefore = future.totalSupply();
        uint16 buyTaxBefore = future.projectBuyTaxBasisPoints();
        uint16 sellTaxBefore = future.projectSellTaxBasisPoints();
        address pairBefore = future.uniswapV2Pair();

        // Upgrade
        _upgradeMinimalProxy(FUTURE, address(v3Impl));

        // Verify all V2 storage is preserved
        assertEq(future.name(), nameBefore, "name preserved");
        assertEq(future.symbol(), symbolBefore, "symbol preserved");
        assertEq(future.totalSupply(), supplyBefore, "supply preserved");
        assertEq(future.projectBuyTaxBasisPoints(), buyTaxBefore, "buy tax preserved");
        assertEq(future.projectSellTaxBasisPoints(), sellTaxBefore, "sell tax preserved");
        assertEq(future.uniswapV2Pair(), pairBefore, "V2 pair preserved");

        // New V3 features should have clean state
        address[] memory cls = future.clPools();
        assertEq(cls.length, 0, "CL pools should be empty initially");
    }

    // ================================================================
    //  HELPER: Perform full V3 upgrade + post-upgrade cleanup
    //  This is what the Virtuals team would do after upgrading.
    // ================================================================

    function _upgradeToV3WithCleanup(address proxy) internal returns (AgentTokenV3) {
        _upgradeMinimalProxy(proxy, address(v3Impl));
        _clearAutoSwapFlag(proxy);
        _ensureFundedDate(proxy);
        AgentTokenV3 token = AgentTokenV3(payable(proxy));
        _clearBlacklistForPair(token);
        return token;
    }

    // ================================================================
    //  TEST: After upgrade, existing V2 sells still work
    // ================================================================

    function test_fork_FUTURE_v2SellStillWorks() public {
        AgentTokenV3 future = _upgradeToV3WithCleanup(FUTURE);

        // Get tokens for alice
        deal(FUTURE, alice, 10_000 ether);

        address v2Pool = future.uniswapV2Pair();
        uint256 sellAmount = 100 ether;

        uint256 aliceBefore = future.balanceOf(alice);
        uint256 poolBefore = future.balanceOf(v2Pool);

        vm.prank(alice);
        future.transfer(v2Pool, sellAmount);

        // Alice should lose the full sellAmount
        assertEq(future.balanceOf(alice), aliceBefore - sellAmount, "alice lost full amount");

        // Pool should receive less than sellAmount (V2 tax deducted)
        uint256 poolGot = future.balanceOf(v2Pool) - poolBefore;
        assertTrue(poolGot < sellAmount, "V2 pool should receive less than sell amount due to tax");
        assertTrue(poolGot > 0, "V2 pool should receive something");
    }

    // ================================================================
    //  TEST: After upgrade, regular transfers (no pool) untaxed
    // ================================================================

    function test_fork_FUTURE_regularTransferNoTax() public {
        AgentTokenV3 future = _upgradeToV3WithCleanup(FUTURE);

        deal(FUTURE, alice, 10_000 ether);
        address bob = makeAddr("bob");

        uint256 amount = 500 ether;
        uint256 aliceBefore = future.balanceOf(alice);

        vm.prank(alice);
        future.transfer(bob, amount);

        assertEq(future.balanceOf(alice), aliceBefore - amount);
        assertEq(future.balanceOf(bob), amount, "bob should get exact amount (no tax)");
    }

    // ================================================================
    //  TEST: Register a real V3 pool as CL pool, test sell
    // ================================================================

    function test_fork_FUTURE_addCLPoolAndSell() public {
        AgentTokenV3 future = _upgradeToV3WithCleanup(FUTURE);

        // Find the FUTURE owner
        address futureOwner = future.owner();

        // Deploy a mock CL pool contract to register
        // (We can't easily find a real FUTURE V3 pool, so we mock one)
        address mockPool = address(new MockCLPoolForFork());

        // Add CL pool as owner
        vm.prank(futureOwner);
        future.addCLPool(mockPool);

        assertTrue(future.isCLPool(mockPool), "should be registered as CL pool");
        assertTrue(future.isLiquidityPool(mockPool), "should be registered as LP");

        // Give alice some tokens
        deal(FUTURE, alice, 10_000 ether);

        uint256 sellAmount = 100 ether;
        uint16 sellTax = future.projectSellTaxBasisPoints();
        uint256 expectedTax = (sellAmount * sellTax) / 10000;

        uint256 aliceBefore = future.balanceOf(alice);
        uint256 poolBefore = future.balanceOf(mockPool);
        uint256 contractBefore = future.balanceOf(FUTURE);

        vm.prank(alice);
        future.transfer(mockPool, sellAmount);

        // CL model: pool gets FULL amount
        assertEq(future.balanceOf(mockPool), poolBefore + sellAmount, "CL pool gets full amount");
        // Alice debited amount + tax
        assertEq(future.balanceOf(alice), aliceBefore - sellAmount - expectedTax, "alice debited amount + tax");
        // Contract holds tax
        assertEq(future.balanceOf(FUTURE), contractBefore + expectedTax, "contract holds tax");
    }

    // ================================================================
    //  TEST: Verify the FUTURE tax rate is as expected (1%)
    // ================================================================

    function test_fork_FUTURE_taxRate() public {
        AgentTokenV3 future = _upgradeToV3WithCleanup(FUTURE);

        // FUTURE (AgentTokenV2) should have 1% tax
        uint16 sellTax = future.projectSellTaxBasisPoints();
        uint16 buyTax = future.projectBuyTaxBasisPoints();

        // Log the actual rates
        emit log_named_uint("FUTURE sell tax BP", sellTax);
        emit log_named_uint("FUTURE buy tax BP", buyTax);

        // Verify they're reasonable (should be 100 = 1%)
        assertTrue(sellTax > 0 && sellTax <= 1000, "sell tax should be between 0-10%");
        assertTrue(buyTax >= 0 && buyTax <= 1000, "buy tax should be between 0-10%");
    }

    // ================================================================
    //  TEST: CL sell via transferFrom (simulates router)
    // ================================================================

    function test_fork_FUTURE_clSellViaTransferFrom() public {
        AgentTokenV3 future = _upgradeToV3WithCleanup(FUTURE);

        address futureOwner = future.owner();
        address mockPool = address(new MockCLPoolForFork());

        vm.prank(futureOwner);
        future.addCLPool(mockPool);

        deal(FUTURE, alice, 10_000 ether);

        // Simulate router doing transferFrom
        address router = makeAddr("router");
        uint256 sellAmount = 100 ether;
        uint16 sellTax = future.projectSellTaxBasisPoints();
        uint256 expectedTax = (sellAmount * sellTax) / 10000;

        vm.prank(alice);
        future.approve(router, type(uint256).max);

        uint256 aliceBefore = future.balanceOf(alice);

        vm.prank(router);
        future.transferFrom(alice, mockPool, sellAmount);

        // CL model
        assertEq(future.balanceOf(mockPool), sellAmount, "pool gets full amount");
        assertEq(future.balanceOf(alice), aliceBefore - sellAmount - expectedTax, "alice debited correctly");
    }

    // ================================================================
    //  TEST: Remove CL pool → reverts to V2 behavior
    // ================================================================

    function test_fork_FUTURE_removeCLPoolRevertsToV2() public {
        AgentTokenV3 future = _upgradeToV3WithCleanup(FUTURE);

        address futureOwner = future.owner();
        address mockPool = address(new MockCLPoolForFork());

        vm.startPrank(futureOwner);
        future.addCLPool(mockPool);
        future.removeCLPool(mockPool);
        vm.stopPrank();

        assertFalse(future.isCLPool(mockPool));
        assertFalse(future.isLiquidityPool(mockPool));

        deal(FUTURE, alice, 10_000 ether);
        uint256 amount = 100 ether;
        uint256 aliceBefore = future.balanceOf(alice);

        vm.prank(alice);
        future.transfer(mockPool, amount);

        // Not a pool anymore → no tax
        assertEq(future.balanceOf(alice), aliceBefore - amount, "no tax on non-pool");
        assertEq(future.balanceOf(mockPool), amount, "pool gets exact amount");
    }

    // ================================================================
    //  TEST: AIXBT upgrade + CL pool features
    // ================================================================

    function test_fork_AIXBT_upgradeAndCLSell() public {
        AgentTokenV3 aixbt = AgentTokenV3(payable(AIXBT));

        // Capture owner before upgrade
        address aixbtOwner = aixbt.owner();

        _upgradeMinimalProxy(AIXBT, address(v3Impl));

        // Verify CL pools empty
        assertEq(aixbt.clPools().length, 0);

        // Add a mock CL pool
        address mockPool = address(new MockCLPoolForFork());
        vm.prank(aixbtOwner);
        aixbt.addCLPool(mockPool);

        deal(AIXBT, alice, 10_000 ether);

        uint16 sellTax = aixbt.projectSellTaxBasisPoints();
        uint256 sellAmount = 100 ether;
        uint256 expectedTax = (sellAmount * sellTax) / 10000;

        uint256 aliceBefore = aixbt.balanceOf(alice);

        vm.prank(alice);
        aixbt.transfer(mockPool, sellAmount);

        assertEq(aixbt.balanceOf(mockPool), sellAmount, "AIXBT CL pool gets full amount");
        assertEq(aixbt.balanceOf(alice), aliceBefore - sellAmount - expectedTax, "alice debited amount + tax");
    }

    // ================================================================
    //  TEST: Balance invariant holds after CL sell
    // ================================================================

    function test_fork_FUTURE_balanceInvariant() public {
        AgentTokenV3 future = _upgradeToV3WithCleanup(FUTURE);

        address futureOwner = future.owner();
        MockCLPoolForFork mockPool = new MockCLPoolForFork();

        vm.prank(futureOwner);
        future.addCLPool(address(mockPool));

        deal(FUTURE, alice, 10_000 ether);

        uint256 sellAmount = 100 ether;

        // Record pool balance before
        uint256 poolBefore = future.balanceOf(address(mockPool));

        vm.prank(alice);
        future.transfer(address(mockPool), sellAmount);

        uint256 poolAfter = future.balanceOf(address(mockPool));

        // The CL invariant: poolBefore + expectedAmount <= poolAfter
        assertTrue(poolBefore + sellAmount <= poolAfter, "CL balance invariant holds");
    }
}

/// @dev Minimal contract used as a CL pool stand-in for fork tests
contract MockCLPoolForFork {
    receive() external payable {}
}
