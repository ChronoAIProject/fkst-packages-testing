# Testing schema release

The testing schema release descriptor remains an unsigned, reproducible identity object. This repository contract additionally includes the detached DSSE signature envelope and committed verification-key authorization record required by #772. Runtime admission remains outside this repository contract.

Repository maintainers with merge authority over the canonical `dev` branch authorize the committed `(keyid, Ed25519 public key)` pair solely for the `application/vnd.in-toto+json` testing schema release attestation profile. Successful cryptographic verification proves integrity and possession of that authorized key; it does not grant Runtime execution or admission authority.

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

Generate the detached envelope and scoped public-key authorization with an external base64-encoded 32-byte Ed25519 seed:

```sh
FKST_TESTING_SCHEMA_RELEASE_SIGNING_SEED='<base64-encoded-32-byte-seed>' \
  PYTHONPATH=.fkst/run/python-test-deps \
  python3 scripts/generate_testing_schema_release_attestation.py
```

Alternatively, pass the secret through `--seed-file /path/to/secret-seed.base64`. The private seed is external secret material and is never committed or logged. The public key authorization record and DSSE envelope are distributable release artifacts.

Verify the committed artifact offline using only committed files and Node's built-in cryptography:

```sh
node scripts/verify_testing_schema_release_attestation.mjs
```

Run the focused smoke test through the repository's isolated Python dependency environment:

```sh
PYTHONNOUSERSITE=1 PYTHONPATH=.fkst/run/python-test-deps:scripts \
  python3 -S -B scripts/testing_schema_release_attestation_test.py
```

Each fixture-set identity hashes canonical JSON with only `fixture_set_sha256` omitted. `catalog_sha256` and `release_sha256` use the same self-field omission rule for their respective objects.

`schema-release/testing-schema-catalog.v1.sha256` has a different domain: it is the SHA-256 of the exact persisted catalog bytes, including the `catalog_sha256` field and the final LF. The unsigned release binds that exact persisted-byte digest. The package-manifest reference similarly binds the exact bytes of `schema-release/testing-package-manifest.v1.json` supplied to the release generator.

The catalog publishes `testing-assertion-reducer-identity.v1` and `testing-result-authority-receipt.v1`; `contracts/testing-result-authority.v1.md` defines their authority separation and digest domains.

## Offline conformance

The Node validator imports only `scripts/node_schema/vendor/`, removes HTTP, HTTPS, and file retrieval plugins after local resource registration, and fails unresolved references. Its dependency lock records exact versions and package integrities. The official JSON Schema Test Suite is pinned by commit in `scripts/node_schema/standards-corpus.json`; selected test groups run directly against vendored Hyperjump, while exclusions are machine-readable and limited to behavior outside the repository profile.
