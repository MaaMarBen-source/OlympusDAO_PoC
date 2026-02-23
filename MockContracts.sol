// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

// ============================================================
// MOCK CONTRACTS FOR OLYMPUSDAO CROSSCHAINBRIDGE POC
// Simulates the OlympusDAO V3 Default Framework environment
// ============================================================

// ---- ERC20 minimal interface ----
contract MockOHM {
    string public name = "Olympus";
    string public symbol = "OHM";
    uint8 public decimals = 9;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "OHM: insufficient balance");
        totalSupply -= amount;
        balanceOf[from] -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "OHM: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "OHM: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "OHM: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// ---- Mock MINTR Module ----
contract MockMINTR {
    MockOHM public ohm;
    mapping(address => uint256) public mintApproval;

    event IncreaseMintApproval(address indexed policy_, uint256 amount_);
    event MintOhm(address indexed to_, uint256 amount_);
    event BurnOhm(address indexed from_, uint256 amount_);

    constructor(address ohm_) {
        ohm = MockOHM(ohm_);
    }

    function increaseMintApproval(address policy_, uint256 amount_) external {
        mintApproval[policy_] += amount_;
        emit IncreaseMintApproval(policy_, amount_);
    }

    function mintOhm(address to_, uint256 amount_) external {
        require(mintApproval[msg.sender] >= amount_, "MINTR: insufficient approval");
        mintApproval[msg.sender] -= amount_;
        ohm.mint(to_, amount_);
        emit MintOhm(to_, amount_);
    }

    function burnOhm(address from_, uint256 amount_) external {
        ohm.burn(from_, amount_);
        emit BurnOhm(from_, amount_);
    }

    // Expose keycode for compatibility
    function KEYCODE() external pure returns (bytes5) {
        return "MINTR";
    }
}

// ---- Mock LayerZero Endpoint ----
contract MockLZEndpoint {
    // Simulates the LayerZero endpoint
    // In a real scenario, this would be the actual LZ endpoint
    
    address public bridge;
    
    function setBridge(address bridge_) external {
        bridge = bridge_;
    }
    
    // Simulate delivering a message to the bridge
    function deliverMessage(
        uint16 srcChainId_,
        bytes calldata srcAddress_,
        uint64 nonce_,
        bytes calldata payload_
    ) external {
        // Call lzReceive on the bridge as the endpoint
        (bool success, bytes memory reason) = bridge.call(
            abi.encodeWithSignature(
                "lzReceive(uint16,bytes,uint64,bytes)",
                srcChainId_,
                srcAddress_,
                nonce_,
                payload_
            )
        );
        if (!success) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
    
    function send(
        uint16,
        bytes memory,
        bytes memory,
        address payable,
        address,
        bytes memory
    ) external payable {}
    
    function estimateFees(
        uint16,
        address,
        bytes memory,
        bool,
        bytes memory
    ) external pure returns (uint256 nativeFee, uint256 zroFee) {
        return (0.01 ether, 0);
    }
    
    function setConfig(uint16, uint16, uint256, bytes calldata) external {}
    function setSendVersion(uint16) external {}
    function setReceiveVersion(uint16) external {}
    function forceResumeReceive(uint16, bytes calldata) external {}
    function getConfig(uint16, uint16, address, uint256) external pure returns (bytes memory) {
        return "";
    }
}
