local contract = require("contract.testing_design_generation")
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
    provider = {
      adapter_id = "fake-generation",
      adapter_version = "1.0.0",
      model_id = "deterministic-test-model",
    },
    prompt_template = request.prompt_template,
  }
end

local function assert_failure(outcome, code)
  t.eq(outcome.ok, false)
  t.eq(outcome.failure.code, code)
  t.eq(next(outcome.failure, "code"), nil)
  t.eq(outcome.candidate_set, nil)
end

return {
  test_fake_returns_contract_valid_success_with_prompt_identity = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    local outcome = generation.generate(request, fake.new(complete(request, candidate_set)))
    t.eq(outcome.status, "complete")
    t.eq(outcome.candidate_set.candidate_set_id, "candidate-set-browser-title-v1")
    t.eq(outcome.provider.adapter_id, "fake-generation")
    for _, key in ipairs({ "template_id", "template_version", "template_digest" }) do
      t.eq(outcome.prompt_template[key], request.prompt_template[key])
    end
    t.eq(contract.validate_candidate_set(outcome.candidate_set, request), outcome.candidate_set)
  end,

  test_cancellation_prevents_the_generation_effect = function()
    local called = false
    local outcome = generation.generate(load("valid-request"), {
      generate = function()
        called = true
      end,
    }, { cancelled = true })
    assert_failure(outcome, "cancellation")
    t.eq(called, false)
  end,

  test_malformed_cancellation_control_fails_closed = function()
    t.raises(function()
      generation.generate(load("valid-request"), fake.new(false), { cancelled = "yes" })
    end)
  end,

  test_closed_provider_neutral_failure_union_is_preserved = function()
    for code in pairs(contract.generation_failure_codes) do
      local outcome = generation.generate(load("valid-request"), fake.new({
        ok = false,
        failure = { code = code },
      }))
      assert_failure(outcome, code)
    end
  end,

  test_malformed_or_open_ended_outcomes_fail_closed = function()
    local request = load("valid-request")
    local malformed = {
      false,
      {},
      { status = "complete" },
      { status = "complete", candidate_set = load("valid-candidate-set") },
      { ok = true, candidate_set = load("valid-candidate-set") },
      { ok = false, failure = { code = "provider-error" } },
      { ok = false, failure = { code = "nonzero-exit" } },
      { ok = false, failure = { code = "timeout", detail = "secret" } },
      { ok = false, failure = { code = "timeout" }, diagnostics = "secret" },
    }
    for _, outcome in ipairs(malformed) do
      t.raises(function() generation.generate(request, fake.new(outcome)) end)
    end
  end,

  test_invalid_candidate_set_is_classified_as_schema_mismatch = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    candidate_set.candidates[1].steps = json.decode("[]")
    assert_failure(generation.generate(request, fake.new(complete(request, candidate_set))), "schema-mismatch")
  end,

  test_foreign_request_digest_is_classified_as_schema_mismatch = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    candidate_set.request_digest = string.rep("f", 64)
    assert_failure(generation.generate(request, fake.new(complete(request, candidate_set))), "schema-mismatch")
  end,

  test_foreign_prompt_identity_fails_closed = function()
    local request = load("valid-request")
    local outcome = complete(request, load("valid-candidate-set"))
    outcome.prompt_template = {
      template_id = request.prompt_template.template_id,
      template_version = request.prompt_template.template_version,
      template_digest = string.rep("f", 64),
    }
    t.raises(function() generation.generate(request, fake.new(outcome)) end)
  end,

  test_invalid_provider_identity_fails_closed = function()
    local request = load("valid-request")
    local outcome = complete(request, load("valid-candidate-set"))
    outcome.provider.adapter_version = "latest"
    t.raises(function() generation.generate(request, fake.new(outcome)) end)
  end,

  test_fake_and_use_case_return_detached_array_preserving_snapshots = function()
    local request = load("valid-request")
    local candidate_set = load("valid-candidate-set")
    local scripted = complete(request, candidate_set)
    local adapter = fake.new(scripted)

    scripted.provider.model_id = "mutated-source"
    candidate_set.candidates[1].traceability.journey_refs[1] = "mutated-source"

    local first = generation.generate(request, adapter)
    t.eq(first.provider.model_id, "deterministic-test-model")
    t.eq(#first.candidate_set.candidates[1].traceability.journey_refs, 0)
    t.eq(contract.canonical_bytes(first.candidate_set):find('"journey_refs":[]', 1, true) ~= nil, true)

    first.provider.model_id = "mutated-result"
    first.candidate_set.candidates[1].traceability.journey_refs[1] = "mutated-result"
    local second = generation.generate(request, adapter)
    t.eq(second.provider.model_id, "deterministic-test-model")
    t.eq(#second.candidate_set.candidates[1].traceability.journey_refs, 0)
  end,

  test_port_receives_a_detached_request_snapshot = function()
    local request = load("valid-request")
    local original_template_id = request.prompt_template.template_id
    local candidate_set = load("valid-candidate-set")
    local outcome = generation.generate(request, {
      generate = function(received)
        received.prompt_template.template_id = "mutated-by-adapter"
        return complete(request, candidate_set)
      end,
    })
    t.eq(outcome.status, "complete")
    t.eq(request.prompt_template.template_id, original_template_id)
  end,
}
