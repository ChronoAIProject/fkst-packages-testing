local manifest = require("contract.testing_evidence_manifest")
local host_json = json
local conformance = require("tests.fixtures.conformance_runner_helpers")
local t = fkst.test

local fixture_root = "packages/testing-runner/tests/fixtures/testing-evidence-manifest.v1"
local invalid_fixtures = {
  "invalid-empty-entries",
  "invalid-malformed-artifact-ref",
  "invalid-malformed-digest",
  "invalid-malformed-timestamp",
  "invalid-impossible-date",
  "invalid-hyphen-time-separators",
  "invalid-multibyte-over-byte-limit",
  "invalid-missing-required-field",
  "invalid-overlong-evidence-id",
  "invalid-overlong-reference-kind",
  "invalid-role-media-mismatch",
  "invalid-size-bytes-fractional",
  "invalid-size-bytes-negative",
  "invalid-size-bytes-over-max",
  "invalid-too-many-entries",
  "invalid-unknown-field",
  "invalid-unsupported-policy-status",
  "invalid-unsupported-role",
  "invalid-unsupported-sensitivity",
}

local function fixture(name) return conformance.fixture(fixture_root, name) end

return {
  test_shared_schema_fixtures_match_portable_validation = function()
    local value = fixture("valid")
    t.eq(value.entries[1].role, "runner-log")
    t.eq(value.entries[2].role, "screenshot")
    t.eq(value.entries[2].assertion_id, nil)
    t.eq(value.entries[3].role, "sanitized-json")
    t.eq(manifest.validate(value), value)
    local year_zero = fixture("valid-year-zero")
    t.eq(manifest.validate(year_zero), year_zero)
    t.raises(function() manifest.validate(value, nil, nil, { allow_empty_entries=false }) end)
    t.raises(function() manifest.validate(value, nil, nil, { artifact_root="unsafe-root" }) end)

    for _, name in ipairs(invalid_fixtures) do
      t.raises(function() manifest.validate(fixture(name)) end)
    end
  end,
}
