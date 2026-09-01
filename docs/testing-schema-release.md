# Testing schema release

The testing schema release is an unsigned, reproducible publication boundary. Signing and Runtime admission are intentionally outside this repository contract.

## Source inventory

`schema-fixtures/testing-schema-fixtures.v1.json` is the fixture publication source. Entries are sorted by schema `$id` UTF-8 bytes, and every `schemas/*.schema.json` resource must occur exactly once. Shared multi-schema result fixtures use one index with an explicit schema discriminator per case.

`scripts/schema_artifact_policy.py` defines the closed repository profile layered over JSON Schema Draft 2020-12. Standard keyword, reference, resource, and base-URI behavior remains delegated to pinned conforming validators. Unknown keywords, formats, and `x-*` extensions fail before fixture execution.

## Generated identities

Run these commands after changing schemas or fixtures:

```sh
python3 scripts/schema_artifact_policy.py
python3 scripts/generate_testing_schema_fixture_index.py
python3 scripts/generate_testing_schema_catalog.py
```

Each fixture-set identity hashes canonical JSON with only `fixture_set_sha256` omitted. `catalog_sha256` and `release_sha256` use the same self-field omission rule for their respective objects.

`schema-release/testing-schema-catalog.v1.sha256` has a different domain: it is the SHA-256 of the exact persisted catalog bytes, including the `catalog_sha256` field and the final LF. The unsigned release binds that exact persisted-byte digest. The package-manifest reference similarly binds the exact bytes of `schema-release/testing-package-manifest.v1.json` supplied to the release generator.

## Offline conformance

The Node validator imports only `scripts/node_schema/vendor/`, removes HTTP, HTTPS, and file retrieval plugins after local resource registration, and fails unresolved references. Its dependency lock records exact versions and package integrities. The official JSON Schema Test Suite is pinned by commit in `scripts/node_schema/standards-corpus.json`; selected test groups run directly against vendored Hyperjump, while exclusions are machine-readable and limited to behavior outside the repository profile.
