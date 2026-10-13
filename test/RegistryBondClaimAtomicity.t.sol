// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ProjectRegistry} from "src/ProjectRegistry.sol";
import {OracleAttestation} from "src/oracle/OracleAttestation.sol";
import {MockIntake, MockProject} from "./mocks/MockIntake.sol";

/// @dev Injects failures AFTER moving tokens, to test rollback of the whole claim.
/// These behaviors are test scenarios, not assertions about the deployed IMD token.
contract ClaimFaultIMD is ERC20 {
    address public blocked;
    uint8 public mode;
    bool public notifyRecipient;

    error RefusedAfterTransfer();

    constructor() ERC20("Claim fault IMD", "cfIMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(address blocked_, uint8 mode_, bool notify_) external {
        blocked = blocked_;
        mode = mode_;
        notifyRecipient = notify_;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blocked) return false;
        super.transfer(to, amount);
        if (notifyRecipient) ClaimRecipient(to).onPayment();
        if (mode == 1) return false;
        if (mode == 2) revert RefusedAfterTransfer();
        if (mode == 3) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}

contract ClaimRecipient {
    ProjectRegistry public immutable registry;
    uint256 public observedDebt;
    bool public nestedSucceeded;
    bytes public nestedError;

    constructor(ProjectRegistry registry_) {
        registry = registry_;
    }

    function claim(address to) external {
        registry.claimBond(to);
    }

    function onPayment() external {
        observedDebt = registry.bondOwed(address(this));
        (nestedSucceeded, nestedError) =
            address(registry).call(abi.encodeCall(ProjectRegistry.claimBond, (address(this))));
    }
}

contract RegistryBondClaimAtomicityTest is Test {
    uint256 internal constant BOND = 20e18;
    uint256 internal constant KEY = 0xA11CE;
    ClaimFaultIMD internal token;
    MockIntake internal intake;
    ProjectRegistry internal registry;
    ClaimRecipient internal recipient;
    address internal project;
    address internal otherProject;
    address internal payout = makeAddr("claim payout");
    bytes32 internal otherRequest;
    uint256 internal nonce;

    function setUp() public {
        vm.chainId(1);
        vm.warp(1_792_000_000);
        vm.roll(26_178_270);
        token = new ClaimFaultIMD();
        intake = new MockIntake();
        registry = new ProjectRegistry(
            address(intake),
            address(token),
            0x06909F672301F28A810f78cfe7a754851269F4F0,
            vm.addr(KEY),
            1,
            BOND,
            7 days
        );
        recipient = new ClaimRecipient(registry);
        token.mint(address(this), 200e18);
        token.approve(address(registry), type(uint256).max);
        project = address(new MockProject());
        otherProject = address(new MockProject());
        _list(project);
        _list(otherProject);
        vm.warp(block.timestamp + 7 days);
        bytes32 id = registry.challengeForBeneficiary(project, "Review.", address(recipient));
        otherRequest = registry.challengeForBeneficiary(otherProject, "Review.", address(recipient));
        token.configure(address(recipient), 0, false);
        _answer(id, true);
        assertEq(registry.bondOwed(address(recipient)), BOND);
        assertEq(token.balanceOf(address(registry)), 2 * BOND);
        token.configure(address(0), 0, false);
    }

    function test_falseReturnAfterTransferRollsBackClaimAndCanRetry() public {
        _failedTransfer(1);
    }

    function test_revertAfterTransferRollsBackClaimAndCanRetry() public {
        _failedTransfer(2);
    }

    function _failedTransfer(uint8 mode) internal {
        bytes32 otherState = keccak256(abi.encode(registry.projectOf(otherProject)));
        uint256 treasuryBefore = token.balanceOf(intake.TREASURY());
        token.configure(address(0), mode, false);
        if (mode == 1) {
            vm.expectRevert(
                abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token))
            );
        } else {
            vm.expectRevert(ClaimFaultIMD.RefusedAfterTransfer.selector);
        }
        recipient.claim(payout);
        assertEq(
            registry.bondOwed(address(recipient)), BOND, "failed transfer destroyed entitlement"
        );
        assertEq(token.balanceOf(payout), 0, "failed claim transferred funds");
        assertEq(token.balanceOf(address(registry)), 2 * BOND);
        assertEq(token.balanceOf(intake.TREASURY()), treasuryBefore);
        assertEq(keccak256(abi.encode(registry.projectOf(otherProject))), otherState);
        _assertOtherBondOpen();

        token.configure(address(0), 0, false);
        vm.expectEmit(address(registry));
        emit ProjectRegistry.BondClaimed(address(recipient), payout, BOND);
        recipient.claim(payout);
        _assertClaimPaid(payout);
        vm.expectRevert(ProjectRegistry.NothingOwed.selector);
        recipient.claim(payout);
    }

    function test_reentrantRecipientCannotClaimTwiceOrConsumeAnotherBond() public {
        token.configure(address(0), 0, true);
        recipient.claim(address(recipient));
        assertEq(recipient.observedDebt(), 0, "debt must be cleared before token interaction");
        assertFalse(recipient.nestedSucceeded());
        assertEq(
            recipient.nestedError(),
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        _assertClaimPaid(address(recipient));
        token.configure(address(0), 0, false);
        // The other request remains independently refundable after the attempted reentry.
        uint256 before = token.balanceOf(address(this));
        assertTrue(intake.fail(otherRequest, 2, "disagreed", 200_000));
        assertEq(token.balanceOf(address(this)), before + BOND);
        assertEq(token.balanceOf(address(registry)), 0);
    }

    function test_noReturnTokenCanPayAClaimWithoutLeavingPhantomDebt() public {
        token.configure(address(0), 3, false);
        recipient.claim(payout);
        _assertClaimPaid(payout);
        vm.expectRevert(ProjectRegistry.NothingOwed.selector);
        recipient.claim(payout);
    }

    function test_noReturnTokenCanSettleTheOtherBondWithoutRecordingDebt() public {
        token.configure(address(0), 3, false);
        _answer(otherRequest, true);
        assertEq(token.balanceOf(address(recipient)), BOND);
        assertEq(
            registry.bondOwed(address(recipient)), BOND, "successful payout created phantom debt"
        );
        assertEq(uint8(registry.projectOf(otherProject).ask), uint8(ProjectRegistry.Ask.None));
        recipient.claim(payout);
        assertEq(token.balanceOf(payout), BOND);
        assertEq(registry.bondOwed(address(recipient)), 0);
        assertEq(token.balanceOf(address(registry)), 0);
    }

    function _assertClaimPaid(address to) internal view {
        assertEq(registry.bondOwed(address(recipient)), 0);
        assertEq(token.balanceOf(to), BOND);
        assertEq(token.balanceOf(address(registry)), BOND, "another project's bond was spent");
        _assertOtherBondOpen();
    }

    function _assertOtherBondOpen() internal view {
        assertEq(registry.projectOfIntake(otherRequest), otherProject);
        assertEq(uint8(registry.projectOf(otherProject).ask), uint8(ProjectRegistry.Ask.Challenge));
        assertTrue(registry.isListed(otherProject));
    }

    function _list(address target) internal {
        bytes32 id = registry.applyListing(
            target, "Venue", "https://example.org/venue", 100, address(recipient)
        );
        _answer(id, true);
    }

    function _answer(bytes32 id, bool yes) internal {
        OracleAttestation.Attestation memory a;
        a.requestId = bytes32(++nonce << 128);
        a.chainId = 1;
        a.answer = abi.encode(yes);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 11;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, registry.attestationDigest(a));
        assertTrue(
            intake.deliver(id, a, abi.encodePacked(r, s, v), 200_000), "callback must settle"
        );
    }
}
