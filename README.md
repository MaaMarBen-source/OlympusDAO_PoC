# OlympusDAO CrossChainBridge PoC 🚨

**Security PoC** – reproduces a critical vulnerability in OlympusDAO V3 `CrossChainBridge.sol`.

The bug allows **unauthorized minting of OHM** via `retryMessage()` even when `bridgeActive = false`.

---

## Repository


CrossChainBridgePOC.sol # Vulnerable bridge
CrossChainBridge_POC.t.sol # Tests & exploit demo
MockContracts.sol # Mock OHM, MINTR & LayerZero
test_results.txt # Test output


---

## Setup

- Solidity ^0.8.15  
- Foundry: [https://github.com/foundry-rs/foundry](https://github.com/foundry-rs/foundry)  

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
git clone https://github.com/MaaMarBen-source/OlympusDAO_PoC.git
cd OlympusDAO_PoC
forge test -vvv
Vulnerability

_receiveMessage() & retryMessage() ignore bridgeActive

Impact: Unauthorized minting, emergency shutdown bypassed, treasury dilution

Attack vectors: retryMessage() (public), lzReceive() (endpoint compromised)

Mitigation
function _receiveMessage(...) internal override {
    if (!bridgeActive) revert Bridge_Deactivated();
}

Ensures all inbound messages respect the emergency shutdown.

Disclaimer

For research & educational purposes only. Do not use on mainnet or with real funds.

Author: MaaMarBen – OlympusDAO V3 CrossChainBridge PoC
