// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ProjectRegistry} from "src/ProjectRegistry.sol";
import {OracleAttestation} from "src/oracle/OracleAttestation.sol";
import {BlocklistIMD} from "./RegistryBondOwed.t.sol";
import {MockIntake, MockProject} from "./mocks/MockIntake.sol";

/// @dev Complements the existing listing model with independent unpaid-bond accounting.
/// Blocklisting is fault injection, not a claim about the live IMD's transfer behavior.
contract DeferredBondHandler is Test {
    uint256 public constant BOND = 20e18;
    uint256 public constant FEE = 0.5e18;
    uint256 public constant INITIAL_FUNDS = 100_000e18;
    uint256 internal constant KEY = 0xA11CE;

    struct Question {
        bool listed;
        address beneficiary;
        address challenger;
        bytes32 id;
        bytes32 closedId;
        uint64 askedAt;
        uint64 cooldown;
        uint64 handoffAt;
    }

    ProjectRegistry public immutable registry;
    MockIntake public immutable intake;
    BlocklistIMD public immutable token;
    address[5] public actors;
    address[3] public projects;
    Question[3] internal questions;
    mapping(address => uint256) public funds;
    mapping(address => uint256) public debt;
    mapping(address => bool) internal blocked;
    bool internal returnsFalse;
    uint256 public fees;
    uint256 public donations;
    uint256 public openBonds;
    uint256 public posted;
    uint256 public paid;
    uint256 public deferred;
    uint256 public claimed;
    uint256 public failedClaims;
    uint256 public handoffs;
    uint256[6] public outcomes;
    uint256 internal nonce;

    constructor(ProjectRegistry registry_, MockIntake intake_, BlocklistIMD token_) {
        registry = registry_;
        intake = intake_;
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            address actor = makeAddr(string.concat("deferred bond actor ", vm.toString(i)));
            actors[i] = actor;
            token.mint(actor, INITIAL_FUNDS);
            funds[actor] = INITIAL_FUNDS;
            vm.prank(actor);
            token.approve(address(registry), type(uint256).max);
        }
        for (uint256 i; i < projects.length; ++i) {
            projects[i] = address(new MockProject());
            questions[i].beneficiary = actors[i];
            _list(i, actors[4]);
        }
    }

    function openChallenge(uint256 projectSeed, uint256 actorSeed) public {
        uint256 index = projectSeed % projects.length;
        Question storage q = questions[index];
        address payer = actors[actorSeed % actors.length];
        if (q.id != bytes32(0)) {
            vm.prank(payer);
            vm.expectRevert(ProjectRegistry.AskOpen.selector);
            registry.challengeForBeneficiary(projects[index], "Review the fees.", q.beneficiary);
            return;
        }
        if (!q.listed) _list(index, payer);
        if (block.timestamp < q.cooldown) vm.warp(q.cooldown);
        vm.prank(payer);
        bytes32 id =
            registry.challengeForBeneficiary(projects[index], "Review the fees.", q.beneficiary);
        funds[payer] -= FEE + BOND;
        fees += FEE;
        posted += BOND;
        openBonds += BOND;
        q.id = id;
        q.challenger = payer;
        q.askedAt = uint64(block.timestamp);
    }

    /// @dev 0 defend, 1 delist, 2 refuse, 3 disagree, 4 lost callback, 5 deadline expiry.
    function resolve(uint256 projectSeed, uint8 rawOutcome) public {
        uint256 index = projectSeed % projects.length;
        Question storage q = questions[index];
        if (q.id == bytes32(0)) return;
        uint256 outcome = bound(rawOutcome, 0, 5);
        address recipient = q.challenger;
        if (outcome < 2) {
            OracleAttestation.Attestation memory a = _attestation(outcome == 0);
            bool delivered = intake.deliver(q.id, a, _sign(a), 200_000);
            if (block.timestamp > uint256(q.askedAt) + 1 days) {
                assertFalse(delivered, "late result must not spend a bond");
                assertFalse(registry.consumed(a.requestId), "failed result consumed UUID");
                registry.expire(projects[index]);
            } else {
                assertTrue(delivered, "valid result must settle within 200k");
                assertTrue(registry.consumed(a.requestId));
                if (outcome == 0) recipient = q.beneficiary;
                else q.listed = false;
            }
        } else if (outcome < 4) {
            assertTrue(
                intake.fail(q.id, outcome == 2 ? 1 : 2, "disagreed", 200_000),
                "failure callback must release the slot within 200k"
            );
        } else {
            if (outcome == 4) {
                intake.completeSilently(q.id);
            } else {
                uint256 deadline = uint256(q.askedAt) + 1 days + 1;
                if (block.timestamp < deadline) vm.warp(deadline);
            }
            vm.prank(actors[4]); // recovery caller need not be the bond's owner
            registry.expire(projects[index]);
        }
        outcomes[outcome]++;
        openBonds -= BOND;
        if (blocked[recipient]) {
            debt[recipient] += BOND;
            deferred += BOND;
        } else {
            funds[recipient] += BOND;
            paid += BOND;
        }
        q.closedId = q.id;
        q.id = bytes32(0);
        q.challenger = address(0);
    }

    function paymentPolicy(uint256 actorSeed, bool isBlocked, bool falseReturn) public {
        address actor = actors[actorSeed % actors.length];
        blocked[actor] = isBlocked;
        returnsFalse = falseReturn;
        token.setBlocked(actor, isBlocked);
        token.setReturnFalse(falseReturn);
    }

    /// @dev Choose the whole debt, including zero, and destinations independently of its owner.
    function claim(uint256 actorSeed, uint256 recipientSeed) public {
        address actor = actors[actorSeed % actors.length];
        uint256 destination = recipientSeed % (actors.length + 1);
        address to = destination == actors.length ? address(0) : actors[destination];
        uint256 amount = debt[actor];
        vm.prank(actor);
        if (to == address(0)) {
            vm.expectRevert(ProjectRegistry.ZeroAddress.selector);
        } else if (amount == 0) {
            vm.expectRevert(ProjectRegistry.NothingOwed.selector);
        } else if (blocked[to]) {
            if (returnsFalse) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        SafeERC20.SafeERC20FailedOperation.selector, address(token)
                    )
                );
            } else {
                vm.expectRevert("blocked");
            }
        }
        registry.claimBond(to);
        if (to == address(0) || amount == 0 || blocked[to]) {
            failedClaims++;
        } else {
            debt[actor] = 0;
            funds[to] += amount;
            claimed += amount;
        }
    }

    function handoff(uint256 projectSeed, uint256 actorSeed) public {
        uint256 index = projectSeed % projects.length;
        Question storage q = questions[index];
        address to = actors[actorSeed % actors.length];
        vm.prank(q.beneficiary);
        if (!q.listed) {
            vm.expectRevert(ProjectRegistry.NotListed.selector);
        } else if (q.id != bytes32(0)) {
            vm.expectRevert(ProjectRegistry.AskOpen.selector);
        } else if (to != q.beneficiary && block.timestamp < q.handoffAt) {
            vm.expectRevert(
                abi.encodeWithSelector(ProjectRegistry.HandoffTooSoon.selector, q.handoffAt)
            );
        }
        registry.setBeneficiary(projects[index], to);
        if (!q.listed || q.id != bytes32(0)) return;
        if (to != q.beneficiary && block.timestamp < q.handoffAt) return;
        if (to != q.beneficiary) {
            q.handoffAt = uint64(block.timestamp + 1 days);
            handoffs++;
        }
        q.beneficiary = to;
    }

    function donate(uint256 actorSeed, uint96 rawAmount) public {
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(rawAmount, 0, 1e18);
        vm.prank(actor);
        assertTrue(token.transfer(address(registry), amount));
        funds[actor] -= amount;
        donations += amount;
    }

    function advance(uint32 rawSeconds) public {
        vm.warp(block.timestamp + bound(rawSeconds, 0, 8 days));
        vm.roll(block.number + 1);
    }

    function replayFailure(uint256 projectSeed) public {
        bytes32 id = questions[projectSeed % projects.length].closedId;
        if (id == bytes32(0)) return;
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(ProjectRegistry.UnknownRequest.selector, id));
        registry.onOracleFailure(id, 2, "disagreed", 0, 0, "");
    }

    function _list(uint256 index, address payer) internal {
        Question storage q = questions[index];
        vm.prank(payer);
        bytes32 id = registry.applyListing(
            projects[index], "Venue", "https://example.org/venue", 25, q.beneficiary
        );
        funds[payer] -= FEE;
        fees += FEE;
        OracleAttestation.Attestation memory a = _attestation(true);
        assertTrue(intake.deliver(id, a, _sign(a), 200_000), "application must list");
        q.listed = true;
        q.cooldown = uint64(block.timestamp + 7 days);
    }

    function _attestation(bool yes) internal returns (OracleAttestation.Attestation memory a) {
        a.requestId = bytes32(++nonce << 128);
        a.chainId = 1;
        a.answer = abi.encode(yes);
        a.panelSize = 15;
        a.quorum = 11;
        a.agreed = 11;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, registry.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function assertConservation() public view {
        uint256 owed;
        uint256 actorFunds;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            assertEq(token.balanceOf(actor), funds[actor], "incorrect payment recipient or amount");
            assertEq(registry.bondOwed(actor), debt[actor], "deferred debt changed incorrectly");
            owed += debt[actor];
            actorFunds += token.balanceOf(actor);
        }
        assertEq(
            token.balanceOf(address(registry)),
            openBonds + owed + donations,
            "custody != liabilities + donations"
        );
        assertEq(posted, openBonds + paid + deferred, "every posted bond settled at most once");
        assertEq(deferred, claimed + owed, "every deferred bond claimed at most once");
        assertEq(token.balanceOf(intake.TREASURY()), fees, "treasury receives only oracle fees");
        assertEq(
            token.allowance(address(registry), address(intake)), 0, "no permission to pull bonds"
        );
        assertEq(token.balanceOf(address(intake)), 0);
        assertEq(token.totalSupply(), actors.length * INITIAL_FUNDS, "fixed campaign supply");
        assertEq(
            actorFunds + token.balanceOf(address(registry)) + fees,
            token.totalSupply(),
            "untracked token outflow"
        );
    }

    function assertQuestions() public view {
        uint256 pending;
        for (uint256 i; i < projects.length; ++i) {
            Question memory q = questions[i];
            ProjectRegistry.Project memory p = registry.projectOf(projects[i]);
            assertEq(p.listed, q.listed, "claims/failures changed listing");
            assertEq(p.beneficiary, q.beneficiary, "debt must not control the beneficiary");
            assertEq(p.challengeOpenAt, q.cooldown, "defense renewed cooldown");
            assertEq(p.intakeId, q.id);
            assertEq(p.asker, q.challenger);
            assertEq(
                uint8(p.ask),
                uint8(q.id == bytes32(0) ? ProjectRegistry.Ask.None : ProjectRegistry.Ask.Challenge)
            );
            if (q.id != bytes32(0)) {
                assertEq(registry.projectOfIntake(q.id), projects[i]);
                pending++;
            }
            if (q.closedId != bytes32(0)) {
                assertEq(registry.projectOfIntake(q.closedId), address(0));
            }
        }
        assertEq(openBonds, pending * BOND, "one reserved bond for each open challenge");
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RegistryDeferredBondInvariantTest is StdInvariant, Test {
    DeferredBondHandler internal handler;

    function setUp() public {
        vm.chainId(1);
        vm.roll(26_178_270);
        vm.warp(1_792_000_000);
        MockIntake intake = new MockIntake();
        BlocklistIMD token = new BlocklistIMD();
        ProjectRegistry registry = new ProjectRegistry(
            address(intake),
            address(token),
            0x06909F672301F28A810f78cfe7a754851269F4F0,
            vm.addr(0xA11CE),
            1,
            20e18,
            7 days
        );
        handler = new DeferredBondHandler(registry, intake, token);

        // Every campaign starts with unpaid debt AND other projects' live bonds.
        handler.openChallenge(0, 3);
        handler.paymentPolicy(0, true, false);
        handler.resolve(0, 0);
        handler.openChallenge(0, 3);
        handler.openChallenge(1, 3);
        handler.openChallenge(2, 4);
        _check();

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.openChallenge.selector;
        selectors[1] = handler.resolve.selector;
        selectors[2] = handler.paymentPolicy.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.handoff.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.advance.selector;
        selectors[7] = handler.replayFailure.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_liveBondsAndDeferredClaimsRemainFullyBacked() public view {
        handler.assertConservation();
    }

    function invariant_deferredClaimsDoNotChangeQuestionsOrImmunity() public view {
        handler.assertQuestions();
    }

    /// @dev Under a recoverable token refusal every remaining liability is withdrawable.
    function afterInvariant() public {
        for (uint256 i; i < 5; ++i) {
            handler.paymentPolicy(i, false, false);
        }
        for (uint256 i; i < 3; ++i) {
            handler.resolve(i, 5);
        }
        for (uint256 i; i < 5; ++i) {
            handler.claim(i, i);
        }
        _check();
        assertEq(handler.openBonds(), 0);
        assertEq(handler.deferred(), handler.claimed(), "all debts recoverable");
        assertEq(handler.token().balanceOf(address(handler.registry())), handler.donations());
    }

    function test_accumulatedClaimsCannotSpendOtherProjectsOpenBonds() public {
        handler.resolve(0, 0); // second deferred defense to actor 0
        assertEq(handler.debt(handler.actors(0)), 40e18);
        assertEq(handler.openBonds(), 40e18);
        _check();
        handler.claim(0, 0); // reverting token, debt preserved
        handler.paymentPolicy(0, true, true);
        handler.claim(0, 0); // false-returning token, same debt preserved
        handler.claim(1, 0); // another caller cannot claim actor 0's debt
        handler.claim(0, 5); // zero destination must preserve the debt
        _check();
        handler.handoff(0, 4); // historical debt stays with the former beneficiary
        handler.claim(4, 4); // new beneficiary did not inherit the historical debt
        handler.claim(0, 2); // former beneficiary redirects the entire accrued debt
        handler.claim(0, 2); // double claim refused
        handler.replayFailure(0); // settled callback cannot create another refund
        _check();
        assertEq(handler.claimed(), 40e18);
        assertEq(handler.openBonds(), 40e18);
        assertEq(handler.handoffs(), 1);
        assertEq(handler.failedClaims(), 6);
        afterInvariant();
    }

    function test_handlerExercisesEverySettlementAndRefundRecipient() public {
        handler.paymentPolicy(3, true, true);
        handler.resolve(1, 1); // delisted, debt to blocked challenger
        _check();
        handler.resolve(2, 2); // refused, refund to unblocked challenger
        _check();
        handler.resolve(0, 3); // disagreement, debt to blocked challenger
        _check();
        handler.openChallenge(0, 4);
        handler.resolve(0, 4); // completed without a callback
        _check();
        handler.openChallenge(2, 3);
        handler.resolve(2, 5); // deadline refund to blocked challenger
        _check();
        handler.openChallenge(1, 3); // relist and challenge while old debts remain
        handler.advance(2 days);
        handler.resolve(1, 0); // late signed answer refunds, never pays beneficiary
        _check();
        handler.donate(4, 1); // one wei of surplus must not mask a missing bond
        for (uint256 i; i < 6; ++i) {
            assertGt(handler.outcomes(i), 0);
        }
        afterInvariant();
    }

    function _check() internal view {
        handler.assertConservation();
        handler.assertQuestions();
    }
}
