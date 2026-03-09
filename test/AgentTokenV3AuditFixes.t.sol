// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentTokenV3.sol";
import "../src/interfaces/IERC20Config.sol";
import "../src/interfaces/IErrors.sol";

// =========================================================================
//                    MINIMAL PROXY (same as main test)
// =========================================================================

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

// =========================================================================
//                    MOCK CONTRACTS
// =========================================================================

contract MockPairTokenAF {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address, uint256) external pure returns (bool) { return true; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract MockFactoryAF {
    mapping(address => mapping(address => address)) public _pairs;

    function getPair(address a, address b) external view returns (address) {
        return _pairs[a][b];
    }

    function createPair(address a, address b) external returns (address) {
        address pair = address(new MockPairLP());
        _pairs[a][b] = pair;
        _pairs[b][a] = pair;
        return pair;
    }
}

contract MockRouterAF {
    address public immutable factAddr;

    constructor(address f) { factAddr = f; }

    function factory() external view returns (address) { return factAddr; }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint, uint, address[] calldata, address, uint
    ) external {}

    function getAmountsOut(uint amountIn, address[] calldata path) external pure returns (uint[] memory amounts) {
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        amounts[1] = amountIn / 2;
    }
}

contract MockPairLP {
    function mint(address) external pure returns (uint256) { return 1000; }
    function transfer(address, uint256) external pure returns (bool) { return true; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
}

contract MockCLPoolAF {
    // Just a contract address that can receive tokens
}

/// @dev Factory mock for auto-detection
contract MockCLFactoryAF {
    mapping(bytes32 => address) public pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[keccak256(abi.encode(tokenA, tokenB, fee))] = pool;
        pools[keccak256(abi.encode(tokenB, tokenA, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(tokenA, tokenB, fee))];
    }
}

/// @dev Malicious factory that returns arbitrary addresses
contract MaliciousFactoryAF {
    address public returnAddress;

    function setReturnAddress(address addr) external {
        returnAddress = addr;
    }

    function getPool(address, address, uint24) external view returns (address) {
        return returnAddress;
    }
}

// =========================================================================
//                    AUDIT FIX TESTS
// =========================================================================

contract AgentTokenV3AuditFixesTest is Test {
    AgentTokenV3 public token;
    MockRouterAF public mockRouter;
    MockFactoryAF public mockFactory;
    MockPairTokenAF public pairToken;
    MockCLPoolAF public clPool;

    address public owner = address(0xABCD);
    address public alice = address(0x1111);
    address public bob = address(0x2222);
    address public taxRecipient = address(0x3333);

    uint256 constant MAX_SUPPLY = 100_000_000;
    uint256 constant LP_SUPPLY = 50_000_000;
    uint256 constant VAULT_SUPPLY = 50_000_000;
    uint256 constant BUY_TAX_BP = 100;
    uint256 constant SELL_TAX_BP = 100;
    uint256 constant SWAP_THRESHOLD_BP = 10;

    function setUp() public {
        pairToken = new MockPairTokenAF();
        mockFactory = new MockFactoryAF();
        mockRouter = new MockRouterAF(address(mockFactory));
        clPool = new MockCLPoolAF();

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
        token.transfer(bob, 5_000_000 ether);
        vm.stopPrank();
    }

    // ================================================================
    //     H-01 + M-01: Tax rate cap at MAX_TAX_BP (1000 BPS = 10%)
    // ================================================================

    function test_H01_setTaxRates_revertsAboveMaxBP_buy() public {
        // M-01: MAX_TAX_BP = 1000 (10%), so 1001 should revert
        vm.prank(owner);
        vm.expectRevert(AgentTokenV3.TaxRateExceedsMaximum.selector);
        token.setProjectTaxRates(1001, 100);
    }

    function test_H01_setTaxRates_revertsAboveMaxBP_sell() public {
        vm.prank(owner);
        vm.expectRevert(AgentTokenV3.TaxRateExceedsMaximum.selector);
        token.setProjectTaxRates(100, 1001);
    }

    function test_H01_setTaxRates_maxAllowed() public {
        // M-01 fix caps tax at MAX_TAX_BP (1000 = 10%)
        vm.prank(owner);
        token.setProjectTaxRates(1000, 1000);
        assertEq(token.projectBuyTaxBasisPoints(), 1000);
        assertEq(token.projectSellTaxBasisPoints(), 1000);
    }

    function test_H01_setTaxRates_aboveMaxReverts() public {
        // Anything above 1000 BP should revert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("TaxRateExceedsMaximum()"));
        token.setProjectTaxRates(1001, 500);
    }

    function test_H01_setTaxRates_normalRatesWork() public {
        vm.prank(owner);
        token.setProjectTaxRates(500, 500);
        assertEq(token.projectBuyTaxBasisPoints(), 500);
        assertEq(token.projectSellTaxBasisPoints(), 500);
    }

    // ================================================================
    //     H-02 / M-06: CEI Fix + ReentrancyGuard
    // ================================================================

    function test_H02_transfer_worksNormally() public {
        uint256 amount = 1000 ether;
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(bob), bobBefore + amount);
    }

    function test_H02_transferFrom_worksNormally() public {
        uint256 amount = 1000 ether;
        vm.prank(alice);
        token.approve(bob, amount);
        vm.prank(bob);
        token.transferFrom(alice, bob, amount);
    }

    // ================================================================
    //     H-03 / M-10: Factory array caps
    // ================================================================

    function test_H03_addCLFactory_respectsMax() public {
        vm.startPrank(owner);

        for (uint256 i = 0; i < 5; i++) {
            MockCLFactoryAF f = new MockCLFactoryAF();
            uint24[] memory fees = new uint24[](1);
            fees[0] = uint24(500 + i);
            token.addUniV3Factory(address(f), fees);
        }

        MockCLFactoryAF extra = new MockCLFactoryAF();
        uint24[] memory extraFees = new uint24[](1);
        extraFees[0] = 999;
        vm.expectRevert(AgentTokenV3.MaxCLFactoriesReached.selector);
        token.addUniV3Factory(address(extra), extraFees);

        vm.stopPrank();
    }

    function test_H03_addV2Factory_respectsMax() public {
        vm.startPrank(owner);

        for (uint256 i = 0; i < 3; i++) {
            MockCLFactoryAF f = new MockCLFactoryAF();
            token.addV2Factory(address(f));
        }

        MockCLFactoryAF extra = new MockCLFactoryAF();
        vm.expectRevert(AgentTokenV3.MaxV2FactoriesReached.selector);
        token.addV2Factory(address(extra));

        vm.stopPrank();
    }

    function test_H03_tiersPerFactory_respectsMax() public {
        vm.startPrank(owner);

        uint24[] memory tooManyFees = new uint24[](9);
        for (uint256 i = 0; i < 9; i++) {
            tooManyFees[i] = uint24(100 * (i + 1));
        }
        MockCLFactoryAF f = new MockCLFactoryAF();
        vm.expectRevert(AgentTokenV3.MaxTiersPerFactoryReached.selector);
        token.addUniV3Factory(address(f), tooManyFees);

        uint24[] memory okFees = new uint24[](8);
        for (uint256 i = 0; i < 8; i++) {
            okFees[i] = uint24(100 * (i + 1));
        }
        token.addUniV3Factory(address(f), okFees);

        vm.stopPrank();
    }

    // ================================================================
    //     H-04: Sensitive operations are owner-only
    // ================================================================

    function test_H04_setProjectTaxRates_factoryCannot() public {
        // Test contract is the factory (it deployed the token)
        vm.expectRevert(AgentTokenV3.CallerIsNotOwner.selector);
        token.setProjectTaxRates(200, 200);
    }

    function test_H04_setProjectTaxRecipient_factoryCannot() public {
        vm.expectRevert(AgentTokenV3.CallerIsNotOwner.selector);
        token.setProjectTaxRecipient(alice);
    }

    function test_H04_withdrawETH_factoryCannot() public {
        vm.deal(address(token), 1 ether);
        vm.expectRevert(AgentTokenV3.CallerIsNotOwner.selector);
        token.withdrawETH(1 ether);
    }

    function test_H04_withdrawERC20_factoryCannot() public {
        vm.expectRevert(AgentTokenV3.CallerIsNotOwner.selector);
        token.withdrawERC20(address(pairToken), 1);
    }

    function test_H04_ownerCanStillSetTaxRates() public {
        vm.prank(owner);
        token.setProjectTaxRates(200, 300);
        assertEq(token.projectBuyTaxBasisPoints(), 200);
        assertEq(token.projectSellTaxBasisPoints(), 300);
    }

    function test_H04_factoryCanStillAddPools() public {
        // Factory (address(this)) can still do non-sensitive ops like addCLPool
        MockCLPoolAF newPool = new MockCLPoolAF();
        token.addCLPool(address(newPool));
        assertTrue(token.isCLPool(address(newPool)));
    }

    // ================================================================
    //     M-05: Factory getPool validation
    // ================================================================

    function test_M05_maliciousFactory_cannotRegisterTokenAsSelf() public {
        MaliciousFactoryAF malicious = new MaliciousFactoryAF();
        malicious.setReturnAddress(address(token));

        vm.startPrank(owner);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        token.addUniV3Factory(address(malicious), fees);
        vm.stopPrank();

        // Transfer to some contract — factory returns address(token) but validation blocks it
        MockCLPoolAF dummy = new MockCLPoolAF();
        vm.prank(alice);
        token.transfer(address(dummy), 100 ether);
        // address(token) should NOT be registered as pool
        assertFalse(token.isLiquidityPool(address(token)));
    }

    function test_M05_maliciousFactory_cannotRegisterTaxRecipient() public {
        MaliciousFactoryAF malicious = new MaliciousFactoryAF();
        malicious.setReturnAddress(taxRecipient);

        vm.startPrank(owner);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        token.addUniV3Factory(address(malicious), fees);
        vm.stopPrank();

        vm.prank(alice);
        token.transfer(taxRecipient, 100 ether);
        assertFalse(token.isLiquidityPool(taxRecipient));
    }

    // ================================================================
    //     M-07: renounceOwnership disabled
    // ================================================================

    function test_M07_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(AgentTokenV3.RenounceOwnershipDisabled.selector);
        token.renounceOwnership();
    }

    // ================================================================
    //     M-08: Blacklist blocks BOTH sending and receiving
    // ================================================================

    function test_M08_blacklist_blocksSending() public {
        vm.prank(owner);
        token.addBlacklistAddress(alice);

        vm.prank(alice);
        vm.expectRevert(AgentTokenV3.TransferFromBlacklistedAddress.selector);
        token.transfer(bob, 100 ether);
    }

    function test_M08_blacklist_stillBlocksReceiving() public {
        vm.prank(owner);
        token.addBlacklistAddress(bob);

        vm.prank(alice);
        vm.expectRevert(IErrors.TransferToBlacklistedAddress.selector);
        token.transfer(bob, 100 ether);
    }

    // ================================================================
    //     L-02: Swap threshold cannot be zero
    // ================================================================

    function test_L02_setSwapThreshold_revertsZero() public {
        vm.prank(owner);
        vm.expectRevert(AgentTokenV3.SwapThresholdCannotBeZero.selector);
        token.setSwapThresholdBasisPoints(0);
    }

    function test_L02_setSwapThreshold_nonZeroWorks() public {
        vm.prank(owner);
        token.setSwapThresholdBasisPoints(5);
        assertEq(token.swapThresholdBasisPoints(), 5);
    }

    // ================================================================
    //     L-06: resetNonPoolCache is owner-only
    // ================================================================

    function test_L06_resetNonPoolCache_factoryCannot() public {
        vm.expectRevert(AgentTokenV3.CallerIsNotOwner.selector);
        token.resetNonPoolCache(alice);
    }

    function test_L06_resetNonPoolCache_ownerCan() public {
        vm.prank(owner);
        token.resetNonPoolCache(alice);
    }

    // ================================================================
    //     L-07: distributeTaxTokens requires owner
    // ================================================================

    function test_L07_distributeTaxTokens_nonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentTokenV3.CallerIsNotOwner.selector);
        token.distributeTaxTokens();
    }

    function test_L07_distributeTaxTokens_ownerWorks() public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        vm.prank(alice);
        token.transfer(address(clPool), 10_000 ether);

        uint128 pending = token.projectTaxPendingSwap();
        assertTrue(pending > 0, "should have pending tax");

        vm.prank(owner);
        token.distributeTaxTokens();
        assertEq(token.projectTaxPendingSwap(), 0, "pending should be zero");
    }

    // ================================================================
    //     Regression: Core functionality intact
    // ================================================================

    function test_regression_clSell_stillWorks() public {
        vm.prank(owner);
        token.addCLPool(address(clPool));

        uint256 sellAmount = 1000 ether;
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;

        vm.prank(alice);
        token.transfer(address(clPool), sellAmount);

        assertEq(token.balanceOf(address(clPool)), sellAmount, "pool gets full amount");
        assertEq(token.projectTaxPendingSwap(), uint128(expectedTax), "tax accumulated");
    }

    function test_regression_v2Sell_stillWorks() public {
        MockCLPoolAF v2Pool = new MockCLPoolAF();
        vm.prank(owner);
        token.addLiquidityPool(address(v2Pool));

        uint256 sellAmount = 1000 ether;
        uint256 expectedTax = (sellAmount * SELL_TAX_BP) / 10000;

        vm.prank(alice);
        token.transfer(address(v2Pool), sellAmount);

        assertEq(token.balanceOf(address(v2Pool)), sellAmount - expectedTax, "pool gets amount minus tax");
    }

    function test_regression_normalTransfer_noTax() public {
        uint256 amount = 500 ether;
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.balanceOf(alice), aliceBefore - amount);
        assertEq(token.balanceOf(bob), bobBefore + amount);
    }

    function test_regression_burn_stillWorks() public {
        uint256 amount = 100 ether;
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        token.burn(amount);
        assertEq(token.balanceOf(alice), before - amount);
    }

    function test_regression_transferFrom_works() public {
        uint256 amount = 1000 ether;
        vm.prank(alice);
        token.approve(bob, amount);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);

        vm.prank(bob);
        token.transferFrom(alice, bob, amount);

        assertEq(token.balanceOf(alice), aliceBefore - amount);
        assertEq(token.balanceOf(bob), bobBefore + amount);
    }

    // ================================================================
    //     M-03: uint128 overflow protection
    // ================================================================

    function test_M03_taxAccumulation_doesNotRevert() public {
        // Set max sell tax and do a big CL sell — must not revert
        vm.prank(owner);
        token.setProjectTaxRates(100, 1000); // 10% sell tax (max allowed)

        vm.prank(owner);
        token.addCLPool(address(clPool));

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 sellAmount = 5_000_000 ether;

        // Sell a large amount — tax accumulates, autoSwap may drain it
        vm.prank(alice);
        token.transfer(address(clPool), sellAmount);

        // CL model: seller is debited sellAmount + tax. 10% of 5M = 500k tax.
        uint256 expectedTax = (sellAmount * 1000) / 10000; // 10% sell tax
        assertEq(token.balanceOf(alice), aliceBefore - sellAmount - expectedTax, "alice balance reduced by sell + tax");
        // Tax was collected (either pending or already swapped via autoSwap)
        // If autoSwap fired, pendingSwap may be 0 — that's fine, transfer didn't revert
    }
}
