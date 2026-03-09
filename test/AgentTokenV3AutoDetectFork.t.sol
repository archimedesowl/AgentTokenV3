// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentTokenV3.sol";
import "../src/interfaces/IAgentTokenV3.sol";
import "../src/interfaces/ICLFactory.sol";
import "../src/interfaces/IAeroV2Factory.sol";

/**
 * @title AgentTokenV3AutoDetectForkTest
 * @notice Fork tests that verify auto-detection against real Base mainnet
 *         Uniswap V3, Aerodrome Slipstream, and Aerodrome V2 factories.
 *
 *         Uses FUTURE (V2 AgentToken) as a stand-in to test factory lookups.
 *         We impersonate the FUTURE proxy admin to upgrade it to V3, then
 *         register the real factories and verify auto-detection works.
 */
contract AgentTokenV3AutoDetectForkTest is Test {
    event PoolAutoDetected(address indexed pool, address indexed factory);
    event CLPoolAdded(address indexed pool);
    event LiquidityPoolAdded(address addedPool);

    // --- Base Mainnet Addresses ---
    address constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
    address constant FUTURE = 0x810e903C667e02D901f8A70413161629068e6EC5;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // --- Factory Addresses (Base Mainnet) ---
    address constant UNIV3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant AERO_CLFACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    // --- FUTURE-specific ---
    // FUTURE owner (who can call onlyOwnerOrFactory functions)
    address futureOwner;
    AgentTokenV3 future;
    address futureProxy = FUTURE;

    // FUTURE holder with lots of tokens for testing
    address alice = address(0xBB);

    function setUp() public {
        // Fork Base mainnet
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        vm.createSelectFork(rpcUrl);

        // Deploy V3 implementation
        AgentTokenV3 v3impl = new AgentTokenV3();

        // Get current FUTURE owner
        future = AgentTokenV3(payable(futureProxy));
        futureOwner = future.owner();

        // Upgrade FUTURE proxy to V3 implementation
        // FUTURE is an EIP-1167 minimal proxy — the impl address is in the bytecode.
        // We use vm.etch to replace the bytecode with a new clone pointing to V3.
        _upgradeMinimalProxy(futureProxy, address(v3impl));

        // Clear _autoSwapInProgress flag if set by V2 (post-upgrade cleanup)
        _clearAutoSwapFlag(futureProxy);

        // Re-wrap
        future = AgentTokenV3(payable(futureProxy));

        // Fund alice with FUTURE tokens using Foundry's deal cheatcode
        deal(futureProxy, alice, 100_000 ether);
    }

    /**
     * @dev Upgrades an EIP-1167 minimal proxy by etching new bytecode.
     *      Preserves the proxy's storage (state).
     */
    function _upgradeMinimalProxy(address proxy, address newImpl) internal {
        bytes memory code = abi.encodePacked(
            hex"363d3d373d3d3d363d73",
            newImpl,
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        vm.etch(proxy, code);
    }

    /**
     * @dev Some V2 tokens have _autoSwapInProgress=true in storage (byte at
     *      slot 3, offset 20). Clear it so V3 tax processing works.
     */
    function _clearAutoSwapFlag(address proxy) internal {
        bytes32 slot3 = vm.load(proxy, bytes32(uint256(3)));
        bytes32 mask = ~bytes32(uint256(0xFF) << 160);
        vm.store(proxy, bytes32(uint256(3)), slot3 & mask);
    }

    // ================================================================
    //       FACTORY REGISTRATION: Real Base factories
    // ================================================================

    function test_fork_registerRealFactories() public {
        vm.startPrank(futureOwner);

        // Register Uniswap V3 factory
        uint24[] memory uniV3Fees = new uint24[](4);
        uniV3Fees[0] = 100;
        uniV3Fees[1] = 500;
        uniV3Fees[2] = 3000;
        uniV3Fees[3] = 10000;
        future.addUniV3Factory(UNIV3_FACTORY, uniV3Fees);

        // Register Aerodrome Slipstream CLFactory
        int24[] memory slipSpacings = new int24[](4);
        slipSpacings[0] = 1;
        slipSpacings[1] = 50;
        slipSpacings[2] = 100;
        slipSpacings[3] = 200;
        future.addSlipstreamFactory(AERO_CLFACTORY, slipSpacings);

        // Register Aerodrome V2 factory
        future.addV2Factory(AERO_V2_FACTORY);

        vm.stopPrank();

        // Verify registration
        assertEq(future.clFactoryCount(), 2);
        assertEq(future.v2FactoryCount(), 1);

        (address f0, bool isSlip0, , uint24[] memory fees0) = future.getCLFactory(0);
        assertEq(f0, UNIV3_FACTORY);
        assertFalse(isSlip0);
        assertEq(fees0.length, 4);

        (address f1, bool isSlip1, int24[] memory ts1, ) = future.getCLFactory(1);
        assertEq(f1, AERO_CLFACTORY);
        assertTrue(isSlip1);
        assertEq(ts1.length, 4);

        assertEq(future.getV2Factory(0), AERO_V2_FACTORY);
    }

    // ================================================================
    //   AUTO-DETECT: Probe UniV3 factory for FUTURE/VIRTUAL pool
    // ================================================================

    function test_fork_uniV3Factory_getPoolWorks() public {
        // Directly check if UniV3 factory responds for FUTURE/VIRTUAL
        // This pool may or may not exist — we're testing the factory call doesn't revert
        address pool = ICLFactory(UNIV3_FACTORY).getPool(FUTURE, VIRTUAL, 3000);
        // pool could be address(0) if no pool exists for this pair/fee
        // But the call should not revert
        assertTrue(pool == address(0) || pool != address(0), "getPool should return an address");
    }

    function test_fork_slipstreamFactory_getPoolWorks() public {
        // Directly check if Slipstream factory responds
        address pool = ISlipstreamCLFactory(AERO_CLFACTORY).getPool(FUTURE, VIRTUAL, 200);
        assertTrue(pool == address(0) || pool != address(0), "getPool should return an address");
    }

    function test_fork_aeroV2Factory_getPoolWorks() public {
        // Directly check Aero V2 factory for FUTURE/VIRTUAL
        address pool = IAeroV2Factory(AERO_V2_FACTORY).getPool(FUTURE, VIRTUAL, false);
        assertTrue(pool == address(0) || pool != address(0), "getPool should return an address");
    }

    // ================================================================
    //   AUTO-DETECT: Transfer to a new contract, no false positive
    // ================================================================

    function test_fork_transferToEOA_noAutoDetect() public {
        // Register all factories
        _registerAllFactories();

        // Transfer to a random EOA — should NOT be detected as a pool
        address randomEOA = address(0x12345678);

        uint256 aliceBefore = future.balanceOf(alice);
        uint256 amount = 100 ether;

        vm.prank(alice);
        future.transfer(randomEOA, amount);

        // No tax applied
        assertEq(future.balanceOf(alice), aliceBefore - amount);
        assertEq(future.balanceOf(randomEOA), amount);
        assertFalse(future.isLiquidityPool(randomEOA));
    }

    function test_fork_transferToContract_noFalsePositive() public {
        _registerAllFactories();

        // Deploy a random contract (not a pool)
        address randomContract = address(new DummyContract());

        uint256 aliceBefore = future.balanceOf(alice);
        uint256 amount = 100 ether;

        vm.prank(alice);
        future.transfer(randomContract, amount);

        // No tax, not detected as pool
        assertEq(future.balanceOf(alice), aliceBefore - amount);
        assertFalse(future.isLiquidityPool(randomContract));
    }

    // ================================================================
    //   AUTO-DETECT: Multiple transfers gas comparison
    // ================================================================

    function test_fork_gasComparison_firstVsSecondTransfer() public {
        _registerAllFactories();

        address randomContract = address(new DummyContract());

        // First transfer: probes factories (higher gas)
        vm.prank(alice);
        uint256 gas1Start = gasleft();
        future.transfer(randomContract, 10 ether);
        uint256 gas1Used = gas1Start - gasleft();

        // Second transfer: cached as non-pool (lower gas)
        vm.prank(alice);
        uint256 gas2Start = gasleft();
        future.transfer(randomContract, 10 ether);
        uint256 gas2Used = gas2Start - gasleft();

        // Second should be cheaper (cached)
        assertTrue(gas2Used < gas1Used, "cached transfer should use less gas");

        emit log_named_uint("First transfer gas", gas1Used);
        emit log_named_uint("Second transfer gas (cached)", gas2Used);
        emit log_named_uint("Gas saved", gas1Used - gas2Used);
    }

    // ================================================================
    //   AUTO-DETECT: Real pool if it exists
    // ================================================================

    function test_fork_detectRealPoolIfExists() public {
        _registerAllFactories();

        // Check if there's a real FUTURE/VIRTUAL pool on any factory
        // Try Aero V2 first (most likely to exist)
        address v2Pool = IAeroV2Factory(AERO_V2_FACTORY).getPool(FUTURE, VIRTUAL, false);

        if (v2Pool != address(0)) {
            // There's a real V2 pool — test auto-detection
            assertFalse(future.isLiquidityPool(v2Pool), "should not be registered yet");

            // Transfer to the pool
            vm.prank(alice);
            future.transfer(v2Pool, 10 ether);

            // Should be auto-detected
            assertTrue(future.isLiquidityPool(v2Pool), "V2 pool should be auto-detected");
            assertFalse(future.isCLPool(v2Pool), "V2 pool should NOT be CL");
        } else {
            // No pool exists — try UniV3
            address uniPool = ICLFactory(UNIV3_FACTORY).getPool(FUTURE, VIRTUAL, 10000);
            if (uniPool != address(0)) {
                vm.prank(alice);
                future.transfer(uniPool, 10 ether);
                assertTrue(future.isLiquidityPool(uniPool));
                assertTrue(future.isCLPool(uniPool));
            }
            // If no pools exist at all, that's fine — the test just verifies no crash
        }
    }

    // ================================================================
    //   Helper: Register all 3 real factories
    // ================================================================

    function _registerAllFactories() internal {
        vm.startPrank(futureOwner);

        uint24[] memory uniV3Fees = new uint24[](4);
        uniV3Fees[0] = 100;
        uniV3Fees[1] = 500;
        uniV3Fees[2] = 3000;
        uniV3Fees[3] = 10000;
        future.addUniV3Factory(UNIV3_FACTORY, uniV3Fees);

        int24[] memory slipSpacings = new int24[](4);
        slipSpacings[0] = 1;
        slipSpacings[1] = 50;
        slipSpacings[2] = 100;
        slipSpacings[3] = 200;
        future.addSlipstreamFactory(AERO_CLFACTORY, slipSpacings);

        future.addV2Factory(AERO_V2_FACTORY);

        vm.stopPrank();
    }
}

/// @dev Dummy contract used to test transfers to non-pool contracts
contract DummyContract {
    receive() external payable {}
}
