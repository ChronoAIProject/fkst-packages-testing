# Testing package release admission conformance v1

## Purpose and ownership

This contract defines package-side golden vectors and a black-box protocol for testing a Runtime release consumer. It follows trusted-update reference-monitor practice: immutable release coordinates, exact-byte verification before adoption, content-addressed cache publication, authority-supplied monotonic release state, atomic admission, durable replay/conflict, and recovery to a known decision.

This repository owns this contract, the compatibility matrix, the vectors, and the conformance runner. The consumer adapter owns network fetch, quarantined staging, cache persistence, Journal state, admission transactions, update and rollback state, anti-rollback decisions, restart recovery, and production receipt storage. An implementation MUST NOT use the conformance runner as a substitute Runtime state machine.

Package signing and key publication remain separate release-publication responsibilities. The vectors describe authority outcomes and trusted release sequence values; they do not define a competing signature envelope or key format.

## Corpus

The normative corpus is `conformance/testing-package-release-admission.v1.json`.

The corpus:

- identifies immutable baseline, update, admitted-prior, and unapproved-older releases;
- supplies the trusted `release_sequence` used by the consumer authority for update and anti-rollback decisions;
- defines supported contract, canonicalization, profile, capability, platform, and executor identities;
- groups rejection vectors by violated invariant rather than by production code branch;
- defines exact expected black-box observations, including mutation deltas and receipt bindings.

The `release_sequence` is trusted release-authority data. It is not derived from semantic version ordering, timestamps, source commits, digest lexicographic order, or fetch order.

## Adapter protocol

Run the corpus with:

```sh
python3 scripts/testing_package_release_admission_conformance.py --adapter /absolute/path/to/consumer-adapter
```

The runner starts a fresh adapter process for each case, writes one UTF-8 JSON request followed by LF to standard input, closes standard input, and reads one UTF-8 JSON observation from standard output. The adapter command is executed directly without a shell.

The request has this closed shape:

```json
{
  "schema": "testing-package-release-admission-conformance-request.v1",
  "protocol": "stdin-stdout-json.v1",
  "compatibility": {},
  "releases": [],
  "case": {}
}
```

The adapter MUST execute the supplied case against the real consumer boundary. Operations named `restart-runtime` MUST cross the consumer's production restart/recovery seam. Faults and authority outcomes MAY be injected through product test ports, but the final decision and persisted observation MUST come from the production consumer adapter.

The request's `case` contains exactly `name`, `invariant`, and `trials`. The corpus `expected_observation` remains runner-private and MUST NOT be exposed to the adapter.

The runner copies the adapter executable into a fresh temporary directory for each case, runs it from that directory, and supplies only a minimal allowlisted process environment. The repository working directory, the adapter's original sibling files, inherited environment paths, and runner-private corpus location are not adapter inputs.

The adapter MUST emit an observation matching the runner-private `expected_observation`. Unknown fields fail conformance. The runner compares parsed JSON values, so object member order and insignificant whitespace are not observable.

The runner bounds each adapter process by a timeout and a maximum stdout size. A timeout, non-zero exit, malformed JSON, oversized output, or mismatched observation fails conformance.

## Admission ordering

A conforming consumer implements these externally observable states:

```text
immutable fetch into bounded quarantined staging
  -> exact-byte and authority verification
  -> compatibility and unique semantic mapping verification
  -> claim, policy, deadline, idempotency, and anti-rollback verification
  -> atomic admission decision and selected executor
  -> publish verified content to the content-addressed cache
  -> materialize or execute only after admission
```

Verified bytes MAY remain in recoverable quarantined staging before admission. They MUST NOT be reported as an adopted cache entry before the admission transaction succeeds. After an atomic admission crash, recovery MUST retain the admission decision and either finish cache publication or report a recoverable admitted state; it MUST NOT rerun an uncertain external effect.

## Mutation observations

Every decision step reports deltas for `journal`, `cache`, `workspace`, `process`, `browser`, and `evidence`.

- Pre-admission rejection and different-digest conflict require zero deltas for every field.
- Successful first admission may mutate `journal` and publish one content-addressed `cache` identity, but MUST keep execution-owned fields at zero.
- Exact replay returns the original durable receipt and MUST produce zero new deltas.
- Restart operations themselves produce zero logical deltas; their following observation proves recovered state.

## Receipt binding

The successful admission observation binds:

- exact release reference and trusted `release_sequence`;
- package content, manifest, catalog, schema-set, and dependency-lock digests;
- selected executor and contract major;
- policy, capability-set, current-claim, and canonical request digests;
- admission key and admission digest.

The receipt is the package-consumer lineage input for `testing-runner-invocation.v1` and subsequent ResultAuthorityReceipt projection. Production receipt persistence remains consumer-owned.

## Required invariants

The corpus covers:

1. immutable fetch, exact verification, atomic admission, content-addressed publication, and exact replay;
2. content, manifest, catalog, schema-set, and dependency-lock binding failures;
3. invalid or unavailable release authority;
4. unsupported contract major, canonicalization profile, execution profile, capability, and platform;
5. unknown, duplicate, or ambiguous semantic entrypoint mapping;
6. floating, workspace, dynamic-import, plugin, and runtime-install identity rejection;
7. same-key different-digest durable conflict;
8. cache corruption and resolver outage;
9. explicit update, authority-approved rollback, and anti-rollback rejection;
10. restart after fetch, after verification, and after atomic admission;
11. stale claim, expired deadline, and policy denial before effect.

