local host_json = json

local M = {}

M.names = {
  "valid-complete",
  "invalid-top-level-unknown", "invalid-top-level-missing-dedup-key",
  "invalid-request-schema", "invalid-identity-schema",
  "invalid-executor-missing-package-id", "invalid-executor-extra-field",
  "invalid-identity-package-id-non-string", "invalid-identity-entrypoint-empty",
  "invalid-identity-contract-major-control", "invalid-identity-package-id-del",
  "invalid-identity-package-id-over-byte-limit",
  "invalid-identity-package-id-multibyte-over-byte-limit",
  "invalid-execution-profile-empty", "invalid-trace-id-del",
  "invalid-dedup-key-over-byte-limit", "invalid-semver-two-components",
  "invalid-semver-prefixed", "invalid-digest-short", "invalid-digest-uppercase",
  "invalid-digest-non-hex", "invalid-approved-refs-missing-policy",
  "invalid-approved-refs-extra", "invalid-package-manifest-kind",
  "invalid-source-kind", "invalid-plan-kind", "invalid-pql-input-kind",
  "invalid-policy-kind", "invalid-capability-set-kind", "invalid-ref-empty",
  "invalid-ref-mutable", "invalid-ref-query", "invalid-ref-fragment",
  "invalid-ref-control", "invalid-ref-del", "invalid-ref-over-byte-limit",
  "invalid-ref-multibyte-over-byte-limit", "invalid-reference-missing-sha256",
  "invalid-reference-extra-field", "invalid-forbidden-execution-fields",
  "invalid-forbidden-secret-fields", "invalid-forbidden-path-loader-fields",
  "invalid-forbidden-browser-fields", "invalid-forbidden-talos-fields",
  "invalid-forbidden-resolved-entrypoint",
  "contextual-unsupported-execution-profile",
  "contextual-unsupported-executor-mapping",
}

function M.load(name)
  local root = "packages/testing-runner/tests/fixtures/testing-package-executor.request.v1"
  local handle = assert(io.open(root .. "/" .. name .. ".json", "rb"))
  local body = handle:read("*a")
  handle:close()
  return host_json.decode(body)
end

return M
