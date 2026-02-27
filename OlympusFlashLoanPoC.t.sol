// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/OlympusFlashLoanPoC.sol";

contract OlympusFlashLoanPoCTest is Test {
    MockOHM ohm;
    MockDistributor distributor;
    MockStaking staking;
    FlashLoanAttacker attacker;

    address public constant ATTACKER_ADDRESS = address(0x1337);
    uint256 public constant INITIAL_OHM_SUPPLY = 1000000 * 10**9; // 1 million OHM
    uint256 public constant FLASH_LOAN_AMOUNT = 10000000 * 10**9; // 10 million OHM for flash loan

    function setUp() public {
        // Deploy MockOHM
        ohm = new MockOHM();

        // Deploy MockStaking (needs OHM address)
        staking = new MockStaking(address(ohm), address(0)); // Distributor address will be set later

        // Deploy MockDistributor (needs OHM and Staking addresses)
        distributor = new MockDistributor(address(ohm), address(staking));

        // Set distributor in staking contract
        staking.setDistributor(address(distributor));

        // Deploy FlashLoanAttacker
        attacker = new FlashLoanAttacker(address(ohm), address(distributor), address(staking));

        // Fund the staking contract with some initial OHM
        ohm.mint(address(staking), 1000 * 10**9); // 1000 OHM for staking

        // Give some OHM to the attacker for initial setup (if needed, not strictly for flash loan)
        ohm.mint(ATTACKER_ADDRESS, 100 * 10**9);

        // Approve attacker to spend OHM from ATTACKER_ADDRESS (if needed)
        vm.startPrank(ATTACKER_ADDRESS);
        ohm.approve(address(attacker), type(uint256).max);
        vm.stopPrank();
    }

    function testFlashLoanAttack() public {
        // Initial state
        uint256 initialStakingOHM = ohm.balanceOf(address(staking));
        uint256 initialReward = distributor.nextRewardFor(address(staking));

        console.log("Initial Staking OHM Balance:", initialStakingOHM);
        console.log("Initial Reward for Staking:", initialReward);

        // Calculate expected inflated reward during the attack
        uint256 expectedInflatedReward = ((initialStakingOHM + FLASH_LOAN_AMOUNT) * distributor.rewardRate()) / distributor.DENOMINATOR();

        // Expect the RewardCalculated event to be emitted during the attack with the inflated amount
        vm.expectEmit(true, true, true, true);
        emit MockDistributor.RewardCalculated(expectedInflatedReward);

        // Simulate the attack
        vm.startPrank(ATTACKER_ADDRESS);
        attacker.attack(FLASH_LOAN_AMOUNT);
        vm.stopPrank();

        // Verify the state after the attack (flash loan repaid)
        uint256 finalStakingOHM = ohm.balanceOf(address(staking));
        uint256 finalRewardForStaking = distributor.nextRewardFor(address(staking));

        console.log("Expected Inflated Reward (during attack):");
        console.log("  (Based on initial + flash loan amount)", expectedInflatedReward);
        console.log("Final Staking OHM Balance (after attack, flash loan repaid):");
        console.log("  (Should be initial balance)", finalStakingOHM);
        console.log("Final Reward for Staking (after attack, flash loan repaid):");
        console.log("  (Should be initial reward)", finalRewardForStaking);

        // Assert that the staking balance returns to normal after the flash loan is repaid
        assertEq(finalStakingOHM, initialStakingOHM, "Staking balance did not return to normal");

        // Assert that the reward for staking (after flash loan repaid) is the initial reward
        assertEq(finalRewardForStaking, initialReward, "Staking reward should return to normal after flash loan repaid");
    }
}
