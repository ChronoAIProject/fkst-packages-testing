local core = require("core")
local ai = require("module_ai_generation")
local module_inventory = require("module_inventory")
local native = require("fkst_native")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"
local fixture_cdp_url = "http://127.0.0.1:9222"
local fixture_digest = string.rep("a", 64)

local function passed_receipt()
  local cases = {
    { case_id = "dashboard:reachability", action = "navigate", assertions = { "url-within-scope", "document-ready" } },
    { case_id = "dashboard:page-load", action = "wait-for-load", assertions = { "document-ready", "url-within-scope" } },
    { case_id = "dashboard:visible-elements", action = "inspect-visible-elements", assertions = { "visible-target-present", "url-within-scope" } },
    { case_id = "dashboard:console-network-health", action = "collect-console-network-health", assertions = { "no-severe-console", "no-failed-document-request", "url-within-scope" } },
    { case_id = "dashboard:navigation", action = "bounded-navigation", assertions = { "url-within-scope", "document-ready" } },
    { case_id = "dashboard:ai-visible-surface", action = "open-visible-surface", assertions = { "visible-target-present", "url-within-scope", "document-ready" } },
  }
  local actions = {}
  for step, case in ipairs(cases) do
    local pointer = ".testing/runs/module-a-cdp/evidence/execution/" .. case.case_id:gsub(":", "-") .. ".json"
    local assertion_results = {}
    for _, assertion in ipairs(case.assertions) do
      table.insert(assertion_results, {
        type = assertion,
        status = "passed",
        observation = assertion .. " passed",
        evidence_pointer = pointer,
      })
    end
    table.insert(actions, {
      step = step,
      case_id = case.case_id,
      action = case.action,
      execution_status = "executed",
      assertion_status = "passed",
      observation = "typed browser action and assertions completed",
      evidence_pointer = pointer,
      assertion_results = assertion_results,
    })
  end
  return {
    schema = "testing-runtime.execution-receipt.v1",
    module = "module-a",
    request_sha256 = fixture_digest,
    status = "passed",
    classification = "typed-browser-assertions-passed",
    action_count = #actions,
    executed_action_count = #actions,
    failed_action_count = 0,
    blocked_action_count = 0,
    actions = actions,
  }
end

local function runtime_dependencies(receipt)
  local written = {}
  return {
    runtime_ports = {
      exec_argv = function(argv)
        if argv[3] == "hash-json" then
          return { exit_code = 0, stdout = fixture_digest .. "\n", stderr = "" }
        end
        t.eq(argv[3], "execute")
        return { exit_code = 0, stdout = "", stderr = "" }
      end,
      read = function(path)
        t.eq(path, ".testing/runs/module-a-cdp/browser-execution-receipt.json")
        return "{}"
      end,
      write = function(path, body)
        written[path] = body
        return true
      end,
      decode = function()
        return receipt
      end,
    },
  }, written
end

local function request(overrides)
  local value = {
    schema = "testing-runner.module-test-loop.request.v1",
    backend = "fkst-native",
    module = "module-a",
    dry_run = false,
    ui_loop = {
      base_url = fixture_base_url,
      allowed_origins = { fixture_origin },
      cdp_readiness_ref = "cdp-ready",
      mutation_policy = "read-only",
    },
    module_discovery = {
      schema = "testing-runner.module-discovery.v1",
      observations = {
        {
          id = "dashboard",
          name = "Dashboard",
          entry_url = fixture_base_url .. "/dashboard?secret=value#state",
          visible_label = "Dashboard",
          discovery_source = "navigation",
          confidence = "high",
          evidence_pointer = ".testing/runs/evidence/dashboard",
        },
      },
    },
    cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 8,
      case_priorities = { "P0", "P1" },
    },
    preflight_result = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "admin", status = "ready", cdp_url = fixture_cdp_url },
      },
    },
    artifact_root = ".testing/runs/module-a-cdp",
    artifact_writer = function()
      return true
    end,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function approval_result(proposal_id, source_ref, extra)
  local value = {
    schema = "consensus.consensus_reached.v1",
    proposal_id = proposal_id,
    decision = "approve",
    source_ref = source_ref,
    angle_results = {
      { angle = "teleology", verdict = "approve", exit_code = 0 },
      { angle = "parsimony", verdict = "approve", exit_code = 0 },
      { angle = "fidelity", verdict = "approve", exit_code = 0 },
      { angle = "natural-ownership", verdict = "approve", exit_code = 0 },
      { angle = "proportional-containment", verdict = "approve", exit_code = 0 },
    },
  }
  for key, item in pairs(extra or {}) do value[key] = item end
  return value
end

local function reviewed_ai_documents()
  local root = ".testing/runs/module-a-cdp"
  local ai_request = {
    schema = ai.request_schema,
    mode = "autonomous-reviewed",
    case_budget = 1,
    context_manifest_path = root .. "/ai-context-manifest.json",
    generated_cases_path = root .. "/generated-test-cases.json",
    generated_case_gate_path = root .. "/generated-case-gate.json",
    ai_agent_generation_path = root .. "/ai-agent-generation.json",
    generated_case_agent_review_path = root .. "/generated-case-agent-review.json",
    ai_test_design_loop_path = root .. "/ai-test-design-loop.json",
  }
  local payload = request()
  local inventory = module_inventory.inventory(payload.module_discovery, payload.ui_loop, root, {
    readiness = { status = "ready" },
  })
  local context = ai.build_context(inventory, payload.ui_loop, root, {
    ai_generation = ai_request,
    step_budget = 8,
    case_priorities = { "P0", "P1" },
  })
  local generated = ai.canonicalize_candidates(context, ai_request, {
    schema = ai.candidate_schema,
    cases = {
      {
        module_id = "dashboard",
        priority = "P1",
        title = "Open dashboard details",
        objective = "Verify dashboard details open from the visible surface.",
        case_kind = "read-only-interaction",
        actions = {
          { action = "open-visible-surface", target = "Dashboard", expected = "Dashboard details are visible." },
        },
        expected_observable = "Dashboard details remain visible and same-origin.",
      },
    },
  }, "model-dashboard")
  generated.cases[1].id = "dashboard:ai-visible-surface"
  local gate = ai.gate_generated_cases(generated, context, ai_request)
  local agent_generation = ai.generation_from_agent_results(context, approval_result("testing-ai-generation", {
    kind = "testing-ai-generation",
    ref = root,
  }, {
    candidate_generation_digest = generated.generation_digest,
    generated_case_count = generated.case_count,
  }))
  local agent_review = ai.review_from_agent_results(context, gate, approval_result("testing-ai-review", {
    kind = "testing-ai-review",
    ref = root,
  }))
  local closure = ai.build_review_closure(context, generated, gate, agent_generation, agent_review)
  local docs = {
    [context.context_manifest_path] = context,
    [context.generated_cases_path] = generated,
    [context.generated_case_gate_path] = gate,
    [context.ai_agent_generation_path] = agent_generation,
    [context.generated_case_agent_review_path] = agent_review,
    [context.ai_test_design_loop_path] = closure,
  }
  local encoded = {}
  for path, doc in pairs(docs) do encoded[path] = native.json_encode(doc) .. "\n" end
  return ai_request, encoded
end

return {
  test_reviewed_ai_case_resumes_from_pointers_into_typed_cdp_execution = function()
    local ai_request, documents = reviewed_ai_documents()
    local written = {}
    local runtime, runtime_written = runtime_dependencies(passed_receipt())
    local cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 8,
      case_priorities = { "P0", "P1" },
      ai_generation = ai_request,
    }
    local result = core.run("module", request({
      cdp_execution = cdp_execution,
      artifact_reader = function(path)
        return documents[path]
      end,
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    }), runtime)

    t.eq(result.status, "passed")
    t.eq(result.adapter.mode, "module-cdp-execution")
    t.eq(result.native_summary.generated_cases_path, ".testing/runs/module-a-cdp/generated-test-cases.json")
    t.eq(result.native_summary.generated_case_gate_path, ".testing/runs/module-a-cdp/generated-case-gate.json")
    t.eq(result.native_summary.generated_case_agent_review_path, ".testing/runs/module-a-cdp/generated-case-agent-review.json")
    t.is_true(written[".testing/runs/module-a-cdp/test-plan.json"]:find('"case_origin":"ai-generated"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"case_id":"dashboard:ai-visible-surface"', 1, true) ~= nil)
    t.is_true(runtime_written[".testing/runs/module-a-cdp/browser-execution-request.json"]:find('"case_id":"dashboard:ai-visible-surface"', 1, true) ~= nil)
  end,
}
