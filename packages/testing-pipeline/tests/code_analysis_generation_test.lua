local ai = require("ai_orchestration")
local code_analysis = require("code_analysis.artifact")
local generation = require("testing_ai.module_ai_generation")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"
local fixture_source = "local function calculate_total(left, right)\n  return left + right\nend\nreturn calculate_total\n"

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local handle, err = io.open(path, "rb")
  if handle == nil then error(err or ("missing artifact " .. path)) end
  local body = handle:read("*a")
  handle:close()
  return body
end

local function write_file(path, body)
  local directory = assert(path:match("^(.*)/[^/]+$"))
  local ok = os.execute("mkdir -p " .. shell_quote(directory))
  if ok ~= true and ok ~= 0 then return nil, "could not create artifact directory" end
  local handle, err = io.open(path, "wb")
  if handle == nil then return nil, err end
  local wrote, write_err = handle:write(body)
  handle:close()
  return wrote and true or nil, write_err
end

local function sha256_file(path)
  local command = "node libraries/testing_runtime/bin/fkst-testing-runtime.js hash-file --input " .. shell_quote(path)
  local handle = assert(io.popen(command))
  local value = assert(handle:read("*a")):match("^([0-9a-f]+)%s*$")
  assert(handle:close())
  return value
end

local function file_exists(path)
  local handle = io.open(path, "rb")
  if handle == nil then return false end
  handle:close()
  return true
end

local function module_start(reference, artifact_root)
  return {
    schema = "testing-pipeline.module-start.v1",
    module = "calculator",
    backend = "fkst-native",
    dry_run = false,
    ui_loop = {
      base_url = fixture_base_url,
      allowed_origins = { fixture_origin },
      mutation_policy = "read-only",
    },
    module_discovery = {
      schema = "testing-runner.module-discovery.v1",
      observations = {
        {
          id = "calculator",
          name = "Calculator",
          entry_url = fixture_base_url .. "/calculator",
          visible_label = "Calculator",
          discovery_source = "navigation",
          confidence = "high",
          evidence_pointer = artifact_root .. "/evidence/calculator",
        },
      },
      code_analysis = reference,
    },
    preflight_result = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = { { role = "base_url", status = "ready" } },
    },
    cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 4,
      case_priorities = { "P1" },
      ai_generation = {
        schema = "testing-runner.ai-case-generation.request.v1",
        mode = "autonomous-reviewed",
        case_budget = 1,
      },
    },
    artifact_root = artifact_root,
    source_ref = { kind = "fixture-repository", ref = "walking-skeleton" },
  }
end

local function generation_ports(adapter)
  local model = { adapter_calls = 0 }
  model.ports = {
    absolute_path = function(path) return "/repo/" .. path end,
    read = read_file,
    write = write_file,
    sha256_file = sha256_file,
    generate = function(context, request)
      model.adapter_calls = model.adapter_calls + 1
      model.context = context
      local function_fact
      for _, fact in ipairs(context.code_analysis.facts) do
        if fact.kind == "function" and fact.name == "calculate_total" then function_fact = fact end
      end
      if adapter ~= nil then return adapter(context, request, function_fact) end
      return {
        exit_code = 0,
        stderr = "",
        stdout = ai.json_encode({
          schema = "testing-runner.ai-case-candidates.v1",
          cases = {
            {
              module_id = "calculator",
              priority = "P1",
              title = "Exercise discovered function " .. function_fact.name,
              objective = "Derive a bounded case from the verified function fact.",
              case_kind = "read-only-interaction",
              code_fact_pointer = function_fact.pointer,
              actions = {
                {
                  action = "open-visible-surface",
                  target = function_fact.name,
                  expected = "The surface derived from the function fact is visible.",
                },
              },
              expected_observable = function_fact.name .. " remains visible.",
            },
          },
        }),
      }
    end,
  }
  return model
end

local function persist_analysis(root)
  local fixture_root = root .. "/fixture"
  assert(write_file(fixture_root .. "/src/calculator.lua", fixture_source))
  local pointer = root .. "/source/" .. code_analysis.filename
  return code_analysis.persist(fixture_root, pointer, {
    write = write_file,
    sha256_file = sha256_file,
  })
end

local function copy(value)
  return ai.json_decode(ai.json_encode(value))
end

return {
  test_verified_code_fact_influences_generation_and_pointer_only_provenance = function()
    local root = ".testing/runs/code-analysis-generation-positive"
    local reference, artifact, first_body = persist_analysis(root)
    local second_reference, _, second_body = persist_analysis(root)
    t.eq(second_body, first_body)
    t.eq(second_reference.artifact_digest, reference.artifact_digest)

    local model = generation_ports()
    local start_payload = module_start(reference, root .. "/module")
    local start = ai.start(start_payload, model.ports)
    t.eq(start.kind, "generation-request")
    local action = ai.generate(start.request, model.ports)
    t.eq(action.kind, "generation-proposal")
    t.eq(model.adapter_calls, 1)
    t.eq(model.context.code_analysis.artifact_digest, reference.artifact_digest)
    t.eq(model.context.code_analysis.facts[2].name, "calculate_total")

    local generated = ai.json_decode(read_file(root .. "/module/generated-test-cases.json"))
    t.eq(generated.case_count, 1)
    t.is_true(generated.cases[1].title:find("calculate_total", 1, true) ~= nil)
    t.eq(generated.cases[1].code_fact_pointer, artifact.facts[2].pointer)
    t.eq(generated.cases[1].provenance.code_analysis_artifact_pointer, reference.artifact_pointer)
    t.eq(generated.cases[1].provenance.code_analysis_digest, reference.artifact_digest)
    t.eq(generated.cases[1].provenance.code_analysis_version, reference.artifact_version)
    t.eq(generated.cases[1].provenance.code_fact_pointers[1], artifact.facts[2].pointer)
    local gate = generation.gate_generated_cases(generated, model.context, start_payload.cdp_execution.ai_generation)
    t.eq(gate.accepted_count, 1)
    t.is_true(generation.prompt_for_context(model.context):find("code_fact_pointer", 1, true) ~= nil)

    local mismatched = copy(generated)
    mismatched.cases[1].provenance.code_analysis_digest = string.rep("f", 64)
    t.eq(generation.gate_generated_cases(mismatched, model.context, start_payload.cdp_execution.ai_generation).rejected_count, 1)
    local empty_pointers = copy(generated)
    empty_pointers.cases[1].provenance.code_fact_pointers = {}
    t.eq(generation.gate_generated_cases(empty_pointers, model.context, start_payload.cdp_execution.ai_generation).rejected_count, 1)
    local unknown_pointer = copy(generated)
    unknown_pointer.cases[1].provenance.code_fact_pointers = { reference.artifact_pointer .. "#/facts/999" }
    t.eq(generation.gate_generated_cases(unknown_pointer, model.context, start_payload.cdp_execution.ai_generation).rejected_count, 1)
    local missing_provenance = copy(generated)
    missing_provenance.cases[1].provenance.code_analysis_artifact_pointer = nil
    missing_provenance.cases[1].provenance.code_analysis_digest = nil
    missing_provenance.cases[1].provenance.code_analysis_version = nil
    missing_provenance.cases[1].provenance.code_fact_pointers = nil
    t.eq(generation.gate_generated_cases(missing_provenance, model.context, start_payload.cdp_execution.ai_generation).rejected_count, 1)
    local binding_ok, binding_error = pcall(generation.validate_code_analysis_binding, reference, {
      artifact_pointer = reference.artifact_pointer,
      artifact_digest = string.rep("0", 64),
      artifact_version = reference.artifact_version,
    })
    t.eq(binding_ok, false)
    t.is_true(tostring(binding_error):find("code-analysis-binding-mismatch", 1, true) ~= nil)

    local event_body = ai.json_encode({ module_start = start_payload, request = start.request, proposal = action.proposal })
    t.is_true(event_body:find(reference.artifact_pointer, 1, true) ~= nil)
    t.is_true(event_body:find(reference.artifact_digest, 1, true) ~= nil)
    t.eq(event_body:find('"facts"', 1, true), nil)
    t.eq(event_body:find("return left + right", 1, true), nil)
    t.eq(event_body:find(first_body, 1, true), nil)
  end,

  test_stale_code_analysis_digest_blocks_before_generation_adapter = function()
    local root = ".testing/runs/code-analysis-generation-stale"
    local reference, _, body = persist_analysis(root)
    local model = generation_ports()
    local start = ai.start(module_start(reference, root .. "/module"), model.ports)
    t.eq(start.kind, "generation-request")

    assert(write_file(reference.artifact_pointer, body .. " "))
    local action = ai.generate(start.request, model.ports)
    t.eq(action.kind, "blocked-result")
    t.eq(action.result.status, "blocked")
    t.eq(model.adapter_calls, 0)
    t.eq(file_exists(root .. "/module/generated-test-cases.json"), false)
    local state = ai.json_decode(read_file(root .. "/module/ai-orchestration-state.json"))
    t.is_true(state.blocked_error:find("code-analysis: digest-mismatch", 1, true) ~= nil)
    local event_body = ai.json_encode(action)
    t.eq(event_body:find("generation-proposal", 1, true), nil)
    t.eq(event_body:find("calculate_total", 1, true), nil)
  end,
}
