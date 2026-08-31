# Testing Package Manifest v1

`testing-package-manifest.v1` is the release identity for a distributable Testing Packages bundle.
Semantic versioning communicates compatibility; `package_content_sha256` identifies the exact final
package tree. A consumer fetches the manifest, verifies its canonical `manifest_digest`, fetches the
package bytes, recomputes `package_content_sha256`, and adopts the package only after every identity
and capability check passes.

## Canonical domains

`fkst-testing-package-manifest-canonical-json.v1` is a constrained deterministic JSON profile. It is
informed by RFC 8785/JCS but is not declared RFC 8785-compatible: object keys are ordered by Unicode
code point (equivalently, lexicographic UTF-8 byte order for valid Unicode scalar values), rather than
JCS UTF-16 code-unit order. Inputs must contain valid Unicode scalar values. Strings use standard JSON
escapes for quotation mark, reverse solidus, and controls while preserving all other Unicode as UTF-8.
Arrays preserve order. Object keys are sorted at every level. Separators are `,` and `:` with no added
whitespace, and output has no trailing whitespace or newline.

Numbers are restricted to integers in the inclusive range `[-9007199254740991, 9007199254740991]`.
Lua non-empty arrays and objects are inferred from dense positive integer indexes or string keys.
Because an empty Lua table is otherwise ambiguous, an untagged empty table denotes `[]` and
`contract.canonical_json.object({})` denotes `{}`; `contract.canonical_json.array({})` may be used to
state `[]` explicitly. JSON `null` is represented by `contract.canonical_json.null` when nested in Lua.

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

The portable JSON Schema is `schemas/testing-package-manifest.v1.schema.json`, using JSON Schema
Draft 2020-12. Portable checks cover the closed object shapes, all 14 required fields, bounded string
and list forms, exact schema/canonicalization/dependency identifiers, exact version/commit/digest
syntax, supported contract majors and entrypoint names, and path-unsafe `package_id` values. In
particular, `package_id` may use identifiers such as `QA_RUNNER@V1`, but may not contain any
U+0000-U+001F control, `/`, `\`, or the literal substring `..`.

Lua validation additionally owns checks that require runtime context rather than one portable
manifest instance: entrypoint capability membership in `semantic_capabilities`, caller-supplied
expected identity and entrypoint/major/capability requirements, and optional recomputation of
`manifest_digest`. Package adoption separately recomputes `package_content_sha256` from the fetched
package tree. Schema validation alone does not establish those contextual identities or digest
bindings.

## Local QA Runtime adoption

Local QA Runtime obtains a manifest from its configured immutable release source, verifies the
manifest digest, requires the expected package ID/version/entrypoint/contract major, verifies the two
dependency commits against its lock policy, fetches the package archive, recomputes the package
content digest, and only then extracts/adopts it into its cache. A digest mismatch, replay with a
different digest, unsupported contract major, unknown entrypoint, capability mismatch, floating
reference, or malformed metadata fails closed. Runtime code consumes this public manifest contract
and does not import private Lua implementation details.
