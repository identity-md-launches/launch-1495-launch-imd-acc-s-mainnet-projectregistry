# Registry deferred bond coverage

These additions exercise the unchanged ProjectRegistry on a local chain with chain ID 1,
a 20 IMD bond, a seven-day cooldown, the specified Stacker address, and 200,000-gas
oracle callbacks. The Intake, token, and signing key are local fixtures. No Stacker is
deployed or called, and no transaction is broadcast.

`RegistryDeferredBondInvariant.t.sol` adds a handler with three projects and five funded
actors. Every campaign starts with an unpaid claim and three open challenge bonds.
Eight randomly interleaved actions open and settle challenges, change token refusal
behavior, claim to independently selected recipients, hand off beneficiaries, donate,
advance time, and replay closed failure callbacks. Inline settings request 256 runs
of depth 64 with unexpected reverts treated as failures.

Independent ledgers check after every action that:

- Registry custody equals open bonds plus unpaid claims plus unsolicited donations.
- Each actor receives exactly the payment or debt their challenge outcome entitles them to.
- Posted bonds split into open, immediately paid, and deferred amounts; deferred amounts
  split into claimed and still owed amounts, with no duplicate payment or lost entitlement.
- Intake allowances cannot spend retained bonds, and its treasury receives only fees.
- Claims and failures do not change listings, beneficiary rights, or challenge cooldowns.

After every campaign, token refusals are disabled, remaining questions are expired,
and every actor claims all remaining debt. Only the tracked donations may remain.
Deterministic handler tests exercise all six resolution paths, accumulated debt,
failed claims, former beneficiaries' rights, redirects, and concurrent custody.

`RegistryBondClaimAtomicity.t.sol` checks that a claim whose token transfers and then
returns false or reverts restores both the debt and token balances and can be retried.
It also checks reentry from a recipient during payment, claims and settlement with
empty token return data, and isolation of a second project's still-open bond.
Token faults are deliberate test inputs; they do not characterize the live IMD token.

The supplied references informed conservation, independent entitlement tracking,
failure assertions, bounded inputs, and deterministic coverage checks. Existing protocol
signature-vector, launch-manifest, owner-gate, rule-text, and callback-gas tests remain
in place. No additional dependency is required.

The beneficiary self-challenge slot limit remains **accepted**, as specified in the
assignment: a challenge can occupy the slot until settlement or expiry, but a defended
challenge does not restart immunity. Existing self-challenge regressions cover this;
the new handler also allows a beneficiary to be the challenger.

Run locally without network access:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

Existing mainnet and Sepolia fork tests still require their RPC settings. Local fixture
results do not independently verify live deployment bytecode, mainnet token behavior,
or off-chain panel decisions. Fork runs remain owed when RPC access is configured.
