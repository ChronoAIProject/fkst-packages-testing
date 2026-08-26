# Testing Package Resolution v1

Trusted package resolution is a fail-closed reference-monitor boundary between an opaque
`testing-package-executor.request.v1` and an admitted
`testing-package-executor.resolved-invocation.v1`. The resolver, not the executor, owns immutable
reference loading, byte-digest verification, package-manifest verification, compatibility and
capability policy, semantic target selection, and atomic admission. The executor receives only the
resolved semantic identity and bounded capability ports.

## Normative semantic mapping

`contract.testing_package_executor.semantic_mappings` is the closed, versioned runtime compatibility
registry. A candidate matches only when all of these verified values match one registry row:

```text
execution_profile
+ package_id
+ package_version verified by the manifest
+ contract_major
+ ordered allowed capability set
→ exactly one executor_id / semantic entrypoint
```

The selected semantic entrypoint must also occur exactly once in the verified package manifest with
the same contract major and capability set. Zero matches fail as `unsupported-mapping`; multiple
runtime or manifest matches fail as `mapping-ambiguous`. Paths, `argv`, shells, dynamic imports,
plugins, workspaces, floating references, and credential-bearing fields are not mapping inputs.

## Admission identity

Before effects, Local QA Runtime canonicalizes `testing-package-executor.admission-request.v1` and
computes its SHA-256 digest. The canonical object binds the admission key to the complete verified
executor identity, execution profile, all six immutable reference digests, and the selected
`executor_id` / semantic entrypoint / contract-major / capability tuple.

The injected `admit_resolution` port is the atomic Runtime-owned receipt-store seam:

- no prior key returns `testing-package-executor.admission-receipt.v1` with status `admitted`;
- the same key and digest returns the original receipt unchanged;
- the same key and a different digest returns
  `testing-package-executor.admission-conflict.v1` with both digests;
- malformed receipts and conflicts fail closed.

Only a resolved invocation carrying a matching admission digest and receipt is accepted by
`TestingPackageExecutor`. Resolver failures can be projected as
`testing-package-executor.resolver-failure.v1`; its stable `code` is drawn from
`contract.testing_package_executor.resolver_failure_codes`. Current-claim failures use the reserved
`current-claim-unavailable` and `current-claim-superseded` codes, but current-claim lookup remains a
Talos-owned boundary and is not implemented as a package resolver or executor port here.

## Effect boundary

Resolution may read immutable bytes and atomically admit a digest. It must not call freshness,
browser, writer, Journal, workspace, process, or local-resource ports. `TestingPackageExecutor`
validates the admitted resolved invocation before its first effect and has no API for opaque package
resolution.
