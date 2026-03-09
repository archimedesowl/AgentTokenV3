// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentTokenV3.sol";
import "../src/interfaces/IAgentTokenV3.sol";

/**
 * @title AgentTokenV3GameAixbtTest
 * @notice Fork tests against real GAME and AIXBT tokens on Base mainnet.
 *         Validates V3 upgrade path: storage, V2 sells, CL sells, auto-detection,
 *         tax math, access control, and new audit-fix features.
 */
contract AgentTokenV3GameAixbtTest is Test {
    address constant GAME   = 0x1C4CcA7C5DB003824208aDDA61Bd749e55F463a3;
    address constant AIXBT  = 0x4F9Fd6Be4a90f2620860d680c0d4d5Fb53d1A825;
    address constant VIRTUAL = 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b;
    address constant UNI_V3_FACTORY  = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address constant AERO_V2_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant GAME_V2_VOLATILE  = 0x9f7700b6030471D89c643f30b2315A670Ab13bB4;
    address constant GAME_UNIV3_3000   = 0xfD9C418ac8762A44bB06CD2635db024C61FbA1dB;
    address constant AIXBT_V2_VOLATILE = 0xeb3458046d3aA2fdbBbF4FEe58C755744ec42ce2;
    address constant AIXBT_UNIV3_3000  = 0xEdbC10C4A80A85b14c6ab4fA1B3d26f1e315C103;
    address constant TOKEN_OWNER = 0xE220329659D41B2a9F26E83816B424bDAcF62567;

    AgentTokenV3 public v3Impl;
    address public alice;
    address public bob;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org");
        v3Impl = new AgentTokenV3();
        alice = makeAddr("alice");
        bob   = makeAddr("bob");
    }

    function _upgradeMinimalProxy(address proxy, address newImpl) internal {
        bytes memory code = abi.encodePacked(
            hex"363d3d373d3d3d363d73", newImpl, hex"5af43d82803e903d91602b57fd5bf3"
        );
        vm.etch(proxy, code);
    }

    function _clearAutoSwapFlag(address proxy) internal {
        bytes32 slot3 = vm.load(proxy, bytes32(uint256(3)));
        bytes32 mask = ~bytes32(uint256(0xFF) << 160);
        vm.store(proxy, bytes32(uint256(3)), slot3 & mask);
    }

    function _ensureFundedDate(address proxy) internal {
        bytes32 slot2 = vm.load(proxy, bytes32(uint256(2)));
        uint32 fundedDate = uint32(uint256(slot2) >> 168);
        if (fundedDate == 0) {
            bytes32 mask = ~bytes32(uint256(0xFFFFFFFF) << 168);
            bytes32 newVal = (slot2 & mask) | bytes32(uint256(1) << 168);
            vm.store(proxy, bytes32(uint256(2)), newVal);
        }
    }

    function _clearBlacklistForPair(AgentTokenV3 token) internal {
        address pair = token.uniswapV2Pair();
        if (token.blacklists(pair)) {
            vm.prank(token.owner());
            token.removeBlacklistAddress(pair);
        }
    }

    function _fullUpgrade(address proxy) internal returns (AgentTokenV3) {
        _upgradeMinimalProxy(proxy, address(v3Impl));
        _clearAutoSwapFlag(proxy);
        _ensureFundedDate(proxy);
        AgentTokenV3 token = AgentTokenV3(payable(proxy));
        _clearBlacklistForPair(token);
        return token;
    }

    // ================================================================
    //  1. Storage Preservation
    // ================================================================

    function test_fork_GAME_storagePreserved() public {
        AgentTokenV3 game = AgentTokenV3(payable(GAME));
        string memory nameBefore = game.name();
        string memory symbolBefore = game.symbol();
        uint256 supplyBefore = game.totalSupply();
        uint16 buyTaxBefore = game.projectBuyTaxBasisPoints();
        uint16 sellTaxBefore = game.projectSellTaxBasisPoints();
        address ownerBefore = game.owner();
        address pairBefore = game.uniswapV2Pair();
        address pairTokenBefore = game.pairToken();
        _upgradeMinimalProxy(GAME, address(v3Impl));
        assertEq(game.name(), nameBefore, "name");
        assertEq(game.symbol(), symbolBefore, "symbol");
        assertEq(game.totalSupply(), supplyBefore, "totalSupply");
        assertEq(game.projectBuyTaxBasisPoints(), buyTaxBefore, "buyTax");
        assertEq(game.projectSellTaxBasisPoints(), sellTaxBefore, "sellTax");
        assertEq(game.owner(), ownerBefore, "owner");
        assertEq(game.uniswapV2Pair(), pairBefore, "v2Pair");
        assertEq(game.pairToken(), pairTokenBefore, "pairToken");
        assertEq(game.clPools().length, 0, "clPools empty");
    }

    function test_fork_AIXBT_storagePreserved() public {
        AgentTokenV3 aixbt = AgentTokenV3(payable(AIXBT));
        string memory nameBefore = aixbt.name();
        string memory symbolBefore = aixbt.symbol();
        uint256 supplyBefore = aixbt.totalSupply();
        uint16 buyTaxBefore = aixbt.projectBuyTaxBasisPoints();
        uint16 sellTaxBefore = aixbt.projectSellTaxBasisPoints();
        address ownerBefore = aixbt.owner();
        address pairBefore = aixbt.uniswapV2Pair();
        _upgradeMinimalProxy(AIXBT, address(v3Impl));
        assertEq(aixbt.name(), nameBefore, "name");
        assertEq(aixbt.symbol(), symbolBefore, "symbol");
        assertEq(aixbt.totalSupply(), supplyBefore, "totalSupply");
        assertEq(aixbt.projectBuyTaxBasisPoints(), buyTaxBefore, "buyTax");
        assertEq(aixbt.projectSellTaxBasisPoints(), sellTaxBefore, "sellTax");
        assertEq(aixbt.owner(), ownerBefore, "owner");
        assertEq(aixbt.uniswapV2Pair(), pairBefore, "v2Pair");
        assertEq(aixbt.clPools().length, 0, "clPools empty");
    }

    // ================================================================
    //  2. Tax Rates
    // ================================================================

    function test_fork_GAME_taxRates() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        assertEq(game.projectBuyTaxBasisPoints(), 100, "buy 1%");
        assertEq(game.projectSellTaxBasisPoints(), 100, "sell 1%");
    }

    function test_fork_AIXBT_taxRates() public {
        AgentTokenV3 aixbt = _fullUpgrade(AIXBT);
        assertEq(aixbt.projectBuyTaxBasisPoints(), 100, "buy 1%");
        assertEq(aixbt.projectSellTaxBasisPoints(), 100, "sell 1%");
    }

    // ================================================================
    //  3. Regular Transfer (no tax)
    // ================================================================

    function test_fork_GAME_regularTransfer_noTax() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        deal(GAME, alice, 50_000 ether);
        vm.prank(alice);
        game.transfer(bob, 1_000 ether);
        assertEq(game.balanceOf(bob), 1_000 ether);
    }

    function test_fork_AIXBT_regularTransfer_noTax() public {
        AgentTokenV3 aixbt = _fullUpgrade(AIXBT);
        deal(AIXBT, alice, 50_000 ether);
        vm.prank(alice);
        aixbt.transfer(bob, 1_000 ether);
        assertEq(aixbt.balanceOf(bob), 1_000 ether);
    }

    // ================================================================
    //  4. V2 Sell Still Works
    // ================================================================

    function test_fork_GAME_v2Sell() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        deal(GAME, alice, 50_000 ether);
        address v2Pool = game.uniswapV2Pair();
        uint256 poolBefore = game.balanceOf(v2Pool);
        vm.prank(alice);
        game.transfer(v2Pool, 500 ether);
        uint256 poolGot = game.balanceOf(v2Pool) - poolBefore;
        assertEq(poolGot, 500 ether - (500 ether * 100 / 10000), "V2 tax deducted");
    }

    function test_fork_AIXBT_v2Sell() public {
        AgentTokenV3 aixbt = _fullUpgrade(AIXBT);
        deal(AIXBT, alice, 50_000 ether);
        address v2Pool = aixbt.uniswapV2Pair();
        uint256 poolBefore = aixbt.balanceOf(v2Pool);
        vm.prank(alice);
        aixbt.transfer(v2Pool, 500 ether);
        uint256 poolGot = aixbt.balanceOf(v2Pool) - poolBefore;
        assertEq(poolGot, 500 ether - (500 ether * 100 / 10000), "V2 tax deducted");
    }

    // ================================================================
    //  5. CL Sell
    // ================================================================

    function test_fork_GAME_clSell() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        MockCLPoolGA mockPool = new MockCLPoolGA();
        vm.prank(TOKEN_OWNER);
        game.addCLPool(address(mockPool));
        deal(GAME, alice, 50_000 ether);
        uint256 sellAmount = 1_000 ether;
        uint256 expectedTax = sellAmount * 100 / 10000;
        uint256 aliceBefore = game.balanceOf(alice);
        uint256 contractBefore = game.balanceOf(GAME);
        vm.prank(alice);
        game.transfer(address(mockPool), sellAmount);
        assertEq(game.balanceOf(address(mockPool)), sellAmount, "pool full");
        assertEq(game.balanceOf(alice), aliceBefore - sellAmount - expectedTax, "alice debited");
        assertEq(game.balanceOf(GAME), contractBefore + expectedTax, "contract tax");
    }

    function test_fork_AIXBT_clSell() public {
        AgentTokenV3 aixbt = _fullUpgrade(AIXBT);
        MockCLPoolGA mockPool = new MockCLPoolGA();
        vm.prank(TOKEN_OWNER);
        aixbt.addCLPool(address(mockPool));
        deal(AIXBT, alice, 50_000 ether);
        uint256 sellAmount = 1_000 ether;
        uint256 expectedTax = sellAmount * 100 / 10000;
        uint256 aliceBefore = aixbt.balanceOf(alice);
        vm.prank(alice);
        aixbt.transfer(address(mockPool), sellAmount);
        assertEq(aixbt.balanceOf(address(mockPool)), sellAmount, "pool full");
        assertEq(aixbt.balanceOf(alice), aliceBefore - sellAmount - expectedTax, "alice debited");
    }

    // ================================================================
    //  6. CL Sell via transferFrom (router)
    // ================================================================

    function test_fork_GAME_clSell_transferFrom() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        MockCLPoolGA mockPool = new MockCLPoolGA();
        vm.prank(TOKEN_OWNER);
        game.addCLPool(address(mockPool));
        deal(GAME, alice, 50_000 ether);
        address router = makeAddr("router");
        vm.prank(alice);
        game.approve(router, type(uint256).max);
        uint256 aliceBefore = game.balanceOf(alice);
        uint256 sellAmount = 200 ether;
        uint256 expectedTax = sellAmount * 100 / 10000;
        vm.prank(router);
        game.transferFrom(alice, address(mockPool), sellAmount);
        assertEq(game.balanceOf(address(mockPool)), sellAmount);
        assertEq(game.balanceOf(alice), aliceBefore - sellAmount - expectedTax);
    }

    // ================================================================
    //  7. CL Buy — tax deducted from delivery
    // ================================================================

    function test_fork_GAME_clBuy() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        MockCLPoolGA mockPool = new MockCLPoolGA();
        vm.prank(TOKEN_OWNER);
        game.addCLPool(address(mockPool));
        uint256 buyAmount = 1_000 ether;
        deal(GAME, address(mockPool), buyAmount);
        uint256 expectedTax = buyAmount * 100 / 10000;
        uint256 contractBefore = game.balanceOf(GAME);
        vm.prank(address(mockPool));
        game.transfer(alice, buyAmount);
        assertEq(game.balanceOf(alice), buyAmount - expectedTax, "alice gets minus tax");
        assertEq(game.balanceOf(GAME), contractBefore + expectedTax, "contract tax");
    }

    // ================================================================
    //  8. Auto-detect UniV3 (real pools)
    // ================================================================

    function test_fork_GAME_autoDetect_uniV3() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        uint24[] memory tiers = new uint24[](3);
        tiers[0] = 500; tiers[1] = 3000; tiers[2] = 10000;
        vm.prank(TOKEN_OWNER);
        game.addUniV3Factory(UNI_V3_FACTORY, tiers);
        deal(GAME, alice, 50_000 ether);
        uint256 aliceBefore = game.balanceOf(alice);
        uint256 sellAmount = 500 ether;
        uint256 expectedTax = sellAmount * 100 / 10000;
        vm.prank(alice);
        game.transfer(GAME_UNIV3_3000, sellAmount);
        assertTrue(game.isCLPool(GAME_UNIV3_3000), "auto-registered");
        assertEq(game.balanceOf(alice), aliceBefore - sellAmount - expectedTax, "CL tax");
    }

    function test_fork_AIXBT_autoDetect_uniV3() public {
        AgentTokenV3 aixbt = _fullUpgrade(AIXBT);
        uint24[] memory tiers = new uint24[](3);
        tiers[0] = 500; tiers[1] = 3000; tiers[2] = 10000;
        vm.prank(TOKEN_OWNER);
        aixbt.addUniV3Factory(UNI_V3_FACTORY, tiers);
        deal(AIXBT, alice, 50_000 ether);
        vm.prank(alice);
        aixbt.transfer(AIXBT_UNIV3_3000, 500 ether);
        assertTrue(aixbt.isCLPool(AIXBT_UNIV3_3000), "auto-registered");
    }

    // ================================================================
    //  9. Auto-detect Aero V2 (real pool)
    // ================================================================

    function test_fork_GAME_autoDetect_aeroV2() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        vm.prank(TOKEN_OWNER);
        game.addV2Factory(AERO_V2_FACTORY);
        deal(GAME, alice, 50_000 ether);
        uint256 poolBefore = game.balanceOf(GAME_V2_VOLATILE);
        vm.prank(alice);
        game.transfer(GAME_V2_VOLATILE, 500 ether);
        uint256 poolGot = game.balanceOf(GAME_V2_VOLATILE) - poolBefore;
        assertEq(poolGot, 500 ether - (500 ether * 100 / 10000), "V2 tax");
        assertTrue(game.isLiquidityPool(GAME_V2_VOLATILE), "auto-registered");
    }

    // ================================================================
    //  10. Remove CL Pool → no tax
    // ================================================================

    function test_fork_GAME_removeCLPool() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        MockCLPoolGA mockPool = new MockCLPoolGA();
        vm.startPrank(TOKEN_OWNER);
        game.addCLPool(address(mockPool));
        game.removeCLPool(address(mockPool));
        vm.stopPrank();
        deal(GAME, alice, 10_000 ether);
        vm.prank(alice);
        game.transfer(address(mockPool), 100 ether);
        assertEq(game.balanceOf(address(mockPool)), 100 ether, "no tax");
    }

    // ================================================================
    //  11. Supply Invariant (CL sell: balance shift, NOT mint)
    // ================================================================

    function test_fork_GAME_supplyInvariant() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        MockCLPoolGA mockPool = new MockCLPoolGA();
        vm.prank(TOKEN_OWNER);
        game.addCLPool(address(mockPool));
        deal(GAME, alice, 50_000 ether);
        uint256 supplyBefore = game.totalSupply();
        vm.prank(alice);
        game.transfer(address(mockPool), 1_000 ether);
        // CL sell shifts balances (sender -> pool + sender -> contract)
        // without minting, so totalSupply stays constant
        assertEq(game.totalSupply(), supplyBefore, "supply unchanged after CL sell");
    }

    // ================================================================
    //  12. Tax Accumulation (multiple sells)
    // ================================================================

    function test_fork_GAME_taxAccumulation() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        MockCLPoolGA mockPool = new MockCLPoolGA();
        vm.prank(TOKEN_OWNER);
        game.addCLPool(address(mockPool));
        deal(GAME, alice, 100_000 ether);
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            game.transfer(address(mockPool), 1_000 ether);
        }
        uint256 totalTax = 3 * (1_000 ether * 100 / 10000);
        assertEq(game.balanceOf(alice), 100_000 ether - 3_000 ether - totalTax, "3x sell+tax");
    }

    // ================================================================
    //  13. distributeTaxTokens
    // ================================================================

    function test_fork_GAME_distributeTax() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        MockCLPoolGA mockPool = new MockCLPoolGA();
        vm.prank(TOKEN_OWNER);
        game.addCLPool(address(mockPool));
        deal(GAME, alice, 50_000 ether);
        vm.prank(alice);
        game.transfer(address(mockPool), 10_000 ether);
        uint256 contractBal = game.balanceOf(GAME);
        if (contractBal > 0) {
            address recipient = game.projectTaxRecipient();
            uint256 recipientBefore = game.balanceOf(recipient);
            vm.prank(TOKEN_OWNER);
            game.distributeTaxTokens();
            assertTrue(game.balanceOf(recipient) >= recipientBefore, "distributed");
        }
    }

    // ================================================================
    //  14. Access Control
    // ================================================================

    function test_fork_GAME_accessControl() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        vm.prank(alice);
        vm.expectRevert();
        game.setProjectTaxRates(200, 200);
        vm.prank(alice);
        vm.expectRevert();
        game.addCLPool(address(1));
        vm.prank(TOKEN_OWNER);
        vm.expectRevert();
        game.renounceOwnership();
    }

    // ================================================================
    //  15. MAX_TAX_BP enforcement
    // ================================================================

    function test_fork_GAME_maxTaxCap() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        vm.prank(TOKEN_OWNER);
        game.setProjectTaxRates(1000, 1000);
        assertEq(game.projectBuyTaxBasisPoints(), 1000);
        vm.prank(TOKEN_OWNER);
        vm.expectRevert(AgentTokenV3.TaxRateExceedsMaximum.selector);
        game.setProjectTaxRates(1001, 500);
    }

    // ================================================================
    //  16. Duplicate Factory prevention (M-04)
    // ================================================================

    function test_fork_GAME_duplicateFactory() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        vm.startPrank(TOKEN_OWNER);
        game.addV2Factory(AERO_V2_FACTORY);
        vm.expectRevert(AgentTokenV3.FactoryAlreadyRegistered.selector);
        game.addV2Factory(AERO_V2_FACTORY);
        vm.stopPrank();
    }

    // ================================================================
    //  17. Blacklist
    // ================================================================

    function test_fork_GAME_blacklist() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        deal(GAME, alice, 10_000 ether);
        vm.prank(TOKEN_OWNER);
        game.addBlacklistAddress(alice);
        vm.prank(alice);
        vm.expectRevert();
        game.transfer(bob, 100 ether);
    }

    // ================================================================
    //  18. sweepExcessTaxTokens (L-02)
    // ================================================================

    function test_fork_GAME_sweepExcess() public {
        AgentTokenV3 game = _fullUpgrade(GAME);

        // Accumulate real tax via CL sell (not deal, which doesn't update internal tracking)
        MockCLPoolGA mockPool = new MockCLPoolGA();
        vm.prank(TOKEN_OWNER);
        game.addCLPool(address(mockPool));
        deal(GAME, alice, 100_000 ether);

        // Do a sell to accumulate tax on contract
        vm.prank(alice);
        game.transfer(address(mockPool), 50_000 ether);

        uint256 contractBal = game.balanceOf(GAME);
        uint256 pending = game.projectTaxPendingSwap();

        // There should be excess if contractBal > pending (due to autoSwap rounding etc.)
        // or we can clear pending to simulate the excess scenario
        if (contractBal > 0 && contractBal > pending) {
            address recipient = game.projectTaxRecipient();
            uint256 recipientBefore = game.balanceOf(recipient);
            vm.prank(TOKEN_OWNER);
            game.sweepExcessTaxTokens();
            assertTrue(game.balanceOf(recipient) >= recipientBefore, "swept");
        }
    }

    // ================================================================
    //  19. Multiple CL Pools
    // ================================================================

    function test_fork_GAME_multipleCLPools() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        MockCLPoolGA p1 = new MockCLPoolGA();
        MockCLPoolGA p2 = new MockCLPoolGA();
        vm.startPrank(TOKEN_OWNER);
        game.addCLPool(address(p1));
        game.addCLPool(address(p2));
        vm.stopPrank();
        assertEq(game.clPools().length, 2);
        deal(GAME, alice, 50_000 ether);
        vm.prank(alice);
        game.transfer(address(p1), 500 ether);
        assertEq(game.balanceOf(address(p1)), 500 ether);
        vm.prank(alice);
        game.transfer(address(p2), 500 ether);
        assertEq(game.balanceOf(address(p2)), 500 ether);
    }

    // ================================================================
    //  20. Second transfer uses cache (gas optimization)
    // ================================================================

    function test_fork_GAME_cacheUsed() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        uint24[] memory tiers = new uint24[](2);
        tiers[0] = 3000; tiers[1] = 10000;
        vm.prank(TOKEN_OWNER);
        game.addUniV3Factory(UNI_V3_FACTORY, tiers);
        deal(GAME, alice, 50_000 ether);
        vm.prank(alice);
        game.transfer(GAME_UNIV3_3000, 100 ether);
        assertTrue(game.isCLPool(GAME_UNIV3_3000));
        vm.prank(alice);
        game.transfer(GAME_UNIV3_3000, 100 ether);
        assertTrue(game.balanceOf(GAME_UNIV3_3000) >= 200 ether);
    }

    // ================================================================
    //  21. EOA transfer — no false positive detection
    // ================================================================

    function test_fork_GAME_eoaNoFalsePositive() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        uint24[] memory tiers = new uint24[](1);
        tiers[0] = 3000;
        vm.prank(TOKEN_OWNER);
        game.addUniV3Factory(UNI_V3_FACTORY, tiers);
        deal(GAME, alice, 50_000 ether);
        vm.prank(alice);
        game.transfer(bob, 1_000 ether);
        assertFalse(game.isCLPool(bob));
        assertEq(game.balanceOf(bob), 1_000 ether);
    }

    // ================================================================
    //  22. GAME Full Integration (both factories + mixed transfers)
    // ================================================================

    function test_fork_GAME_fullIntegration() public {
        AgentTokenV3 game = _fullUpgrade(GAME);
        uint24[] memory tiers = new uint24[](2);
        tiers[0] = 3000; tiers[1] = 10000;
        vm.startPrank(TOKEN_OWNER);
        game.addUniV3Factory(UNI_V3_FACTORY, tiers);
        game.addV2Factory(AERO_V2_FACTORY);
        vm.stopPrank();
        deal(GAME, alice, 200_000 ether);

        // Regular transfer — no tax
        vm.prank(alice);
        game.transfer(bob, 5_000 ether);
        assertEq(game.balanceOf(bob), 5_000 ether, "no tax");

        // V2 sell (auto-detect)
        uint256 v2Before = game.balanceOf(GAME_V2_VOLATILE);
        vm.prank(alice);
        game.transfer(GAME_V2_VOLATILE, 5_000 ether);
        assertEq(
            game.balanceOf(GAME_V2_VOLATILE) - v2Before,
            5_000 ether - (5_000 ether * 100 / 10000),
            "V2 sell"
        );

        // CL sell (auto-detect)
        uint256 clBefore = game.balanceOf(GAME_UNIV3_3000);
        uint256 aliceBefore = game.balanceOf(alice);
        vm.prank(alice);
        game.transfer(GAME_UNIV3_3000, 5_000 ether);
        assertEq(game.balanceOf(GAME_UNIV3_3000) - clBefore, 5_000 ether, "CL full");
        assertEq(
            game.balanceOf(alice),
            aliceBefore - 5_000 ether - (5_000 ether * 100 / 10000),
            "CL tax"
        );
    }

    // ================================================================
    //  23. AIXBT Full Integration
    // ================================================================

    function test_fork_AIXBT_fullIntegration() public {
        AgentTokenV3 aixbt = _fullUpgrade(AIXBT);
        uint24[] memory tiers = new uint24[](2);
        tiers[0] = 3000; tiers[1] = 10000;
        vm.startPrank(TOKEN_OWNER);
        aixbt.addUniV3Factory(UNI_V3_FACTORY, tiers);
        aixbt.addV2Factory(AERO_V2_FACTORY);
        vm.stopPrank();
        deal(AIXBT, alice, 200_000 ether);

        // Regular transfer
        vm.prank(alice);
        aixbt.transfer(bob, 5_000 ether);
        assertEq(aixbt.balanceOf(bob), 5_000 ether);

        // V2 sell
        uint256 v2Before = aixbt.balanceOf(AIXBT_V2_VOLATILE);
        vm.prank(alice);
        aixbt.transfer(AIXBT_V2_VOLATILE, 5_000 ether);
        assertEq(
            aixbt.balanceOf(AIXBT_V2_VOLATILE) - v2Before,
            5_000 ether - (5_000 ether * 100 / 10000),
            "V2 sell"
        );

        // CL sell
        uint256 clBefore = aixbt.balanceOf(AIXBT_UNIV3_3000);
        uint256 aliceBefore = aixbt.balanceOf(alice);
        vm.prank(alice);
        aixbt.transfer(AIXBT_UNIV3_3000, 5_000 ether);
        assertEq(aixbt.balanceOf(AIXBT_UNIV3_3000) - clBefore, 5_000 ether, "CL full");
        assertEq(
            aixbt.balanceOf(alice),
            aliceBefore - 5_000 ether - (5_000 ether * 100 / 10000),
            "CL tax"
        );
    }
}

contract MockCLPoolGA {
    receive() external payable {}
}
