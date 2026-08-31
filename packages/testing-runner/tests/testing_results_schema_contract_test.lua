local results = require("contract.testing_results")
local t = fkst.test
local host_json = json
local sha256 = require("tests.fixtures.sha256_helpers")
local conformance = require("tests.fixtures.conformance_runner_helpers")

local fixture_root = "packages/testing-runner/tests/fixtures/testing-results"

local function fixture(name) return conformance.fixture(fixture_root, name) end

return {
  test_valid_schema_fixtures_match_lua_contract = function()
    t.eq(results.validate_observation(fixture("valid-observation")).schema, "testing-observation.v1")
    t.eq(results.validate_assertion_result(fixture("valid-assertion")).schema, "testing-assertion-result.v1")
    for _, name in ipairs({
      "valid-case-passed", "valid-case-failed", "valid-case-skipped",
      "valid-case-not-applicable", "valid-case-error", "valid-case-blocked",
      "valid-case-lost", "valid-case-year-zero",
    }) do
      t.eq(results.validate_case_result(fixture(name)).schema, "testing-case-result.v2")
    end
    local result_set = fixture("valid-result-set")
    local evidence = fixture("valid-result-set-evidence-manifest")
    t.eq(results.validate_case_result_set(result_set, nil, evidence, sha256).schema, "testing-case-result-set.v2")
  end,

  test_invalid_schema_fixtures_are_rejected_by_lua = function()
    for _, name in ipairs({
      "invalid-unknown-field", "invalid-missing-required-field",
      "invalid-overlong-reference-kind", "invalid-malformed-digest",
      "invalid-impossible-date", "invalid-hyphen-time-separators",
      "invalid-multibyte-over-byte-limit", "invalid-nested-multibyte-over-byte-limit",
      "invalid-assertion-truth-table",
      "invalid-case-outcome", "invalid-case-error-rule", "invalid-case-reason-rule",
      "invalid-required-assertion", "invalid-duration-negative", "invalid-duration-over-max",
    }) do
      local value = fixture(name)
      t.raises(function()
        if value.schema == "testing-observation.v1" then
          results.validate_observation(value)
        elseif value.schema == "testing-assertion-result.v1" then
          results.validate_assertion_result(value)
        else
          results.validate_case_result(value)
        end
      end)
    end
    t.raises(function()
      results.validate_case_result_set(
        fixture("invalid-set-digest-presence"),
        nil,
        fixture("valid-result-set-evidence-manifest")
      )
    end)
  end,
}
