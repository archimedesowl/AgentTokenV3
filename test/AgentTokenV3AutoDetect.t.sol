// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentTokenV3.sol";
import "../src/interfaces/IAgentTokenV3.sol";
import "../src/interfaces/IERC20Config.sol";
import "../src/interfaces/ICLFactory.sol";
import "../src/interfaces/IAeroV2Factory.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============================================================
//  MINIMAL PROXY (same as in AgentTokenV3.t.sol)
// ============================================================

contract MinimalProxy2 {
    address internal immutable _impl;

    constructor(address impl_, bytes memory initData) {
        _impl = impl_;
        if (initData.length > 0) {
            (bool ok, ) = impl_.delegatecall(initData);
            require(ok, "init failed");
        }
    }

    fallback() external payable {
        address impl = _impl;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}

// ============================================================
//  MOCK CONTRACTS
// ============================================================

contract MockPairToken2 is ERC20 {
    constructor() ERC20("Virtual", "VIRTUAL") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPair2 {
    address public token0;
    address public token1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address _t0, address _t1) {
        token0 = _t0;
        token1 = _t1;
    }

    function mint(address to) external returns (uint256 liquidity) {
        liquidity = 1000 ether;
        balanceOf[to] += liquidity;
        totalSupply += liquidity;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockV2Factory {
    mapping(bytes32 => address) private _pairs;

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _pairs[_key(tokenA, tokenB)];
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new MockPair2(tokenA, tokenB));
        _pairs[_key(tokenA, tokenB)] = pair;
        _pairs[_key(tokenB, tokenA)] = pair;
    }

    function _key(address a, address b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }
}

contract MockV2Router {
    address public immutable factoryAddr;

    constructor(address factory_) {
        factoryAddr = factory_;
    }

    function factory() external view returns (address) {
        return factoryAddr;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256, uint256, address[] calldata, address, uint256
    ) external {}

    function WETH() external pure returns (address) {
        return address(0);
    }

    function addLiquidityETH(
        address, uint256, uint256, uint256, address, uint256
    ) external pure returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }
}

// ============================================================
//  MOCK CL FACTORY (simulates UniswapV3Factory.getPool)
// ============================================================

contract MockUniV3Factory {
    // (token0, token1, fee) => pool
    mapping(bytes32 => address) private _pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _pools[keccak256(abi.encode(t0, t1, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _pools[keccak256(abi.encode(t0, t1, fee))];
    }
}

// ============================================================
//  MOCK SLIPSTREAM FACTORY (simulates Aerodrome CLFactory.getPool)
// ============================================================

contract MockSlipstreamFactory {
    // (token0, token1, tickSpacing) => pool
    mapping(bytes32 => address) private _pools;

    function setPool(address tokenA, address tokenB, int24 tickSpacing, address pool) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _pools[keccak256(abi.encode(t0, t1, tickSpacing))] = pool;
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _pools[keccak256(abi.encode(t0, t1, tickSpacing))];
    }
}

// ============================================================
//  MOCK AERODROME V2 FACTORY (simulates PoolFactory.getPool)
// ============================================================

contract MockAeroV2Factory {
    // (token0, token1, stable) => pool
    mapping(bytes32 => address) private _pools;

    function setPool(address tokenA, address tokenB, bool stable, address pool) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _pools[keccak256(abi.encode(t0, t1, stable))] = pool;
    }

    function getPool(address tokenA, address tokenB, bool stable) external view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return _pools[keccak256(abi.encode(t0, t1, stable))];
    }

    function isPool(address) external pure returns (bool) {
        return true;
    }
}

// ============================================================
//  MOCK CL POOL (simulates a real CL pool contract)
// ============================================================

contract MockCLPool2 {
    // Just needs to be a contract (has code), that's all
}

// ============================================================
//  TEST CONTRACT
// ============================================================

contract AgentTokenV3AutoDetectTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event LiquidityPoolAdded(address addedPool);
    event CLPoolAdded(address indexed pool);
    event PoolAutoDetected(address indexed pool, address indexed factory);
    event CLFactoryAdded(address indexed factory, bool isSlipstream);
    event V2FactoryAdded(address indexed factory);

    AgentTokenV3 public token;
    MockPairToken2 public pairToken;
    MockV2Factory public mockV2Factory;
    MockV2Router public mockRouter;

    MockUniV3Factory public uniV3Factory;
    MockSlipstreamFactory public slipstreamFactory;
    MockAeroV2Factory public aeroV2Factory;

    address public owner = address(0xAA);
    address public alice = address(0xBB);
    address public bob = address(0xCC);
    address public taxRecipient = address(0xDD);

    uint16 constant BUY_TAX_BP = 100;
    uint16 constant SELL_TAX_BP = 100;
    uint16 constant SWAP_THRESHOLD_BP = 10;

    uint256 constant MAX_SUPPLY = 1_000_000_000;
    uint256 constant LP_SUPPLY = 800_000_000;
    uint256 constant VAULT_SUPPLY = 200_000_000;

    function setUp() public {
        // Deploy basic mocks
        pairToken = new MockPairToken2();
        mockV2Factory = new MockV2Factory();
        mockRouter = new MockV2Router(address(mockV2Factory));

        // Deploy factory mocks for auto-detection
        uniV3Factory = new MockUniV3Factory();
        slipstreamFactory = new MockSlipstreamFactory();
        aeroV2Factory = new MockAeroV2Factory();

        // Deploy implementation
        AgentTokenV3 impl = new AgentTokenV3();

        address[3] memory integrationAddresses = [
            owner,
            address(mockRouter),
            address(pairToken)
        ];

        bytes memory baseParams = abi.encode("TestAgent", "AGENT");
        bytes memory supplyParams = abi.encode(
            IERC20Config.ERC20SupplyParameters({
                maxSupply: MAX_SUPPLY,
                lpSupply: LP_SUPPLY,
                vaultSupply: VAULT_SUPPLY,
                maxTokensPerWallet: 0,
                maxTokensPerTxn: 0,
                botProtectionDurationInSeconds: 0,
                vault: owner
            })
        );
        bytes memory taxParams = abi.encode(
            IERC20Config.ERC20TaxParameters({
                projectBuyTaxBasisPoints: BUY_TAX_BP,
                projectSellTaxBasisPoints: SELL_TAX_BP,
                taxSwapThresholdBasisPoints: SWAP_THRESHOLD_BP,
                projectTaxRecipient: taxRecipient
            })
        );

        bytes memory initData = abi.encodeCall(
            AgentTokenV3.initialize,
            (integrationAddresses, baseParams, supplyParams, taxParams)
        );

        MinimalProxy2 proxy = new MinimalProxy2(address(impl), initData);
        token = AgentTokenV3(payable(address(proxy)));

        pairToken.mint(address(token), 100_000 ether);

        vm.prank(owner);
        token.addInitialLiquidity(owner);

        vm.startPrank(owner);
        token.transfer(alice, 10_000_000 ether);
        token.transfer(bob, 10_000_000 ether);
        vm.stopPrank();
    }

    // ================================================================
    //               FACTORY REGISTRATION
    // ================================================================

    function test_addUniV3Factory_success() public {
        vm.prank(owner);
        uint24[] memory fees = new uint24[](4);
        fees[0] = 100;
        fees[1] = 500;
        fees[2] = 3000;
        fees[3] = 10000;

        vm.expectEmit(true, false, false, true);
        emit CLFactoryAdded(address(uniV3Factory), false);

        token.addUniV3Factory(address(uniV3Factory), fees);

        assertEq(token.clFactoryCount(), 1);

        (address f, bool isSlip, , uint24[] memory tiers) = token.getCLFactory(0);
        assertEq(f, address(uniV3Factory));
        assertFalse(isSlip);
        assertEq(tiers.length, 4);
        assertEq(tiers[0], 100);
    }

    function test_addSlipstreamFactory_success() public {
        vm.prank(owner);
        int24[] memory spacings = new int24[](3);
        spacings[0] = 1;
        spacings[1] = 50;
        spacings[2] = 100;

        vm.expectEmit(true, false, false, true);
        emit CLFactoryAdded(address(slipstreamFactory), true);

        token.addSlipstreamFactory(address(slipstreamFactory), spacings);

        assertEq(token.clFactoryCount(), 1);

        (address f, bool isSlip, int24[] memory ts, ) = token.getCLFactory(0);
        assertEq(f, address(slipstreamFactory));
        assertTrue(isSlip);
        assertEq(ts.length, 3);
        assertEq(ts[1], 50);
    }

    function test_addV2Factory_success() public {
        vm.prank(owner);

        vm.expectEmit(true, false, false, true);
        emit V2FactoryAdded(address(aeroV2Factory));

        token.addV2Factory(address(aeroV2Factory));

        assertEq(token.v2FactoryCount(), 1);
        assertEq(token.getV2Factory(0), address(aeroV2Factory));
    }

    function test_addFactory_revertsNonOwner() public {
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;

        vm.prank(alice);
        vm.expectRevert();
        token.addUniV3Factory(address(uniV3Factory), fees);
    }

    function test_addFactory_revertsZeroAddress() public {
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;

        vm.prank(owner);
        vm.expectRevert();
        token.addUniV3Factory(address(0), fees);
    }

    function test_addFactory_revertsEOA() public {
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;

        vm.prank(owner);
        vm.expectRevert();
        token.addUniV3Factory(address(0x999), fees); // EOA has no code
    }

    function test_addFactory_revertsEmptyTiers() public {
        uint24[] memory fees = new uint24[](0);

        vm.prank(owner);
        vm.expectRevert();
        token.addUniV3Factory(address(uniV3Factory), fees);
    }

    function test_removeCLFactory() public {
        vm.startPrank(owner);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        token.addUniV3Factory(address(uniV3Factory), fees);

        assertEq(token.clFactoryCount(), 1);
        token.removeCLFactory(0);
        assertEq(token.clFactoryCount(), 0);
        vm.stopPrank();
    }

    function test_removeV2Factory() public {
        vm.startPrank(owner);
        token.addV2Factory(address(aeroV2Factory));

        assertEq(token.v2FactoryCount(), 1);
        token.removeV2Factory(0);
        assertEq(token.v2FactoryCount(), 0);
        vm.stopPrank();
    }

    function test_removeCLFactory_revertsOutOfBounds() public {
        vm.prank(owner);
        vm.expectRevert();
        token.removeCLFactory(0);
    }

    // ================================================================
    //               AUTO-DETECTION: UniswapV3
    // ================================================================

    function test_autoDetect_uniV3Pool_onSell() public {
        // Create a mock CL pool contract
        MockCLPool2 pool = new MockCLPool2();

        // Register it in the mock UniV3 factory
        uniV3Factory.setPool(address(token), address(pairToken), 3000, address(pool));

        // Register the factory in the token
        vm.prank(owner);
        uint24[] memory fees = new uint24[](4);
        fees[0] = 100;
        fees[1] = 500;
        fees[2] = 3000;
        fees[3] = 10000;
        token.addUniV3Factory(address(uniV3Factory), fees);

        // Verify pool is NOT yet registered
        assertFalse(token.isLiquidityPool(address(pool)));
        assertFalse(token.isCLPool(address(pool)));

        // Alice transfers tokens to the pool (sell) — should auto-detect
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 sellAmount = 1000 ether;

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit PoolAutoDetected(address(pool), address(uniV3Factory));
        token.transfer(address(pool), sellAmount);

        // Pool should now be registered as both LP and CL
        assertTrue(token.isLiquidityPool(address(pool)));
        assertTrue(token.isCLPool(address(pool)));

        // Tax should have been applied using CL mode (debit-from-sender)
        // Pool receives full amount
        assertEq(token.balanceOf(address(pool)), sellAmount, "pool should receive full amount");

        // Alice pays amount + tax
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;
        assertEq(
            token.balanceOf(alice),
            aliceBefore - sellAmount - expectedTax,
            "alice should pay amount + CL tax"
        );
    }

    function test_autoDetect_uniV3Pool_onBuy() public {
        // Create a mock CL pool contract
        MockCLPool2 pool = new MockCLPool2();

        // Register it in the mock UniV3 factory
        uniV3Factory.setPool(address(token), address(pairToken), 500, address(pool));

        // Register the factory in the token
        vm.prank(owner);
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 3000;
        token.addUniV3Factory(address(uniV3Factory), fees);

        // Fund the pool so it can "sell" tokens to alice (simulate a buy)
        vm.prank(owner);
        token.transfer(address(pool), 100_000 ether);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 buyAmount = 5000 ether;

        // Pool transfers to alice (buy) — should auto-detect
        vm.prank(address(pool));
        token.transfer(alice, buyAmount);

        // Pool should now be registered
        assertTrue(token.isLiquidityPool(address(pool)));
        assertTrue(token.isCLPool(address(pool)));

        // Buy tax should have been applied (deducted from delivery)
        uint256 expectedTax = (buyAmount * BUY_TAX_BP) / 10000;
        assertEq(
            token.balanceOf(alice),
            aliceBefore + buyAmount - expectedTax,
            "alice should receive amount minus buy tax"
        );
    }

    // ================================================================
    //               AUTO-DETECTION: Slipstream
    // ================================================================

    function test_autoDetect_slipstreamPool_onSell() public {
        MockCLPool2 pool = new MockCLPool2();

        // Register in slipstream factory
        slipstreamFactory.setPool(address(token), address(pairToken), 100, address(pool));

        vm.prank(owner);
        int24[] memory spacings = new int24[](2);
        spacings[0] = 50;
        spacings[1] = 100;
        token.addSlipstreamFactory(address(slipstreamFactory), spacings);

        assertFalse(token.isLiquidityPool(address(pool)));

        uint256 sellAmount = 2000 ether;
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        token.transfer(address(pool), sellAmount);

        // Should be auto-detected as CL pool
        assertTrue(token.isLiquidityPool(address(pool)));
        assertTrue(token.isCLPool(address(pool)));

        // CL tax mode: pool gets full amount
        assertEq(token.balanceOf(address(pool)), sellAmount);

        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;
        assertEq(token.balanceOf(alice), aliceBefore - sellAmount - expectedTax);
    }

    // ================================================================
    //               AUTO-DETECTION: Aerodrome V2
    // ================================================================

    function test_autoDetect_aeroV2Pool_onSell() public {
        MockCLPool2 pool = new MockCLPool2(); // just need a contract address

        // Register in aero V2 factory as a volatile pool
        aeroV2Factory.setPool(address(token), address(pairToken), false, address(pool));

        vm.prank(owner);
        token.addV2Factory(address(aeroV2Factory));

        assertFalse(token.isLiquidityPool(address(pool)));

        uint256 sellAmount = 3000 ether;
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        token.transfer(address(pool), sellAmount);

        // Should be auto-detected as LP pool (NOT CL — it's V2)
        assertTrue(token.isLiquidityPool(address(pool)));
        assertFalse(token.isCLPool(address(pool))); // V2 pools are NOT CL

        // V2 tax mode: tax deducted from delivery
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;
        assertEq(
            token.balanceOf(address(pool)),
            sellAmount - expectedTax,
            "V2 pool should receive amount minus tax"
        );
        assertEq(
            token.balanceOf(alice),
            aliceBefore - sellAmount,
            "alice pays exactly sellAmount for V2"
        );
    }

    function test_autoDetect_aeroV2StablePool() public {
        MockCLPool2 pool = new MockCLPool2();

        // Register as stable pool
        aeroV2Factory.setPool(address(token), address(pairToken), true, address(pool));

        vm.prank(owner);
        token.addV2Factory(address(aeroV2Factory));

        uint256 sellAmount = 1000 ether;
        vm.prank(alice);
        token.transfer(address(pool), sellAmount);

        assertTrue(token.isLiquidityPool(address(pool)));
        assertFalse(token.isCLPool(address(pool)));
    }

    // ================================================================
    //               CACHING: Non-pool addresses
    // ================================================================

    function test_nonPoolAddress_cached() public {
        // Register a factory but don't put any pool in it
        vm.prank(owner);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        token.addUniV3Factory(address(uniV3Factory), fees);

        // Transfer to bob (not a pool) — should be cached as non-pool
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 amount = 100 ether;

        vm.prank(alice);
        token.transfer(bob, amount);

        // No tax applied (not a pool)
        assertEq(token.balanceOf(alice), aliceBefore - amount);
        assertEq(token.balanceOf(bob), 10_000_000 ether + amount);

        // Second transfer should be cheaper (cached)
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        token.transfer(bob, amount);
        uint256 gasAfter = gasleft();

        // We don't assert exact gas, just that the transfer still works correctly
        assertEq(token.balanceOf(bob), 10_000_000 ether + amount * 2);
    }

    function test_resetNonPoolCache() public {
        // Register factory
        vm.startPrank(owner);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        token.addUniV3Factory(address(uniV3Factory), fees);
        vm.stopPrank();

        // Create a contract address that will be a pool later
        MockCLPool2 pool = new MockCLPool2();

        // First transfer: not in factory yet → cached as non-pool
        vm.prank(owner);
        token.transfer(address(pool), 100 ether);
        assertFalse(token.isLiquidityPool(address(pool)));

        // Now add the pool to the factory
        uniV3Factory.setPool(address(token), address(pairToken), 500, address(pool));

        // Transfer again: still cached as non-pool, so no detection
        vm.prank(owner);
        token.transfer(address(pool), 100 ether);
        assertFalse(token.isLiquidityPool(address(pool)));

        // Reset cache for this address
        vm.prank(owner);
        token.resetNonPoolCache(address(pool));

        // Now transfer should trigger auto-detection
        vm.prank(alice);
        token.transfer(address(pool), 100 ether);
        assertTrue(token.isLiquidityPool(address(pool)));
        assertTrue(token.isCLPool(address(pool)));
    }

    // ================================================================
    //               SECOND TRANSFER: No re-detection cost
    // ================================================================

    function test_secondTransfer_usesRegisteredPool() public {
        MockCLPool2 pool = new MockCLPool2();
        uniV3Factory.setPool(address(token), address(pairToken), 3000, address(pool));

        vm.prank(owner);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        token.addUniV3Factory(address(uniV3Factory), fees);

        // First sell: auto-detects
        uint256 sellAmount = 1000 ether;
        vm.prank(alice);
        token.transfer(address(pool), sellAmount);
        assertTrue(token.isLiquidityPool(address(pool)));

        // Second sell: already registered, should still work with CL tax
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(address(pool), sellAmount);

        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;
        assertEq(
            token.balanceOf(alice),
            aliceBefore - sellAmount - expectedTax,
            "second sell should also use CL tax mode"
        );
    }

    // ================================================================
    //               NO FACTORIES: Normal behavior
    // ================================================================

    function test_noFactories_normalTransfer() public {
        // Without any factories registered, transfers should work normally
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 amount = 100 ether;

        vm.prank(alice);
        token.transfer(bob, amount);

        // No tax (not a pool transfer)
        assertEq(token.balanceOf(alice), aliceBefore - amount);
    }

    // ================================================================
    //        MULTIPLE FACTORIES: Detection across all
    // ================================================================

    function test_multipleFactories_detectsCorrectOne() public {
        MockCLPool2 uniPool = new MockCLPool2();
        MockCLPool2 slipPool = new MockCLPool2();
        MockCLPool2 v2Pool = new MockCLPool2();

        // Set up pools in different factories
        uniV3Factory.setPool(address(token), address(pairToken), 3000, address(uniPool));
        slipstreamFactory.setPool(address(token), address(pairToken), 100, address(slipPool));
        aeroV2Factory.setPool(address(token), address(pairToken), false, address(v2Pool));

        vm.startPrank(owner);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        token.addUniV3Factory(address(uniV3Factory), fees);

        int24[] memory spacings = new int24[](1);
        spacings[0] = 100;
        token.addSlipstreamFactory(address(slipstreamFactory), spacings);

        token.addV2Factory(address(aeroV2Factory));
        vm.stopPrank();

        // Transfer to UniV3 pool
        vm.prank(alice);
        token.transfer(address(uniPool), 100 ether);
        assertTrue(token.isCLPool(address(uniPool)));

        // Transfer to Slipstream pool
        vm.prank(alice);
        token.transfer(address(slipPool), 100 ether);
        assertTrue(token.isCLPool(address(slipPool)));

        // Transfer to V2 pool
        vm.prank(alice);
        token.transfer(address(v2Pool), 100 ether);
        assertTrue(token.isLiquidityPool(address(v2Pool)));
        assertFalse(token.isCLPool(address(v2Pool))); // V2, not CL
    }

    // ================================================================
    //        FACTORY EXTERNAL CALL FAILURE: Graceful handling
    // ================================================================

    function test_factoryReverts_transferStillWorks() public {
        // Register a factory address that will revert on getPool
        // Use a contract that doesn't implement getPool properly
        MockCLPool2 fakeFactory = new MockCLPool2(); // doesn't have getPool

        vm.prank(owner);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        token.addUniV3Factory(address(fakeFactory), fees); // will revert on call

        // Transfer should still work (try/catch handles the revert)
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(token.balanceOf(alice), aliceBefore - 100 ether);
    }

    // ================================================================
    //        MANUALLY REGISTERED POOL: No double-detection
    // ================================================================

    function test_manuallyRegistered_noAutoDetect() public {
        MockCLPool2 pool = new MockCLPool2();

        // Manually register
        vm.prank(owner);
        token.addCLPool(address(pool));

        // Also register in factory
        uniV3Factory.setPool(address(token), address(pairToken), 3000, address(pool));

        vm.prank(owner);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        token.addUniV3Factory(address(uniV3Factory), fees);

        // Transfer should work without triggering auto-detection (already registered)
        uint256 sellAmount = 1000 ether;
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        token.transfer(address(pool), sellAmount);

        // CL tax mode
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;
        assertEq(token.balanceOf(alice), aliceBefore - sellAmount - expectedTax);
        assertEq(token.balanceOf(address(pool)), sellAmount);
    }
}
