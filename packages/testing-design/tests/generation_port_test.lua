local generation = require("generation")
local fake = require("generation_fake")
local t = fkst.test

local fixture_root = "packages/testing-design/tests/fixtures/generation/v1/"

local function load(name)
  local handle = assert(io.open(fixture_root .. name .. ".json", "rb"))
  local body = handle:read("*a")
  handle:close()
  return json.decode(body)
end

local function complete(request, candidate_set)
  return {
    status = "complete",
    candidate_set = candidate_set,
    provider = { adapter_id = "codex-cli", adapter_version = "1.0.0", model_id = "test-model" },
    prompt_template = request.prompt_template,
  }
end

return {
  test_fake_port_returns_a_valid_detached_candidate_set = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    local outcome = generation.generate(request, fake.new(complete(request, candidate_set)))
    t.eq(outcome.status, "complete")
    t.eq(outcome.provider.model_id, "test-model")
    t.eq(outcome.prompt_template.template_id, request.prompt_template.template_id)
    t.eq(outcome.candidate_set.candidate_set_id, "candidate-set-browser-title-v1")
    outcome.candidate_set.candidate_set_id = "changed"
    t.eq(candidate_set.candidate_set_id, "candidate-set-browser-title-v1")
  end,

  test_invalid_complete_output_is_a_schema_mismatch_not_an_artifact = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    candidate_set.request_digest = string.rep("f", 64)
    local outcome = generation.generate(request, fake.new(complete(request, candidate_set)))
    t.eq(outcome.ok, false)
    t.eq(outcome.failure.code, "schema-mismatch")
    t.eq(outcome.candidate_set, nil)
  end,

  test_candidate_validation_failures_return_schema_mismatch = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    candidate_set.candidates = json.decode("[]")
    local outcome = generation.generate(request, {
      generate = function()
        return complete(request, candidate_set)
      end,
    })
    t.eq(outcome.ok, false)
    t.eq(outcome.failure.code, "schema-mismatch")
    t.eq(outcome.candidate_set, nil)
  end,

  test_candidate_canonicalization_failures_return_schema_mismatch = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    setmetatable(candidate_set, {})
    local outcome = generation.generate(request, {
      generate = function()
        return complete(request, candidate_set)
      end,
    })
    t.eq(outcome.ok, false)
    t.eq(outcome.failure.code, "schema-mismatch")
    t.eq(outcome.candidate_set, nil)
  end,

  test_invalid_provider_metadata_fails_closed = function()
    local request = load("valid-request")
    local outcome = complete(request, load("valid-candidate-set"))
    outcome.provider.adapter_version = "not-semver"
    t.raises(function() generation.generate(request, fake.new(outcome)) end)
  end,

  test_generation_control_rejects_non_boolean_cancelled = function()
    t.raises(function()
      generation.generate(load("valid-request"), fake.new({ ok = false, failure = { code = "refusal" } }), { cancelled = "true" })
    end)
  end,

  test_closed_adapter_failure_union_is_preserved_without_diagnostics = function()
    for _, code in ipairs({
      "refusal", "malformed-output", "schema-mismatch", "timeout", "cancellation",
      "nonzero-exit", "unavailable-binary", "truncation", "budget-exhausted",
    }) do
      local outcome = generation.generate(load("valid-request"), fake.new({ ok = false, failure = { code = code } }))
      t.eq(outcome.ok, false)
      t.eq(outcome.failure.code, code)
      t.eq(next(outcome.failure, "code"), nil)
    end
  end,

  test_cancellation_prevents_the_generation_effect = function()
    local called = false
    local outcome = generation.generate(load("valid-request"), {
      generate = function() called = true end,
    }, { cancelled = true })
    t.eq(outcome.failure.code, "cancellation")
    t.eq(called, false)
  end,

  test_malformed_or_open_ended_port_outcomes_fail_closed = function()
    local request = load("valid-request")
    for _, outcome in ipairs({
      {},
      { status = "complete" },
      { status = "complete", candidate_set = load("valid-candidate-set") },
      complete(request, load("valid-candidate-set")),
      { ok = false, failure = { code = "provider-error" } },
      { ok = false, failure = { code = "timeout", detail = "secret" } },
      { ok = false, failure = { code = "timeout" }, stderr = "secret" },
    }) do
      if outcome.status == "complete" and outcome.provider ~= nil then
        outcome.prompt_template = { template_id = "foreign", template_version = "1.0.0", template_digest = string.rep("0", 64) }
      end
      t.raises(function() generation.generate(request, fake.new(outcome)) end)
    end
  end,
}
