# Testing Package Release v1

`testing-package-release.v1` binds one immutable Testing Packages bundle to its existing package
manifest, published schema catalog, signed schema release, executor identity, reducer identity, and
single symbolic entrypoint mapping. All paths, byte lengths, digests, source revisions, dependency
revisions, runtime requirements, and creation inputs are exact release values; floating references
and ambient workspace identities are not release inputs.

The bundle and release metadata use recursively sorted compact UTF-8 JSON with exactly one final LF.
The package manifest retains `fkst-testing-package-manifest-canonical-json.v1` and has no final LF.
Bundle records are sorted by UTF-8 path bytes and bind canonical standard base64, decoded size, and
decoded SHA-256. `package_content_sha256` uses the manifest file-record domain over decoded files.

The detached DSSE signature establishes artifact integrity and publisher-key possession. Without an
independently provisioned SHA-256 pin for the exact authorization-record bytes, the release artifacts
demonstrate only self-consistency and integrity. With a matching independently provisioned pin, the
offline verifier establishes that the authorized Ed25519 publisher key signed this exact release
profile before any bundle parsing, extraction, module loading, or executor effect.

The release layer does not own Runtime fetch, cache, admission, rotation, revocation, current-claim
dispatch, or browser lifecycle. After verification, the walking skeleton resolves exactly
`testing-runner.run` to `testing_package_executor.executor.execute`, loads that module only from the
verified extracted bundle, and invokes the existing executor with deterministic in-memory ports.
