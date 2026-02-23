// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

// ============================================================
// MOCK CONTRACTS pour le PoC CrossChainBridge OlympusDAO
// Reproduit fidèlement l'environnement de production
// ============================================================

// ---- Interface ILayerZeroEndpoint (minimal) ----
interface ILZEndpoint {
    function send(
        uint16 _dstChainId,
        bytes calldata _destination,
        bytes calldata _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable;

    function estimateFees(
        uint16 _dstChainId,
        address _userApplication,
        bytes calldata _payload,
        bool _payInZRO,
        bytes calldata _adapterParam
    ) external view returns (uint256 nativeFee, uint256 zroFee);

    function setConfig(uint16, uint16, uint256, bytes calldata) external;
    function setSendVersion(uint16) external;
    function setReceiveVersion(uint16) external;
    function forceResumeReceive(uint16, bytes calldata) external;
    function getConfig(uint16, uint16, address, uint256) external view returns (bytes memory);
}

// ---- MockOHM : ERC20 minimal avec mint/burn ----
contract MockOHM {
    string public name = "Olympus";
    string public symbol = "OHM";
    uint8 public decimals = 9;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "ERC20: burn amount exceeds balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// ---- MockMINTR : Reproduit MINTRv1 d'OlympusDAO ----
// Le module MINTR gère les approbations de mint et délègue le mint à OHM
contract MockMINTR {
    MockOHM public ohm;
    mapping(address => uint256) public mintApproval;

    constructor(address ohm_) {
        ohm = MockOHM(ohm_);
    }

    /// @notice Augmente l'approbation de mint pour une adresse
    function increaseMintApproval(address policy_, uint256 amount_) external {
        mintApproval[policy_] += amount_;
    }

    /// @notice Mint OHM — vérifie l'approbation (comme en production)
    function mintOhm(address to_, uint256 amount_) external {
        require(mintApproval[msg.sender] >= amount_, "MINTR: insufficient mint approval");
        mintApproval[msg.sender] -= amount_;
        
        // Simuler un échec si la destination est un contrat qui revert (ex: MaliciousReceiver)
        (bool success, ) = to_.call("");
        if (!success) revert("Mint failed: destination reverted");
        
        ohm.mint(to_, amount_);
    }

    /// @notice Burn OHM
    function burnOhm(address from_, uint256 amount_) external {
        ohm.burn(from_, amount_);
    }
}

// ---- MockLZEndpoint : Simule le endpoint LayerZero ----
contract MockLZEndpoint is ILZEndpoint {
    address public bridge;

    function setBridge(address bridge_) external {
        bridge = bridge_;
    }

    function send(
        uint16,
        bytes calldata,
        bytes calldata,
        address payable,
        address,
        bytes calldata
    ) external payable override {}

    function estimateFees(
        uint16,
        address,
        bytes calldata,
        bool,
        bytes calldata
    ) external pure override returns (uint256 nativeFee, uint256 zroFee) {
        return (0.01 ether, 0);
    }

    function setConfig(uint16, uint16, uint256, bytes calldata) external override {}
    function setSendVersion(uint16) external override {}
    function setReceiveVersion(uint16) external override {}
    function forceResumeReceive(uint16, bytes calldata) external override {}
    function getConfig(uint16, uint16, address, uint256) external pure override returns (bytes memory) {
        return "";
    }
}
