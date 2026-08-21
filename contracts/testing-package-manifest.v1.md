# Testing Package Manifest v1

`testing-package-manifest.v1` is the release identity for a distributable Testing Packages bundle.
Semantic versioning communicates compatibility; `package_content_sha256` identifies the exact final
package tree. A consumer fetches the manifest, verifies its canonical `manifest_digest`, fetches the
package bytes, recomputes `package_content_sha256`, and adopts the package only after every identity
and capability check passes.

## Canonical domains

The generator writes UTF-8 JSON with sorted object keys, compact separators, and no trailing whitespace.
The manifest digest is SHA-256 over the canonical manifest with only `manifest_digest` omitted. The
package digest is SHA-256 over sorted UTF-8 relative paths and file records: each record is
`path NUL type byte content NUL`; regular files use `f`, symlinks use `l` followed by their exact
link target bytes, and directories and `.git` metadata are omitted. The output manifest itself is
omitted from the package digest. These domains are distinct from persisted manifest/package bytes.

## Fields and validation

The manifest contains the package ID and exact `X.Y.Z` version, exact source commit, package digest,
supported contract majors and canonicalization profiles, known entrypoints with contract-major and
capability bindings, semantic capabilities, exact runtime/platform requirements, exact
`fkst-packages` and `fkst-substrate` commits, producer/toolchain versions, deterministic creation
metadata, and the manifest digest. Validators reject workspace paths, floating refs or versions,
unsupported majors, unknown entrypoints, and undeclared capabilities. No credentials, cookies,
worker tokens, bearer tokens, or local paths are part of the schema.

## Local QA Runtime adoption

Local QA Runtime obtains a manifest from its configured immutable release source, verifies the
manifest digest, requires the expected package ID/version/entrypoint/contract major, verifies the two
dependency commits against its lock policy, fetches the package archive, recomputes the package
content digest, and only then extracts/adopts it into its cache. A digest mismatch, replay with a
different digest, unsupported contract major, unknown entrypoint, capability mismatch, floating
reference, or malformed metadata fails closed. Runtime code consumes this public manifest contract
and does not import private Lua implementation details.
