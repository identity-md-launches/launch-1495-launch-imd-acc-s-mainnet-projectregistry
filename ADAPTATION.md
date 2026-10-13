# Mainnet ProjectRegistry adaptation

This delivery prepares the single ProjectRegistry already listed in `launch.json` for the
network's deployment step. It keeps the requested ownerless design and version 3.1 panel rules.
The only production change is the reproduced audit fix below. Consequently, the registry's
bytecode differs from Sepolia test run 6; this is the acceptance criteria's exception for a
reproduced audit finding, not a change to the panel policy or launch settings.

## Changes and reasons

| File | Change | Requirement or finding |
| --- | --- | --- |
| `src/ProjectRegistry.sol` | Add `InvalidBeneficiary()` and reject `beneficiary == address(this)` in `applyListing` and `setBeneficiary`. The existing zero-address checks remain. | Audit `8775c1bae1060deb50ba171f2c8ad9aa5519cc56f574dfd2d22967241055e244`: prevent defended challenge bonds from being paid through an unrecoverable ERC-20 self-transfer. |
| `test/RegistrySelfBeneficiary.t.sol` | Six tests using a 20 IMD bond and seven-day cooldown: reject the registry on application, including a project whose owner is the registry; reject handoff without changing terms or using the daily handoff; preserve ordinary defended payouts and contract beneficiaries; reproduce the accepted self-challenge limit. | Regression coverage for the fix and evidence that the agreed behavior is retained. |
| `test/RegistryMainnetLaunch.t.sol` | Deploy exactly the manifest's registry through a local CREATE2 factory on an empty chain with chain ID 1. Check every constructor argument, predicted address, absence of additional deployments, runtime size and forbidden opcodes. | The factory must configure the contract in one nonpayable constructor call, without live dependencies or initialization. The Stacker must not be redeployed. |
| `ADAPTATION.md` | Record the changes, audit dispositions, checks and deployment handoff. | Assignment acceptance criteria. |

`launch.json`, `src/Stacker.sol`, `src/oracle/OracleAttestation.sol`, panel rule text, build
configuration and vendored dependencies are unchanged. No workflow, dependency, launch token,
owner, proxy, initializer, upgrade, pause or recovery authority was added.

## Imported audit dispositions

**8775c1bae106 — self-beneficiary bond loss: reproduced and fixed.** Before changing production
code, ran the supplied proof from `test/scratch/RegistrySelfBeneficiaryProof.t.sol`. Both tests
failed as reported: a defended challenge left exactly `20e18` IMD in the registry with no
`bondOwed` entitlement, and handoff to the registry did not revert. The fix refuses this
beneficiary at both points where it could enter project state, before any application fee or
request. It leaves settlement and `bondOwed` accounting unchanged. New regression tests use
the project's existing mocks; the registry-owned project's application comes through an actual
call by the project itself. Valid treasury contracts remain permitted.

**9525ba500984 — self-challenge slot occupation: reproduced, accepted, unchanged.** A listed
project's beneficiary can challenge after cooldown. An outsider receives `AskOpen` while that
question is pending. A signed defense returns the 20 IMD bond to the beneficiary, so the round
costs only the live oracle fee (0.5 IMD in the test). The listing's start block and
`challengeOpenAt` remain unchanged, and an outsider can challenge immediately after settlement.
Each round judges all rules again and grants no new immunity; unanswered requests can be
expired after a day. Refusing only the beneficiary as caller would not prevent another wallet
from doing the same. This is the limit explicitly accepted in the brief and in launches
#1371, #1378, #1428 and #1463. The new regression records it without imposing a restriction.

**f51ed7a97611 — review scope and coverage: informational.** Reviewed the registry and oracle
attestation source, supplied launch and oracle references, protected deployment floor,
manifest, README, panel rules, and relevant application, bond, callback, conformance and
deployment tests. The library's 15-field attestation, type hash and consumer-domain constants
match the supplied protocol vector. Its existing ECDSA-first/ERC-1271 fallback is retained,
including support for a signing key with code. The result and failure selectors remain
`0x510379c7` and `0xa7980e31`. There is no constructor external call or owner authority.
The already-live Stacker and trial contracts are outside this adaptation's production scope;
their existing offline tests still run in the full suite. This local review does not replace
the independent launch audit. No actionable imported finding was dismissed as irreproducible.

The task's explicit ownerless design takes precedence over the reference examples' owner-settable
protocol addresses and optional v1 fallback. The registry continues to use Intake v2 and its
live `priceOf` quote, settle inside the callback, and return only the original challenger's bond
on failure or expiry. No generic example settings or administrative powers were introduced.

## Validation

- Baseline: `forge test --no-match-path 'test/scratch/**'` passed 232 tests with 14 skipped.
- Targeted: `forge test --match-path 'test/Registry{SelfBeneficiary,MainnetLaunch}.t.sol' -vv`
  passed all seven new tests.
- `forge build` passed. `forge test` passed 239 tests with zero failures and 14 skips
  (253 total across 39 suites). Both used the unchanged project configuration: Solidity
  0.8.26, Cancun, 10,000 optimizer runs, metadata bytecode hash disabled, and the existing fuzz
  and invariant settings.
- Final registry runtime: 23,427 bytes (1,149 bytes below EIP-170). Creation code plus the
  seven constructor words: 25,230 bytes, below the 49,152-byte init-code limit. No unlinked
  library references or forbidden runtime opcodes. The local factory rehearsal succeeds with
  no code at the mainnet dependency addresses.
- Existing tests cover live fee reads through mocks, owner-only applications, panel rules,
  signature and replay checks, failures/expiry, refused transfers and deferred bond claims,
  handoff intervals, and cold callbacks within the 200,000-gas budget. Existing accounting
  invariants run as part of the full suite.
- Neither `ETH_RPC_URL` nor `SEPOLIA_RPC_URL` is set. The 12 existing fork tests skip, as do
  the two Stacker-only manifest tests. The brief's live reads at Ethereum block 26,178,270 and
  real-IMD callback measurements were not independently rerun here. No Slither or Mythril run
  is claimed.

## Deployment handoff

The existing manifest deploys only `ProjectRegistry` with Intake v2
`0xa43e6f75ee006411f79ac1c84120606c2330de82`, IMD
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, the live Stacker
`0x06909f672301f28a810f78cfe7a754851269f4f0`, signer
`0x5598aa9146215bc13eb26f2c692ad1461fd32982`, question chain `1`, bond
`20000000000000000000`, and cooldown `604800`. The constructor ABI is unchanged.

No transaction was broadcast and no deployment address was invented. After IMD's deployment
step confirms the mainnet registry address, that step can add it to README's Ethereum mainnet
Deployments table. The README address update is conditional on that confirmed deployment;
it does not require a key or a new address input for this source adaptation.
