// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RegistryBase} from "./ProjectRegistry.t.sol";
import {OwnedProject} from "./RegistryApplicantGate.t.sol";
import {ProjectRegistry} from "../src/ProjectRegistry.sol";
import {MockIntake, MintableIMD, MockProject} from "./mocks/MockIntake.sol";

/// @dev Regression for audit 8775c1bae106: a successful ERC-20 self-transfer must never
/// settle a defended bond into the registry's own balance without a recoverable entitlement.
contract RegistrySelfBeneficiaryTest is RegistryBase {
    uint256 internal constant MAINNET_BOND = 20e18;
    uint64 internal constant MAINNET_COOLDOWN = 7 days;

    function setUp() public override {
        vm.chainId(1);
        vm.roll(1_000);
        vm.warp(1_700_000_000);
        intake = new MockIntake();
        imd = new MintableIMD();
        reg = new ProjectRegistry(
            address(intake),
            address(imd),
            STACKER,
            vm.addr(SIGNER_KEY),
            QUESTION_CHAIN,
            MAINNET_BOND,
            MAINNET_COOLDOWN
        );
        project = address(new MockProject());
        _fund(applicant);
        _fund(challenger);
    }

    function test_applicationRefusesRegistryBeforeFeeOrRequest() public {
        uint256 funds = imd.balanceOf(applicant);
        uint256 approval = imd.allowance(applicant, address(reg));
        vm.prank(applicant);
        vm.expectRevert(ProjectRegistry.InvalidBeneficiary.selector);
        reg.applyListing(project, "Venue", "https://venue.example/src", 50, address(reg));

        assertEq(imd.balanceOf(applicant), funds);
        assertEq(imd.allowance(applicant, address(reg)), approval);
        assertEq(imd.balanceOf(intake.TREASURY()), 0);
        assertEq(intake.count(), 0);
        assertEq(uint8(reg.projectOf(project).ask), uint8(ProjectRegistry.Ask.None));
        assertEq(reg.projectOf(project).beneficiary, address(0));
        assertEq(imd.balanceOf(address(reg)), 0);
    }

    function test_registryOwnedProjectCannotApplyWithRegistryAsBeneficiary() public {
        OwnedProject owned = new OwnedProject(address(reg));
        imd.mint(address(owned), 1e18);
        assertEq(reg.projectOwner(address(owned)), address(reg));

        // A real call from the project passes the owner gate, but must fail the recipient gate.
        vm.expectRevert(ProjectRegistry.InvalidBeneficiary.selector);
        owned.applySelf(reg, address(imd), address(reg));
        assertEq(imd.balanceOf(address(owned)), 1e18);
        assertEq(intake.count(), 0);
        assertEq(uint8(reg.projectOf(address(owned)).ask), uint8(ProjectRegistry.Ask.None));
        assertFalse(reg.isListed(address(owned)));
        assertEq(imd.balanceOf(address(reg)), 0);
        assertEq(reg.bondOwed(address(reg)), 0);
    }

    function test_handoffRefusesRegistryAndPreservesBondRecipient() public {
        _listed();
        ProjectRegistry.Project memory before_ = reg.projectOf(project);
        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.InvalidBeneficiary.selector);
        reg.setBeneficiary(project, address(reg));

        assertEq(abi.encode(reg.projectOf(project)), abi.encode(before_));
        assertEq(reg.handoffOpenAt(project), 0);
        assertFalse(reg.beneficiaryPinRequired(project));

        // The rejected handoff does not change the recipient or prevent a normal challenge.
        vm.warp(before_.challengeOpenAt);
        vm.prank(challenger);
        bytes32 id = reg.challengeForBeneficiary(project, "Review all rules.", beneficiary);
        assertEq(imd.balanceOf(address(reg)), MAINNET_BOND);
        assertTrue(_answer(id, true), "defense fits the 200k callback budget");
        assertEq(imd.balanceOf(beneficiary), MAINNET_BOND);
        assertEq(imd.balanceOf(address(reg)), 0);
        assertEq(reg.bondOwed(address(reg)), 0);
    }

    function test_rejectedHandoffDoesNotConsumeDailyHandoff() public {
        _listed();
        vm.prank(beneficiary);
        vm.expectRevert(ProjectRegistry.InvalidBeneficiary.selector);
        reg.setBeneficiary(project, address(reg));

        address next = makeAddr("next beneficiary");
        vm.prank(beneficiary);
        reg.setBeneficiary(project, next);
        assertEq(reg.projectOf(project).beneficiary, next);
        assertEq(reg.handoffOpenAt(project), block.timestamp + 1 days);
        assertTrue(reg.beneficiaryPinRequired(project));
    }

    function test_contractBeneficiaryStillReceivesBondAndCanHandOff() public {
        // The test contract can receive IMD and call setBeneficiary, like a treasury wallet.
        beneficiary = address(this);
        _listed();
        vm.warp(reg.projectOf(project).challengeOpenAt);
        vm.prank(challenger);
        bytes32 id = reg.challengeForBeneficiary(project, "Review all rules.", beneficiary);
        assertTrue(_answer(id, true));
        assertEq(imd.balanceOf(beneficiary), MAINNET_BOND);
        assertEq(imd.balanceOf(address(reg)), 0);

        reg.setBeneficiary(project, applicant);
        assertEq(reg.projectOf(project).beneficiary, applicant);
        vm.warp(block.timestamp + 1 days);
        vm.prank(applicant);
        reg.setBeneficiary(project, beneficiary);
        assertEq(reg.projectOf(project).beneficiary, beneficiary);
    }

    /// @dev Audit 9525ba500984 is an accepted design limit, not a requested restriction.
    function test_acceptedSelfChallengeHoldsSlotUntilAnswerWithoutNewCooldown() public {
        _fund(beneficiary);
        _listed();
        ProjectRegistry.Project memory listed = reg.projectOf(project);
        vm.warp(listed.challengeOpenAt);
        uint256 funds = imd.balanceOf(beneficiary);
        uint256 fee = reg.ORACLE_FEE();

        vm.prank(beneficiary);
        bytes32 id = reg.challengeForBeneficiary(project, "Review all rules.", beneficiary);
        assertEq(imd.balanceOf(beneficiary), funds - fee - MAINNET_BOND);
        vm.prank(challenger);
        vm.expectRevert(ProjectRegistry.AskOpen.selector);
        reg.challengeForBeneficiary(project, "Review the fee guard.", beneficiary);

        assertTrue(_answer(id, true));
        assertEq(imd.balanceOf(beneficiary), funds - fee, "only the oracle fee was spent");
        assertEq(imd.balanceOf(address(reg)), 0);
        assertTrue(reg.isListed(project));
        assertEq(reg.projectOf(project).challengeOpenAt, listed.challengeOpenAt);
        assertEq(reg.projectOf(project).fromBlock, listed.fromBlock);
        vm.prank(challenger);
        reg.challengeForBeneficiary(project, "Review the fee guard.", beneficiary);
        assertEq(reg.projectOf(project).asker, challenger);
    }
}
