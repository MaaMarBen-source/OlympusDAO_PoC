// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.15;

// ============================================================
// CrossChainBridgePOC.sol
// Reproduction FIDÈLE du contrat OlympusDAO CrossChainBridge.sol
// Source: github.com/OlympusDAO/olympus-v3/src/policies/CrossChainBridge.sol
//
// VULNÉRABILITÉ ZERO-DAY DOCUMENTÉE :
//   retryMessage() et lzReceive() ne vérifient PAS bridgeActive
//   => Mint OHM illégal possible même après arrêt d'urgence de la gouvernance
// ============================================================

import "./MockContracts.sol";

contract CrossChainBridgePOC {

    // ---- Errors (identiques au contrat de production) ----
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
    event MessageFailed(
        uint16 srcChainId_,
        bytes srcAddress_,
        uint64 nonce_,
        bytes payload_,
        bytes reason_
    );
    event RetryMessageSuccess(
        uint16 srcChainId_,
        bytes srcAddress_,
        uint64 nonce_,
        bytes32 payloadHash_
    );
    event BridgeStatusSet(bool isActive_);

    // ---- State (identique au contrat de production) ----
    MockMINTR public MINTR;
    MockLZEndpoint public lzEndpoint;
    MockOHM public ohm;

    /// @notice Flag de contrôle d'urgence — seul mécanisme d'arrêt de la gouvernance
    bool public bridgeActive;

    /// @notice Messages échoués stockés pour retry
    /// chainID => source address => nonce => keccak256(payload)
    mapping(uint16 => mapping(bytes => mapping(uint64 => bytes32))) public failedMessages;

    /// @notice Chemins de confiance (trusted remotes)
    mapping(uint16 => bytes) public trustedRemoteLookup;

    address public admin;

    constructor(address mintr_, address endpoint_) {
        MINTR = MockMINTR(mintr_);
        lzEndpoint = MockLZEndpoint(endpoint_);
        ohm = MINTR.ohm();
        bridgeActive = true; // Actif par défaut (comme en production)
        admin = msg.sender;
    }

    // ============================================================
    // CORE FUNCTIONS
    // ============================================================

    /// @notice Envoyer OHM vers une autre chaîne
    /// @dev CORRECTEMENT PROTÉGÉ par bridgeActive — voie sortante sécurisée
    function sendOhm(uint16 dstChainId_, address to_, uint256 amount_) external payable {
        // ✓ GUARD PRÉSENT : voie sortante correctement protégée
        if (!bridgeActive) revert Bridge_Deactivated();
        if (ohm.balanceOf(msg.sender) < amount_) revert Bridge_InsufficientAmount();

        bytes memory payload = abi.encode(to_, amount_);
        MINTR.burnOhm(msg.sender, amount_);

        // Envoi via LayerZero (simplifié pour le PoC)
        lzEndpoint.send{value: msg.value}(
            dstChainId_,
            trustedRemoteLookup[dstChainId_],
            payload,
            payable(msg.sender),
            address(0),
            bytes("")
        );

        emit BridgeTransferred(msg.sender, amount_, dstChainId_);
    }

    /// @notice Réception interne d'un message cross-chain → mint OHM
    /// @dev VULNÉRABLE : pas de vérification de bridgeActive ici
    ///      Appelée par lzReceive(), receiveMessage() ET retryMessage()
    ///      => Tous les chemins entrants sont non protégés
    function _receiveMessage(
        uint16 srcChainId_,
        bytes memory, /* srcAddress_ */
        uint64, /* nonce_ */
        bytes memory payload_
    ) internal virtual {
        // ✗ GUARD ABSENT : bridgeActive n'est PAS vérifié ici
        // C'est l'invariant de sécurité violé : même si bridgeActive == false,
        // cette fonction peut être appelée via retryMessage()
        (address to, uint256 amount) = abi.decode(payload_, (address, uint256));

        MINTR.increaseMintApproval(address(this), amount);
        MINTR.mintOhm(to, amount);

        emit BridgeReceived(to, amount, srcChainId_);
    }

    // ---- LZ Receive Functions ----

    /// @notice Point d'entrée LayerZero — appelé par le endpoint LZ
    /// @dev VULNÉRABLE : ne vérifie pas bridgeActive avant d'appeler receiveMessage
    function lzReceive(
        uint16 srcChainId_,
        bytes calldata srcAddress_,
        uint64 nonce_,
        bytes calldata payload_
    ) public virtual {
        // Seul le endpoint LZ peut appeler cette fonction
        if (msg.sender != address(lzEndpoint)) revert Bridge_InvalidCaller();

        // Vérification de la source de confiance
        bytes memory trustedRemote = trustedRemoteLookup[srcChainId_];
        if (
            trustedRemote.length == 0 ||
            srcAddress_.length != trustedRemote.length ||
            keccak256(srcAddress_) != keccak256(trustedRemote)
        ) revert Bridge_InvalidMessageSource();

        // ✗ GUARD ABSENT : bridgeActive n'est PAS vérifié ici
        // Appel low-level pour capturer les erreurs
        (bool success, bytes memory reason) = address(this).call(
            abi.encodeWithSelector(
                this.receiveMessage.selector,
                srcChainId_,
                srcAddress_,
                nonce_,
                payload_
            )
        );

        // Si échec : stocker le message pour retry
        if (!success) {
            failedMessages[srcChainId_][srcAddress_][nonce_] = keccak256(payload_);
            emit MessageFailed(srcChainId_, srcAddress_, nonce_, payload_, reason);
        }
    }

    /// @notice Réception publique d'un message — appelée par lzReceive via low-level call
    /// @dev VULNÉRABLE : ne vérifie pas bridgeActive
    function receiveMessage(
        uint16 srcChainId_,
        bytes memory srcAddress_,
        uint64 nonce_,
        bytes memory payload_
    ) external {
        // Seul le contrat lui-même peut appeler cette fonction (via lzReceive)
        if (msg.sender != address(this)) revert Bridge_InvalidCaller();
        // ✗ GUARD ABSENT : bridgeActive n'est PAS vérifié ici
        _receiveMessage(srcChainId_, srcAddress_, nonce_, payload_);
    }

    /// @notice Rejouer un message précédemment échoué
    /// @dev VECTEUR D'ATTAQUE PRINCIPAL
    ///      PUBLIC + PERMISSIONLESS : n'importe qui peut appeler cette fonction
    ///      ✗ GUARD ABSENT : bridgeActive n'est PAS vérifié
    ///      => Permet de minter OHM même après arrêt d'urgence de la gouvernance
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

        // Effacer le message stocké
        failedMessages[srcChainId_][srcAddress_][nonce_] = bytes32(0);

        // ✗ GUARD ABSENT : retryMessage ne vérifie PAS bridgeActive
        // APPEL DIRECT à _receiveMessage → mint OHM sans restriction
        _receiveMessage(srcChainId_, srcAddress_, nonce_, payload_);

        emit RetryMessageSuccess(srcChainId_, srcAddress_, nonce_, payloadHash);
    }

    // ---- Admin Functions ----

    /// @notice Activer/désactiver le pont (mécanisme d'arrêt d'urgence)
    function setBridgeStatus(bool active_) external {
        require(msg.sender == admin, "Not admin");
        bridgeActive = active_;
        emit BridgeStatusSet(active_);
    }

    /// @notice Configurer un trusted remote
    function setTrustedRemote(uint16 srcChainId_, bytes calldata path_) external {
        require(msg.sender == admin, "Not admin");
        trustedRemoteLookup[srcChainId_] = path_;
    }
}

// ============================================================
// CrossChainBridgePOC_FIXED : Version corrigée
// Démontre que la mitigation est efficace
// ============================================================
contract CrossChainBridgePOC_FIXED is CrossChainBridgePOC {

    constructor(address mintr_, address endpoint_) CrossChainBridgePOC(mintr_, endpoint_) {}

    /// @notice Version corrigée de _receiveMessage
    /// @dev MITIGATION : vérification de bridgeActive ajoutée en tête de fonction
    ///      Protège TOUS les chemins entrants : lzReceive, receiveMessage, retryMessage
    function _receiveMessage(
        uint16 srcChainId_,
        bytes memory srcAddress_,
        uint64 nonce_,
        bytes memory payload_
    ) internal override {
        // ✓ GUARD PRÉSENT : vérification atomique couvrant tous les vecteurs
        if (!bridgeActive) revert Bridge_Deactivated();

        (address to, uint256 amount) = abi.decode(payload_, (address, uint256));
        MINTR.increaseMintApproval(address(this), amount);
        MINTR.mintOhm(to, amount);

        emit BridgeReceived(to, amount, srcChainId_);
    }
}
