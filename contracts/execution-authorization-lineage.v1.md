# Execution authorization lineage v1

`contract.execution_authorization_lineage` defines closed audit receipts for Host-owned authorization
effects. The receipts let downstream consumers verify the exact authorization chain without turning
logs, counters, self-digests, or replay handles into an execution capability.

## Boundary

Every exported receipt fixes `evidence_role = audit-only`, `human_approval_required = false`,
`authorization_capability = false`, `execution_authorized = false`,
`promotion_authorized = false`, `reusable = false`, and
`source_max_uses = 1`. It binds one immutable repository commit plus the run,
trace, and dedup identities. Receipt validators require complete source bindings; shape validation or
partial caller-provided expectations are insufficient.

The authoritative claim state remains in the Host durable store. Raw claim IDs, fence tokens, state
MACs, runtime configuration secrets, physical workspace paths, credentials, commands, and capability
payloads are forbidden from this exported lineage. Each Host profile-policy, authorization-policy,
attestation, and verifier field fixes one non-interchangeable kind and relative-key grammar; URLs,
traversal, query, fragment, userinfo, and local
path syntax are rejected. Claim receipts expose only a domain-separated
`claim_fingerprint_sha256` computed by the trusted Host from the internal claim handle. A fingerprint
cannot be submitted to complete or replay the claim.

Possession or validation of a receipt does not authorize checkout, startup, test execution,
publication, promotion, or a gate effect. Receipts are one-way projections of authenticated Host state,
never inputs from which authority state may be reconstructed.

## Receipt chain

The fixed chain is:

```text
testing-project-profile-approval-claim-receipt.v1
  -> testing-structured-preauthorization-claim-receipt.v1
  -> testing-structured-execution-grant-verification-receipt.v1
  -> testing-structured-execution-claim-receipt.v1
  -> testing-structured-execution-completion-receipt.v1
  -> testing-execution-authorization-lineage-index.v1
```

The Profile receipt keeps persisted artifact SHA-256 and canonical Profile/Approval SHA-256 in
separate named fields. It is emitted only after trusted Approval authentication, point-of-use receipt
freshness validation, and a successful atomic single-use Profile claim.

The Preauthorization receipt binds the Profile claim receipt, preauthorization, Profile digest, Case
Catalog, StructuredPlan, ready Environment Receipt, trusted policy, and the preauthorization claim
fingerprint. The Grant verification receipt then binds the Preauthorization claim receipt, Grant,
parent authorization, plan, environment, trusted authority attestation, and exact verifier identity.

Execution claim and completion are distinct immutable receipts. The claim receipt binds the Grant
verification and Preauthorization claim receipts plus the exact operation and safe run-scoped execution
artifact root. It never contains result or completion fields. The completion receipt binds the claim
receipt to `<artifact-root>/execution.json`, `<artifact-root>/case-result-set.json`,
`<artifact-root>/evidence-manifest.json`, and the completion time.

The lineage index references all five receipts at fixed paths under:

```text
.testing/runs/<run-id>/authorization-lineage/
```

Receipt artifacts are persisted as canonical JSON. Index validation recomputes each receipt's canonical
JSON SHA-256 and requires its immutable ref, digest, value, and complete native source bindings. It
validates every receipt and all cross-receipt links. Every ref must resolve to the same run root;
cross-run, cross-repository, cross-plan, cross-environment, and cross-Grant substitutions fail closed
even if an attacker can reserialize the outer receipt. The chain also requires one continuous Host
authority, policy revision, Plan, and ready Environment Receipt from Preauthorization through Grant
and execution, plus monotonically ordered claim, verification, execution, completion, and index
timestamps.

## Host integration

The trusted Host must produce these receipts only after the corresponding real verifier or atomic
claim succeeds and persist them immutably. A fixture verifier may exercise the contract, but it is not
a production trust root. Loss of an exported receipt may be repaired only as an idempotent projection
of the same authenticated durable state; a receipt must never be imported to recreate a claim.

The durable generic Host reference implementation projects all five receipts at the Profile claim,
Preauthorization claim, Grant verification, execution claim, and completion effect points. It writes
canonical JSON without a trailing newline so the persisted byte digest is the receipt canonical
digest, then validates the complete lineage index through this contract. Restart paths project the
same bytes from authenticated durable state and reject an existing Grant that cannot be reconciled to
its earlier claim. Raw durable handles never leave the Host.

Routine human approval is not a requirement of this lineage. A trusted Host may make Profile and
Preauthorization decisions through deterministic machine policy. That automation does not collapse
the distinct single-use claims, turn audit receipts into capabilities, or grant publication,
promotion, regression, or gating authority.

Authorization lineage also does not replace target isolation admission. Before a target effect, the
runtime independently requires the exact `testing-host.target-execution-boundary.v1` repository
binding documented in `contracts/target-execution-boundary.v1.md`. Compatibility, machine policy
admission, Preauthorization, and a valid Grant cannot authorize an unknown repository when that
boundary is absent or mismatched.

Existing Project Profile, Grant request/result, structured execution request-v3, and summary-v1
contracts remain unchanged. Production consumers requiring authorization lineage must use a future
explicit request/result version or a separate lineage index; adding receipt fields to strict v1 payloads
is not backward compatible.

Diagnostic counters such as `claim_count = 1` or `grant_write_count = 1` do not substitute for this
receipt chain.
