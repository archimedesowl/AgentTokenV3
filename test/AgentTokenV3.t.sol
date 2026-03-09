// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentTokenV3.sol";
import "../src/interfaces/IAgentTokenV3.sol";
import "../src/interfaces/IERC20Config.sol";
import "../src/interfaces/IUniswapV2Router02.sol";
import "../src/interfaces/IUniswapV2Factory.sol";
import "../src/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
// ============================================================
//  MINIMAL PROXY (avoids OZ ERC1967Proxy which needs solc ^0.8.21)
// ============================================================

/// @dev Bare-bones delegatecall proxy — no upgrade logic needed for tests.
contract MinimalProxy {
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

/// @dev Minimal mock ERC20 used as the pair token ($VIRTUAL stand-in)
contract MockPairToken is ERC20 {
    constructor() ERC20("Virtual", "VIRTUAL") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Minimal V2 pair mock – just holds LP tokens, mints to sender
contract MockPair {
    address public token0;
    address public token1;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address _t0, address _t1) {
        token0 = _t0;
        token1 = _t1;
    }

    function mint(address to) external returns (uint256 liquidity) {
        liquidity = 1000 ether; // arbitrary LP amount
        balanceOf[to] += liquidity;
        totalSupply += liquidity;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal V2 factory mock – creates/returns pairs
contract MockFactory {
    mapping(bytes32 => address) private _pairs;

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return _pairs[_key(tokenA, tokenB)];
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        pair = address(new MockPair(tokenA, tokenB));
        _pairs[_key(tokenA, tokenB)] = pair;
        _pairs[_key(tokenB, tokenA)] = pair;
    }

    function _key(address a, address b) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }
}

/// @dev Minimal V2 router mock – records swap calls, returns factory address
contract MockRouter {
    address public immutable factoryAddr;

    constructor(address factory_) {
        factoryAddr = factory_;
    }

    function factory() external view returns (address) {
        return factoryAddr;
    }

    // no-op for swaps (we test tax accounting, not actual swaps)
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
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

/// @dev Simulates a CL pool. When receiving tokens via transfer, it checks
/// balanceBefore + expectedAmount <= balanceAfter (the real CL invariant).
contract MockCLPool {
    uint256 public pendingExpectedAmount;

    /// @dev Called by the test to set up a pending trade expectation
    function expectTransfer(uint256 amount) external {
        pendingExpectedAmount = amount;
    }

    /// @dev Mimics the CL pool's balance check on callback settlement.
    function verifyBalanceCheck(address tokenAddr, uint256 balanceBefore) external view returns (bool) {
        uint256 balanceAfter = IERC20(tokenAddr).balanceOf(address(this));
        return balanceBefore + pendingExpectedAmount <= balanceAfter;
    }
}

// ============================================================
//  TEST CONTRACT
// ============================================================

contract AgentTokenV3Test is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event LiquidityPoolAdded(address addedPool);
    event CLPoolAdded(address indexed pool);

    AgentTokenV3 public token;
    MockPairToken public pairToken;
    MockFactory public mockFactory;
    MockRouter public mockRouter;
    MockCLPool public clPool;

    address public owner = address(0xAA);
    address public alice = address(0xBB);
    address public bob = address(0xCC);
    address public taxRecipient = address(0xDD);

    // Tax: 1% buy, 1% sell (100 basis points each) — same as current Virtuals
    uint16 constant BUY_TAX_BP = 100;
    uint16 constant SELL_TAX_BP = 100;
    uint16 constant SWAP_THRESHOLD_BP = 10; // 0.1% autoswap threshold

    uint256 constant MAX_SUPPLY = 1_000_000_000;
    uint256 constant LP_SUPPLY = 800_000_000;
    uint256 constant VAULT_SUPPLY = 200_000_000;

    function setUp() public {
        // Deploy mocks
        pairToken = new MockPairToken();
        mockFactory = new MockFactory();
        mockRouter = new MockRouter(address(mockFactory));
        clPool = new MockCLPool();

        // Deploy implementation
        AgentTokenV3 impl = new AgentTokenV3();

        // Build initialization calldata
        address[3] memory integrationAddresses = [
            owner,                      // project owner
            address(mockRouter),        // uniswap router
            address(pairToken)          // pair token ($VIRTUAL)
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

        // Deploy proxy pointing to implementation, calling initialize
        MinimalProxy proxy = new MinimalProxy(address(impl), initData);
        token = AgentTokenV3(payable(address(proxy)));

        // Fund pair token to the token contract so addInitialLiquidity works
        pairToken.mint(address(token), 100_000 ether);

        // Add initial liquidity (as owner)
        vm.prank(owner);
        token.addInitialLiquidity(owner);

        // Distribute tokens to test accounts
        // After addInitialLiquidity, vault (owner) has VAULT_SUPPLY
        vm.startPrank(owner);
        token.transfer(alice, 10_000_000 ether);
        token.transfer(bob, 10_000_000 ether);
        vm.stopPrank();
    }

    // ================================================================
    //                    BASIC TOKEN PROPERTIES
    // ================================================================

    function test_name() public view {
        assertEq(token.name(), "TestAgent");
    }

    function test_symbol() public view {
        assertEq(token.symbol(), "AGENT");
    }

    function test_decimals() public view {
        assertEq(token.decimals(), 18);
    }

    function test_totalSupply() public view {
        assertEq(token.totalSupply(), MAX_SUPPLY * 1e18);
    }

    function test_taxRates() public view {
        assertEq(token.projectBuyTaxBasisPoints(), BUY_TAX_BP);
        assertEq(token.projectSellTaxBasisPoints(), SELL_TAX_BP);
        assertEq(token.totalBuyTaxBasisPoints(), BUY_TAX_BP);
        assertEq(token.totalSellTaxBasisPoints(), SELL_TAX_BP);
    }

    // ================================================================
    //                 REGULAR TRANSFER (NO TAX)
    // ================================================================

    function test_transfer_noTax_betweenUsers() public {
        uint256 amount = 1000 ether;
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(alice), aliceBefore - amount, "alice balance wrong");
        assertEq(token.balanceOf(bob), bobBefore + amount, "bob balance wrong");
    }

    function test_transferFrom_withApproval() public {
        uint256 amount = 500 ether;
        vm.prank(alice);
        token.approve(bob, amount);

        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(bob);
        token.transferFrom(alice, bob, amount);

        assertEq(token.balanceOf(alice), aliceBefore - amount);
    }

    // ================================================================
    //               V2 POOL SELL — ORIGINAL TAX BEHAVIOR
    // ================================================================

    function test_v2Sell_taxDeductedFromDelivery() public {
        address v2Pool = token.uniswapV2Pair();
        uint256 sellAmount = 1000 ether;
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000; // 1% = 10 ether
        uint256 expectedDelivered = sellAmount - expectedTax;

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 poolBefore = token.balanceOf(v2Pool);
        uint256 contractBefore = token.balanceOf(address(token));

        vm.prank(alice);
        token.transfer(v2Pool, sellAmount);

        assertEq(token.balanceOf(alice), aliceBefore - sellAmount, "alice should lose full amount");
        assertEq(token.balanceOf(v2Pool), poolBefore + expectedDelivered, "pool should get amount minus tax");
        assertEq(token.balanceOf(address(token)), contractBefore + expectedTax, "contract should hold tax");
    }

    // ================================================================
    //           CL POOL SELL — "DEBIT-FROM-SENDER" TAX
    // ================================================================

    function test_clSell_fullAmountDeliveredToPool() public {
        // Register CL pool
        vm.prank(owner);
        token.addCLPool(address(clPool));

        uint256 sellAmount = 1000 ether;
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000; // 10 ether
        uint256 totalDebit = sellAmount + expectedTax; // 1010 ether

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 poolBefore = token.balanceOf(address(clPool));
        uint256 contractBefore = token.balanceOf(address(token));

        // Record balance before for CL invariant check
        clPool.expectTransfer(sellAmount);

        vm.prank(alice);
        token.transfer(address(clPool), sellAmount);

        // CL Pool gets FULL amount (no tax deducted from delivery)
        assertEq(token.balanceOf(address(clPool)), poolBefore + sellAmount, "CL pool must get full amount");
        // Alice loses amount + tax
        assertEq(token.balanceOf(alice), aliceBefore - totalDebit, "alice must lose amount + tax");
        // Tax contract accumulates tax
        assertEq(token.balanceOf(address(token)), contractBefore + expectedTax, "contract must hold tax");

        // Verify the CL pool balance invariant: balanceBefore + expectedAmount <= balanceAfter
        bool invariantOk = clPool.verifyBalanceCheck(address(token), poolBefore);
        assertTrue(invariantOk, "CL pool balance invariant MUST hold");
    }

    function test_clSell_taxEmitEvents() public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        uint256 sellAmount = 1000 ether;
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;

        vm.prank(alice);
        // Expect Transfer event for tax (from alice to contract)
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(token), expectedTax);
        // Expect Transfer event for the transfer itself (from alice to pool)
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(clPool), sellAmount);

        token.transfer(address(clPool), sellAmount);
    }

    function test_clSell_insufficientBalanceReverts() public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        // Alice has 10M tokens. If she sells 10M, the 1% tax (100K)
        // would need total of 10.1M — which she doesn't have.
        uint256 aliceBalance = token.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(AgentTokenV3.InsufficientBalanceForCLTax.selector);
        token.transfer(address(clPool), aliceBalance);
    }

    function test_clSell_maxSellAmount() public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        // Calculate max sellable amount: amount * (1 + tax/10000) <= balance
        // amount <= balance * 10000 / (10000 + tax)
        uint256 aliceBalance = token.balanceOf(alice);
        uint256 maxSellAmount = (aliceBalance * 10000) / (10000 + SELL_TAX_BP);
        uint256 tax = (maxSellAmount * SELL_TAX_BP) / 10000;

        // Ensure this fits
        assertTrue(maxSellAmount + tax <= aliceBalance, "math check");

        vm.prank(alice);
        token.transfer(address(clPool), maxSellAmount);

        // Alice should have close to zero left
        uint256 remaining = token.balanceOf(alice);
        assertTrue(remaining < 1 ether, "alice should have dust at most");
    }

    // ================================================================
    //                    BUY TAX (SAME FOR ALL POOLS)
    // ================================================================

    function test_v2Buy_taxDeductedFromDelivery() public {
        address v2Pool = token.uniswapV2Pair();

        // First, give the pool some tokens to "sell" to buyer
        vm.prank(alice);
        token.transfer(v2Pool, 5000 ether); // this itself has sell tax, but pool gets tokens

        uint256 buyAmount = 1000 ether;
        uint256 expectedTax = (buyAmount * BUY_TAX_BP) / 10000;
        uint256 expectedReceived = buyAmount - expectedTax;

        uint256 bobBefore = token.balanceOf(bob);

        // Pool sends tokens to bob (simulating a buy)
        vm.prank(v2Pool);
        token.transfer(bob, buyAmount);

        assertEq(token.balanceOf(bob), bobBefore + expectedReceived, "bob should get amount minus buy tax");
    }

    function test_clBuy_taxDeductedFromDelivery() public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        // Give CL pool tokens by dealing directly
        deal(address(token), address(clPool), 100_000 ether);

        uint256 buyAmount = 1000 ether;
        uint256 expectedTax = (buyAmount * BUY_TAX_BP) / 10000;
        uint256 expectedReceived = buyAmount - expectedTax;

        uint256 bobBefore = token.balanceOf(bob);
        uint256 contractBefore = token.balanceOf(address(token));

        // CL pool sends tokens to bob (simulating a buy)
        vm.prank(address(clPool));
        token.transfer(bob, buyAmount);

        assertEq(token.balanceOf(bob), bobBefore + expectedReceived, "bob should get amount minus buy tax");
        assertEq(token.balanceOf(address(token)), contractBefore + expectedTax, "contract should accumulate buy tax");
    }

    // ================================================================
    //              CL POOL MANAGEMENT
    // ================================================================

    function test_addCLPool_success() public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        assertTrue(token.isCLPool(address(clPool)), "should be CL pool");
        assertTrue(token.isLiquidityPool(address(clPool)), "should also be LP");

        address[] memory pools = token.clPools();
        assertEq(pools.length, 1);
        assertEq(pools[0], address(clPool));
    }

    function test_addCLPool_emitsEvents() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit LiquidityPoolAdded(address(clPool));
        vm.expectEmit(true, false, false, false);
        emit CLPoolAdded(address(clPool));
        token.addCLPool(address(clPool));
    }

    function test_addCLPool_revertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(AgentTokenV3.CLPoolCannotBeAddressZero.selector);
        token.addCLPool(address(0));
    }

    function test_addCLPool_revertsNonContract() public {
        vm.prank(owner);
        vm.expectRevert(AgentTokenV3.CLPoolMustBeAContractAddress.selector);
        token.addCLPool(address(0x1234)); // EOA
    }

    function test_addCLPool_revertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(); // CallerIsNotAdminNorFactory
        token.addCLPool(address(clPool));
    }

    function test_removeCLPool() public {
        vm.startPrank(owner);
        token.addCLPool(address(clPool));
        assertTrue(token.isCLPool(address(clPool)));

        token.removeCLPool(address(clPool));
        assertFalse(token.isCLPool(address(clPool)), "should be removed from CL set");
        assertFalse(token.isLiquidityPool(address(clPool)), "should be removed from LP set too");
        vm.stopPrank();
    }

    function test_removeCLPool_sellBehavesAsNonPool() public {
        // Add then remove CL pool -> transfers to it should NOT be taxed
        vm.startPrank(owner);
        token.addCLPool(address(clPool));
        token.removeCLPool(address(clPool));
        vm.stopPrank();

        uint256 amount = 1000 ether;
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 poolBefore = token.balanceOf(address(clPool));

        // Transfer to former CL pool — should be a plain transfer (no tax)
        vm.prank(alice);
        token.transfer(address(clPool), amount);

        assertEq(token.balanceOf(alice), aliceBefore - amount, "alice loses exact amount");
        assertEq(token.balanceOf(address(clPool)), poolBefore + amount, "pool gets exact amount");
    }

    // ================================================================
    //              MULTIPLE CL POOLS
    // ================================================================

    function test_multipleCLPools() public {
        MockCLPool clPool2 = new MockCLPool();

        vm.startPrank(owner);
        token.addCLPool(address(clPool));
        token.addCLPool(address(clPool2));
        vm.stopPrank();

        address[] memory pools = token.clPools();
        assertEq(pools.length, 2);

        assertTrue(token.isCLPool(address(clPool)));
        assertTrue(token.isCLPool(address(clPool2)));

        // Sell to each pool — both should use CL tax model
        uint256 sellAmount = 1000 ether;

        // Sell to clPool
        uint256 pool1Before = token.balanceOf(address(clPool));
        vm.prank(alice);
        token.transfer(address(clPool), sellAmount);
        assertEq(token.balanceOf(address(clPool)), pool1Before + sellAmount, "clPool gets full amount");

        // Sell to clPool2
        uint256 pool2Before = token.balanceOf(address(clPool2));
        vm.prank(alice);
        token.transfer(address(clPool2), sellAmount);
        assertEq(token.balanceOf(address(clPool2)), pool2Before + sellAmount, "clPool2 gets full amount");
    }

    // ================================================================
    //              ZERO TAX SCENARIOS
    // ================================================================

    function test_clSell_zeroTax_noExtraDebit() public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        // Set tax to zero
        vm.prank(owner);
        token.setProjectTaxRates(0, 0);

        uint256 sellAmount = 1000 ether;
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        token.transfer(address(clPool), sellAmount);

        // Zero tax: isCLSell check requires totalSellTaxBasisPoints() > 0
        // Falls through to normal V2 path which also has zero tax
        assertEq(token.balanceOf(alice), aliceBefore - sellAmount, "alice loses only amount");
        assertEq(token.balanceOf(address(clPool)), sellAmount, "pool gets exact amount");
    }

    // ================================================================
    //              TAX CONFIGURATION
    // ================================================================

    function test_setProjectTaxRates() public {
        vm.prank(owner);
        token.setProjectTaxRates(200, 300); // 2% buy, 3% sell

        assertEq(token.projectBuyTaxBasisPoints(), 200);
        assertEq(token.projectSellTaxBasisPoints(), 300);
    }

    function test_setProjectTaxRecipient() public {
        address newRecipient = address(0xEE);
        vm.prank(owner);
        token.setProjectTaxRecipient(newRecipient);
        assertEq(token.projectTaxRecipient(), newRecipient);
    }

    function test_setSwapThreshold() public {
        vm.prank(owner);
        token.setSwapThresholdBasisPoints(50);
        assertEq(token.swapThresholdBasisPoints(), 50);
    }

    // ================================================================
    //              BLACKLIST (from V2)
    // ================================================================

    function test_blacklist_preventsTransferTo() public {
        vm.prank(owner);
        token.addBlacklistAddress(bob);

        vm.prank(alice);
        vm.expectRevert(); // TransferToBlacklistedAddress
        token.transfer(bob, 100 ether);
    }

    function test_blacklist_removeAllowsTransfer() public {
        vm.prank(owner);
        token.addBlacklistAddress(bob);

        vm.prank(owner);
        token.removeBlacklistAddress(bob);

        vm.prank(alice);
        token.transfer(bob, 100 ether); // should succeed
    }

    // ================================================================
    //              ALLOWANCE FUNCTIONS
    // ================================================================

    function test_increaseAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100 ether);
        assertEq(token.allowance(alice, bob), 100 ether);

        vm.prank(alice);
        token.increaseAllowance(bob, 50 ether);
        assertEq(token.allowance(alice, bob), 150 ether);
    }

    function test_decreaseAllowance() public {
        vm.prank(alice);
        token.approve(bob, 100 ether);

        vm.prank(alice);
        token.decreaseAllowance(bob, 40 ether);
        assertEq(token.allowance(alice, bob), 60 ether);
    }

    function test_decreaseAllowance_belowZeroReverts() public {
        vm.prank(alice);
        token.approve(bob, 50 ether);

        vm.prank(alice);
        vm.expectRevert(); // AllowanceDecreasedBelowZero
        token.decreaseAllowance(bob, 60 ether);
    }

    // ================================================================
    //              BURN
    // ================================================================

    function test_burn() public {
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        token.burn(100 ether);

        assertEq(token.balanceOf(alice), aliceBefore - 100 ether);
        assertEq(token.totalSupply(), supplyBefore - 100 ether);
    }

    function test_burnFrom() public {
        vm.prank(alice);
        token.approve(bob, 100 ether);

        vm.prank(bob);
        token.burnFrom(alice, 100 ether);

        assertEq(token.allowance(alice, bob), 0);
    }

    // ================================================================
    //              VALID CALLER MANAGEMENT
    // ================================================================

    function test_validCallerManagement() public {
        bytes32 hash = keccak256("test");

        vm.prank(owner);
        token.addValidCaller(hash);
        assertTrue(token.isValidCaller(hash));

        bytes32[] memory callers = token.validCallers();
        assertEq(callers.length, 1);

        vm.prank(owner);
        token.removeValidCaller(hash);
        assertFalse(token.isValidCaller(hash));
    }

    // ================================================================
    //              LP POOL MANAGEMENT
    // ================================================================

    function test_addLiquidityPool() public {
        address newPool = address(new MockCLPool()); // just any contract
        vm.prank(owner);
        token.addLiquidityPool(newPool);
        assertTrue(token.isLiquidityPool(newPool));
    }

    function test_removeLiquidityPool() public {
        address newPool = address(new MockCLPool());
        vm.startPrank(owner);
        token.addLiquidityPool(newPool);
        token.removeLiquidityPool(newPool);
        vm.stopPrank();
        assertFalse(token.isLiquidityPool(newPool));
    }

    // ================================================================
    //              WITHDRAW FUNCTIONS
    // ================================================================

    function test_withdrawETH() public {
        vm.deal(address(token), 1 ether);
        uint256 ownerBefore = owner.balance;

        vm.prank(owner);
        token.withdrawETH(1 ether);

        assertEq(owner.balance, ownerBefore + 1 ether);
    }

    function test_withdrawERC20() public {
        MockPairToken other = new MockPairToken();
        other.mint(address(token), 100 ether);

        vm.prank(owner);
        token.withdrawERC20(address(other), 100 ether);

        assertEq(other.balanceOf(owner), 100 ether);
    }

    function test_withdrawERC20_cannotWithdrawSelf() public {
        vm.prank(owner);
        vm.expectRevert(); // CannotWithdrawThisToken
        token.withdrawERC20(address(token), 1 ether);
    }

    // ================================================================
    //            CL SELL VIA transferFrom (router pattern)
    // ================================================================

    function test_clSell_viaTransferFrom() public {
        // In V3 swaps, the router calls transferFrom(sender, pool, amount)
        vm.prank(owner);
        token.addCLPool(address(clPool));

        address router = address(0x999);
        uint256 sellAmount = 1000 ether;
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;

        vm.prank(alice);
        token.approve(router, type(uint256).max);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 poolBefore = token.balanceOf(address(clPool));

        // Router calls transferFrom on behalf of alice
        vm.prank(router);
        token.transferFrom(alice, address(clPool), sellAmount);

        // CL pool gets full amount, alice debited amount + tax
        assertEq(token.balanceOf(address(clPool)), poolBefore + sellAmount, "pool gets full amount");
        assertEq(token.balanceOf(alice), aliceBefore - sellAmount - expectedTax, "alice debited amount + tax");
    }

    // ================================================================
    //       TAX ACCOUNTING ACCUMULATES CORRECTLY
    // ================================================================

    function test_taxAccumulates_multipleClSells() public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        uint256 sellAmount = 1000 ether;
        uint256 expectedTaxPerSell = (sellAmount * SELL_TAX_BP) / 10000;

        uint256 contractBefore = token.balanceOf(address(token));

        // Three sells
        vm.startPrank(alice);
        token.transfer(address(clPool), sellAmount);
        token.transfer(address(clPool), sellAmount);
        token.transfer(address(clPool), sellAmount);
        vm.stopPrank();

        uint256 totalTax = token.balanceOf(address(token)) - contractBefore;
        assertEq(totalTax, expectedTaxPerSell * 3, "tax should accumulate correctly");
    }

    function test_projectTaxPendingSwap_accumulatesOnClSell() public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        uint256 sellAmount = 1000 ether;
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;

        uint128 pendingBefore = token.projectTaxPendingSwap();

        vm.prank(alice);
        token.transfer(address(clPool), sellAmount);

        assertEq(
            token.projectTaxPendingSwap(),
            pendingBefore + uint128(expectedTax),
            "pending swap should track CL tax"
        );
    }

    // ================================================================
    //         COMPARISON: SAME AMOUNT, V2 vs CL SELL
    // ================================================================

    function test_v2VsCl_sameSellAmount_differentBehavior() public {
        address v2Pool = token.uniswapV2Pair();
        vm.prank(owner);
        token.addCLPool(address(clPool));

        uint256 sellAmount = 1000 ether;
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;

        // V2 sell: pool gets amount - tax, alice loses amount
        uint256 v2PoolBefore = token.balanceOf(v2Pool);
        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(alice);
        token.transfer(v2Pool, sellAmount);

        uint256 v2PoolReceived = token.balanceOf(v2Pool) - v2PoolBefore;
        uint256 aliceV2Loss = aliceBefore - token.balanceOf(alice);

        assertEq(v2PoolReceived, sellAmount - expectedTax, "V2 pool gets amount - tax");
        assertEq(aliceV2Loss, sellAmount, "V2 alice loses exact amount");

        // CL sell: pool gets full amount, bob loses amount + tax
        uint256 clPoolBefore = token.balanceOf(address(clPool));
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(bob);
        token.transfer(address(clPool), sellAmount);

        uint256 clPoolReceived = token.balanceOf(address(clPool)) - clPoolBefore;
        uint256 bobCLLoss = bobBefore - token.balanceOf(bob);

        assertEq(clPoolReceived, sellAmount, "CL pool gets full amount");
        assertEq(bobCLLoss, sellAmount + expectedTax, "CL bob loses amount + tax");
    }

    // ================================================================
    //              DISTRIBUTE TAX TOKENS
    // ================================================================

    function test_distributeTaxTokens() public {
        // Create some pending tax via CL sell
        vm.prank(owner);
        token.addCLPool(address(clPool));

        vm.prank(alice);
        token.transfer(address(clPool), 10000 ether);

        uint128 pending = token.projectTaxPendingSwap();
        assertTrue(pending > 0, "should have pending tax");

        uint256 recipientBefore = token.balanceOf(taxRecipient);

        // Distribute — [L-07] now requires owner
        vm.prank(owner);
        token.distributeTaxTokens();

        assertEq(token.projectTaxPendingSwap(), 0, "pending should be zero");
        assertEq(token.balanceOf(taxRecipient), recipientBefore + pending, "recipient should get tax tokens");
    }

    // ================================================================
    //           INITIALIZER CANNOT BE CALLED TWICE
    // ================================================================

    function test_initialize_cannotCallTwice() public {
        address[3] memory addrs = [owner, address(mockRouter), address(pairToken)];
        bytes memory baseParams = abi.encode("X", "X");
        bytes memory supplyParams = abi.encode(
            IERC20Config.ERC20SupplyParameters({
                maxSupply: 100, lpSupply: 50, vaultSupply: 50,
                maxTokensPerWallet: 0, maxTokensPerTxn: 0,
                botProtectionDurationInSeconds: 0, vault: owner
            })
        );
        bytes memory taxParams = abi.encode(
            IERC20Config.ERC20TaxParameters({
                projectBuyTaxBasisPoints: 0, projectSellTaxBasisPoints: 0,
                taxSwapThresholdBasisPoints: 0, projectTaxRecipient: owner
            })
        );

        vm.expectRevert(); // InvalidInitialization
        token.initialize(addrs, baseParams, supplyParams, taxParams);
    }

    // ================================================================
    //        AUTOSWAP DOES NOT BREAK CL SELL
    // ================================================================

    function test_autoSwap_doesNotBreakCLSell() public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        // Set threshold very high so autoswap doesn't trigger
        vm.prank(owner);
        token.setSwapThresholdBasisPoints(10000);

        // CL sell should work fine
        uint256 sellAmount = 1000 ether;
        vm.prank(alice);
        token.transfer(address(clPool), sellAmount);

        assertEq(token.balanceOf(address(clPool)), sellAmount);
    }

    // ================================================================
    //  CL POOL ADDED AS LP BUT NOT CL → USES V2 TAX MODEL
    // ================================================================

    function test_lpOnlyPool_usesV2TaxModel() public {
        // If a pool is added as a regular LP pool (not CL), the V2 tax model applies
        MockCLPool regularPool = new MockCLPool();
        vm.prank(owner);
        token.addLiquidityPool(address(regularPool));

        // NOT added as CL pool
        assertFalse(token.isCLPool(address(regularPool)));
        assertTrue(token.isLiquidityPool(address(regularPool)));

        uint256 sellAmount = 1000 ether;
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;

        uint256 poolBefore = token.balanceOf(address(regularPool));
        vm.prank(alice);
        token.transfer(address(regularPool), sellAmount);

        // V2 model: pool gets amount - tax
        assertEq(
            token.balanceOf(address(regularPool)),
            poolBefore + sellAmount - expectedTax,
            "regular LP should use V2 tax model"
        );
    }

    // ================================================================
    //  FUZZ: CL sell tax math is always consistent
    // ================================================================

    function testFuzz_clSell_taxMath(uint256 sellAmount) public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        uint256 aliceBalance = token.balanceOf(alice);
        // Max sell: balance * 10000 / (10000 + SELL_TAX_BP)
        uint256 maxSell = (aliceBalance * 10000) / (10000 + SELL_TAX_BP);

        // Bound to reasonable amounts (at least 1 token, at most max sellable)
        sellAmount = bound(sellAmount, 1 ether, maxSell);

        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;
        uint256 totalDebit = sellAmount + expectedTax;

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 contractBefore = token.balanceOf(address(token));

        vm.prank(alice);
        token.transfer(address(clPool), sellAmount);

        assertEq(token.balanceOf(alice), aliceBefore - totalDebit, "fuzz: alice balance");
        assertEq(token.balanceOf(address(clPool)), sellAmount, "fuzz: pool balance");
        assertEq(token.balanceOf(address(token)), contractBefore + expectedTax, "fuzz: contract balance");
    }
}
