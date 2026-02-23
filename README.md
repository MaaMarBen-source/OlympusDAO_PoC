OlympusDAO CrossChainBridge PoC





























Security PoC – demonstrates unauthorized OHM mint bypass in OlympusDAO V3 CrossChainBridge.sol.




1. Security Property Broken (Local Supply Immutability)

The Emergency Halt mechanism must guarantee that the local contract cannot issue new tokens once deactivated, regardless of the internal state of previously authorized messages or the cross-chain message lifecycle.

Result: VIOLATED. The bridgeActive = false flag fails to freeze the local supply for messages stored in the replay queue (failedMessages).

2. Reachability Analysis: Permissionless Exploitation

Insertion into failedMessages is not a privileged condition but an expected operational outcome of cross-chain delivery. Because destination execution depends on arbitrary receiver logic, any unprivileged actor can intentionally trigger execution failure, thereby creating a persistent mint authorization surviving emergency shutdown.

Permissionless Causality Chain:

1.
Unprivileged user deploys a malicious receiver contract (e.g., one that reverts intentionally).

2.
Bridge delivers a valid message to this receiver.

3.
Execution fails (controlled revert or gas limit), and the message is stored in failedMessages.

4.
Governance activates shutdown (bridgeActive = false).

5.
User executes retryMessage() permissionlessly to mint tokens despite the shutdown.

3. Economic Impact & Extraction Mechanism

Because retryMessage is permissionless, any external actor can execute pending mint authorizations after shutdown and immediately realize economic value without requiring privileged access.

Extraction Mechanism: Newly minted OHM tokens are immediately transferable and can be swapped against existing liquidity pools (e.g., Uniswap, Curve). This converts a protocol-authorized but unstoppable mint into externally realizable value, leading to a direct drain of liquidity and treasury backing. Once minted, OHM tokens are indistinguishable from legitimately bridged supply and cannot be revoked or programmatically clawed back.




Repository Structure

•
CrossChainBridgePOC.sol : Vulnerable bridge implementation

•
CrossChainBridge_POC.t.sol : Test suite & exploit demo (Test 8: Reachability)

•
MockContracts.sol : Mock OHM, MINTR & LayerZero Endpoint

•
test_results.txt : Detailed test output & traces




Setup & Execution

•
Solidity ^0.8.15

•
Foundry: https://github.com/foundry-rs/foundry

Bash


# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone and Test
git clone https://github.com/MaaMarBen-source/OlympusDAO_PoC.git
cd OlympusDAO_PoC
forge test -vvv



Mitigation

The shutdown check must be enforced at the final mint execution boundary, not only at user-facing entrypoints.

Plain Text


function _receiveMessage(... ) internal virtual {
    // ATOMIC MITIGATION: Guarantees local supply immutability
    if (!bridgeActive) revert Bridge_Deactivated();
    
    // ... mint logic
}






Disclaimer

For research & educational purposes only. Do not use on mainnet or with real funds.

Author: MaaMarBen – OlympusDAO V3 CrossChainBridge PoC

