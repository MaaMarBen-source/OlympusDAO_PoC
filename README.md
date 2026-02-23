OlympusDAO CrossChainBridge Zero-Day PoC

This repository contains a reproducible Proof-of-Concept (PoC) for a critical vulnerability in the OlympusDAO V3 CrossChainBridge contract.

🚨 Vulnerability Overview

The CrossChainBridge contract fails to enforce the bridgeActive shutdown invariant on inbound message execution paths, specifically within the retryMessage() and _receiveMessage() functions. This allows an attacker to mint OHM tokens even after governance has activated the emergency shutdown mechanism.

Key Findings

•
Emergency Shutdown Bypass: Governance safety controls (bridgeActive = false) are ignored for pending messages in the retry queue.

•
Permissionless Minting: The retryMessage() function is public and permissionless, allowing any actor to trigger the minting logic.

•
Reachability: Any user can intentionally cause cross-chain message failures to populate the failedMessages queue, creating a persistent mint authorization that survives a protocol shutdown.

🛠 Setup & Reproduction

Prerequisites

•
Foundry installed.

Execution

Bash


# Clone the repository
git clone https://github.com/MaaMarBen-source/OlympusDAO_PoC.git
cd OlympusDAO_PoC

# Install dependencies (forge-std )
forge install

# Run the exploit tests
forge test -vvv



Expected Output

The test suite demonstrates the following:

1.
Test 2: Confirms OHM can be minted via retryMessage while bridgeActive is false.

2.
Test 8: Demonstrates that a malicious receiver can permissionlessly force messages into the failedMessages queue.

📈 Economic Impact Analysis

The impact is classified as Critical due to the potential for unbacked token creation and treasury dilution.

Metric
Current Value (Est.)
Impact (1M OHM Mint)
OHM Price
~$17.12
-
Circulating Supply
~15.6M OHM
+6.39% Dilution
Realizable Value
-
~$17.12M USD




Anti-Downgrade Arguments:

•
No Global Supply Conservation: The burn on the source chain corresponds to a failed transfer. The subsequent mint after shutdown represents a new supply creation that governance intended to prevent.

•
Not a Design Choice: No audit (OtterSec) or documentation (OIP-138) mentions a deliberate bypass of shutdown for retries. The omission is a security flaw, not a feature.

🛡 Mitigation

Add a bridgeActive check at the final execution boundary in _receiveMessage:

Plain Text


function _receiveMessage(...) internal virtual {
    if (!bridgeActive) revert Bridge_Deactivated();
    // ... existing mint logic
}






Author: MaaMarBen
Disclaimer: This PoC is for security research purposes only.

