// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

// ============================================================
// REPRODUCTION FIDÈLE DU CrossChainBridge OlympusDAO V3
// Source: https://github.com/OlympusDAO/olympus-v3/blob/master/src/policies/CrossChainBridge.sol
// Commit: 464abc3f (master branch, Feb 2024)
// ============================================================

import "./MockContracts.sol";

/// @notice Reproduction du CrossChainBridge OlympusDAO pour PoC de sécurité
/// @dev Ce contrat reproduit EXACTEMENT la logique du contrat déployé
contract CrossChainBridgePOC {
    
    // ---- Errors (identiques au contrat réel) ----
    error Bridge_InsufficientAmount();
    error Bridge_InvalidCaller();
    error Bridge_InvalidMessageSource();
    error Bridge_NoStoredMessage();
    error Bridge_InvalidPayload();
    error Bridge_DestinationNotTrusted();
    error Bridge_NoTrustedPath();
    error Bridge_Deactivated();
    error Bridge_TrustedRemoteUninitialized();

    // ---- Events ----
    event BridgeTransferred(address indexed sender_, uint256 amount_, uint16 indexed dstChain_);
    event BridgeReceived(address indexed receiver_, uint256 amount_, uint16 indexed srcChain_);
    event MessageFailed(uint16 srcChainId_, bytes srcAddress_, uint64 nonce_, bytes payload_, bytes reason_);
    event RetryMessageSuccess(uint16 srcChainId_, bytes srcAddress_, uint64 nonce_, bytes32 payloadHash_);
    event BridgeStatusSet(bool isActive_);

    // ---- State Variables (identiques au contrat réel) ----
    MockMINTR public MINTR;
    MockLZEndpoint public immutable lzEndpoint;
    MockOHM public ohm;

    /// @notice Flag to determine if bridge is allowed to send messages or not
    bool public bridgeActive;

    /// @notice Storage for failed messages on receive.
    mapping(uint16 => mapping(bytes => mapping(uint64 => bytes32))) public failedMessages;

    /// @notice Trusted remote paths.
    mapping(uint16 => bytes) public trustedRemoteLookup;

    address public admin;

    // ---- Constructor ----
    constructor(address mintr_, address endpoint_) {
        MINTR = MockMINTR(mintr_);
        lzEndpoint = MockLZEndpoint(endpoint_);
        ohm = MINTR.ohm();
        bridgeActive = true; // Bridge starts active
        admin = msg.sender;
    }

    // ---- Admin Functions ----
    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    function setTrustedRemote(uint16 srcChainId_, bytes calldata path_) external onlyAdmin {
        trustedRemoteLookup[srcChainId_] = path_;
    }

    /// @notice Activate or deactivate the bridge
    /// @dev This is the GOVERNANCE EMERGENCY SHUTDOWN mechanism
    function setBridgeStatus(bool isActive_) external onlyAdmin {
        bridgeActive = isActive_;
        emit BridgeStatusSet(isActive_);
    }

    // ============================================================================================
    // CORE FUNCTIONS - REPRODUCTION EXACTE DU CODE RÉEL
    // ============================================================================================

    /// @notice Send OHM to an eligible chain
    /// @dev CORRECTEMENT protégé par bridgeActive
    function sendOhm(uint16 dstChainId_, address to_, uint256 amount_) external payable {
        // ✓ GUARD PRÉSENT: sendOhm vérifie bridgeActive
        if (!bridgeActive) revert Bridge_Deactivated();
        if (ohm.balanceOf(msg.sender) < amount_) revert Bridge_InsufficientAmount();

        bytes memory payload = abi.encode(to_, amount_);
        MINTR.burnOhm(msg.sender, amount_);

        emit BridgeTransferred(msg.sender, amount_, dstChainId_);
    }

    /// @notice Implementation of receiving an LZ message
    /// @dev INTERNE - NE VÉRIFIE PAS bridgeActive ← FAILLE
    function _receiveMessage(
        uint16 srcChainId_,
        bytes memory,
        uint64,
        bytes memory payload_
    ) internal virtual {
        // ✗ GUARD ABSENT: _receiveMessage ne vérifie PAS bridgeActive
        // C'est ici que la vulnérabilité réside
        (address to, uint256 amount) = abi.decode(payload_, (address, uint256));

        MINTR.increaseMintApproval(address(this), amount);
        MINTR.mintOhm(to, amount);

        emit BridgeReceived(to, amount, srcChainId_);
    }

    /// @notice Implementation of receiving an LZ message (public wrapper)
    function receiveMessage(
        uint16 srcChainId_,
        bytes memory srcAddress_,
        uint64 nonce_,
        bytes memory payload_
    ) public {
        // Restreint à address(this) via low-level call depuis lzReceive
        if (msg.sender != address(this)) revert Bridge_InvalidCaller();
        // ✗ GUARD ABSENT: receiveMessage ne vérifie PAS bridgeActive
        _receiveMessage(srcChainId_, srcAddress_, nonce_, payload_);
    }

    /// @notice LZ receive entry point
    function lzReceive(
        uint16 srcChainId_,
        bytes calldata srcAddress_,
        uint64 nonce_,
        bytes calldata payload_
    ) public virtual {
        // Restreint au lzEndpoint
        if (msg.sender != address(lzEndpoint)) revert Bridge_InvalidCaller();

        // Vérification de la source de confiance
        bytes memory trustedRemote = trustedRemoteLookup[srcChainId_];
        if (
            trustedRemote.length == 0 ||
            srcAddress_.length != trustedRemote.length ||
            keccak256(srcAddress_) != keccak256(trustedRemote)
        ) revert Bridge_InvalidMessageSource();

        // ✗ GUARD ABSENT: lzReceive ne vérifie PAS bridgeActive
        // Low-level call pour capturer les erreurs
        (bool success, bytes memory reason) = address(this).call(
            abi.encodeWithSelector(
                this.receiveMessage.selector,
                srcChainId_,
                srcAddress_,
                nonce_,
                payload_
            )
        );

        // Si le message échoue, le stocker pour retry
        if (!success) {
            failedMessages[srcChainId_][srcAddress_][nonce_] = keccak256(payload_);
            emit MessageFailed(srcChainId_, srcAddress_, nonce_, payload_, reason);
        }
    }

    /// @notice Retry a failed receive message
    /// @dev VECTEUR D'ATTAQUE PRINCIPAL: PUBLIC, PERMISSIONLESS, SANS guard bridgeActive
    function retryMessage(
        uint16 srcChainId_,
        bytes calldata srcAddress_,
        uint64 nonce_,
        bytes calldata payload_
    ) public payable virtual {
        // Vérification du message stocké
        bytes32 payloadHash = failedMessages[srcChainId_][srcAddress_][nonce_];
        if (payloadHash == bytes32(0)) revert Bridge_NoStoredMessage();
        if (keccak256(payload_) != payloadHash) revert Bridge_InvalidPayload();

        // Clear the stored message
        failedMessages[srcChainId_][srcAddress_][nonce_] = bytes32(0);

        // ✗ GUARD ABSENT: retryMessage ne vérifie PAS bridgeActive
        // APPEL DIRECT à _receiveMessage → mint OHM sans restriction
        _receiveMessage(srcChainId_, srcAddress_, nonce_, payload_);

        emit RetryMessageSuccess(srcChainId_, srcAddress_, nonce_, payloadHash);
    }
}
