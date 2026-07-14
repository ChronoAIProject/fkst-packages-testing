local core = require("core")
local ai = require("module_ai_generation")
local module_inventory = require("module_inventory")
local native = require("fkst_native")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"
local fixture_cdp_url = "http://127.0.0.1:9222"
local fixture_digest = string.rep("a", 64)
local screenshot_digest = string.rep("b", 64)

local function passed_receipt()
  local cases = {
    { case_id = "dashboard:reachability", action = "navigate", assertions = { "url-within-scope", "document-ready" } },
    { case_id = "dashboard:page-load", action = "wait-for-load", assertions = { "document-ready", "url-within-scope" } },
    { case_id = "dashboard:visible-elements", action = "inspect-visible-elements", assertions = { "visible-target-present", "url-within-scope" } },
    { case_id = "dashboard:console-network-health", action = "collect-console-network-health", assertions = { "no-severe-console", "no-failed-document-request", "url-within-scope" } },
    { case_id = "dashboard:navigation", action = "bounded-navigation", assertions = { "url-within-scope", "document-ready" } },
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

local function append_ai_action(receipt)
  local pointer = ".testing/runs/module-a-cdp/evidence/execution/dashboard-ai-visible-surface.json"
  table.insert(receipt.actions, {
    step = #receipt.actions + 1,
    case_id = "dashboard:ai-visible-surface",
    action = "open-visible-surface",
    execution_status = "executed",
    assertion_status = "passed",
    observation = "typed browser action and assertions completed",
    evidence_pointer = pointer,
    assertion_results = {
      { type = "visible-target-present", status = "passed", observation = "visible target passed", evidence_pointer = pointer },
      { type = "url-within-scope", status = "passed", observation = "url scope passed", evidence_pointer = pointer },
      { type = "document-ready", status = "passed", observation = "document ready passed", evidence_pointer = pointer },
    },
  })
  receipt.action_count = #receipt.actions
  receipt.executed_action_count = #receipt.actions
  return receipt
end

local function failed_receipt()
  local value = passed_receipt()
  value.status = "failed"
  value.classification = "typed-browser-assertion-failed"
  value.executed_action_count = value.executed_action_count - 1
  value.failed_action_count = 1
  value.actions[3].execution_status = "failed"
  value.actions[3].assertion_status = "failed"
  value.actions[3].assertion_results[1].status = "failed"
  value.actions[3].assertion_results[1].observation = "visible target missing: Dashboard"
  return value
end

local function failed_receipt_with_screenshot()
  local value = failed_receipt()
  value.actions[3].assertion_results[1].screenshot_artifact = {
    path = ".testing/runs/module-a-cdp/evidence/screenshots/failure.png",
    media_type = "image/png",
    size_bytes = 128,
    sha256 = screenshot_digest,
  }
  return value
end

local function runtime_dependencies(receipt, opts)
  opts = opts or {}
  local written = {}
  local dependencies = {
    runtime_ports = {
      exec_argv = function(argv)
        if argv[3] == "hash-json" then
          return { exit_code = 0, stdout = fixture_digest .. "\n", stderr = "" }
        end
        t.eq(argv[3], "execute")
        return opts.execute_result or { exit_code = 0, stdout = "", stderr = "" }
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
  }
  return dependencies, written
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
  test_fkst_native_module_cdp_execution_runs_typed_runtime_and_writes_terminal_artifact = function()
    local written = {}
    local runtime, runtime_written = runtime_dependencies(passed_receipt())
    local result = core.run("module", request({
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    }), runtime)
    t.eq(result.status, "passed")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "module-cdp-execution")
    t.eq(result.native_summary.schema, "testing-runner.module-cdp-execution-summary.v1")
    t.eq(result.native_summary.execution_status, "passed")
    t.eq(result.native_summary.classification, "typed-browser-assertions-passed")
    t.eq(result.native_summary.planned_action_count, 0)
    t.eq(result.native_summary.executed_action_count, 5)
    t.eq(result.native_summary.execution_path, ".testing/runs/module-a-cdp/cdp-execution.json")
    t.eq(result.native_summary.metadata_path, ".testing/runs/module-a-cdp/metadata.json")
    t.eq(result.native_summary.evidence_bundle_path, ".testing/runs/module-a-cdp/evidence-bundle.json")
    t.eq(result.native_summary.action_count, 5)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"action":"navigate"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"execution_status":"executed"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"assertion_status":"passed"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"evidence_pointer":".testing/runs/module-a-cdp/evidence/execution/dashboard-reachability.json"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"url":"' .. fixture_base_url .. '/dashboard"', 1, true) ~= nil)
    t.eq(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find("secret", 1, true), nil)
    t.is_true(written[".testing/runs/module-a-cdp/test-plan.json"]:find('"priority":"P0"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/evidence-bundle.json"]:find('"execution_trace_path":".testing/runs/module-a-cdp/evidence/action-trace.json"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/evidence/action-trace.json"]:find('"action":"navigate"', 1, true) ~= nil)
    t.eq(written[".testing/runs/module-a-cdp/evidence/action-trace.json"]:find("secret", 1, true), nil)
    t.is_true(written[".testing/runs/module-a-cdp/evidence/console-network-summary.json"]:find('"status":"bounded-summary"', 1, true) ~= nil)
    t.is_true(runtime_written[".testing/runs/module-a-cdp/browser-execution-request.json"]:find('"schema":"testing-runtime.execution-request.v1"', 1, true) ~= nil)
    t.is_true(runtime_written[".testing/runs/module-a-cdp/browser-execution-request.json"]:find('"type":"document-ready"', 1, true) ~= nil)
    t.eq(runtime_written[".testing/runs/module-a-cdp/browser-execution-request.json"]:find("secret", 1, true), nil)
    for _, body in pairs(written) do t.eq(body:find(fixture_cdp_url, 1, true), nil) end
    t.is_true(written[".testing/runs/module-a-cdp/metadata.json"]:find('"schema":"testing-runner.module-cdp-execution-summary.v1"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/metadata.json"]:find('"evidence_bundle_path":".testing/runs/module-a-cdp/evidence-bundle.json"', 1, true) ~= nil)
  end,

  test_fkst_native_module_cdp_execution_resumes_reviewed_ai_artifacts_from_pointers = function()
    local ai_request, documents = reviewed_ai_documents()
    local written = {}
    local runtime, runtime_written = runtime_dependencies(append_ai_action(passed_receipt()))
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
    t.eq(result.native_summary.generated_case_gate_path, ".testing/runs/module-a-cdp/generated-case-gate.json")
    t.eq(result.native_summary.ai_agent_generation_path, ".testing/runs/module-a-cdp/ai-agent-generation.json")
    t.eq(result.native_summary.generated_case_agent_review_path, ".testing/runs/module-a-cdp/generated-case-agent-review.json")
    t.is_true(written[".testing/runs/module-a-cdp/test-plan.json"]:find('"case_origin":"ai-generated"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"case_id":"dashboard:ai-visible-surface"', 1, true) ~= nil)
    t.is_true(runtime_written[".testing/runs/module-a-cdp/browser-execution-request.json"]:find('"case_id":"dashboard:ai-visible-surface"', 1, true) ~= nil)
  end,

  test_fkst_native_module_cdp_execution_classifies_valid_failed_assertion_as_product_defect = function()
    local written = {}
    local runtime = runtime_dependencies(failed_receipt())
    local result = core.run("module", request({
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    }), runtime)

    t.eq(result.status, "failed")
    t.eq(result.native_summary.classification, "typed-browser-assertion-failed")
    t.eq(result.native_summary.outcome_classification, "product-defect")
    t.eq(result.native_summary.executed_action_count, 4)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"failed_action_count":1', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find("visible target missing", 1, true) ~= nil)
  end,

  test_fkst_native_wires_one_failure_screenshot_pointer_to_event_index_and_report = function()
    local written = {}
    local runtime, runtime_written = runtime_dependencies(failed_receipt_with_screenshot())
    local result = core.run("module", request({
      cdp_execution = {
        schema = "testing-runner.module-cdp-execution.v1",
        step_budget = 8,
        case_priorities = { "P0", "P1" },
        redaction_selectors = { "[data-fkst-sensitive]" },
      },
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    }), runtime)

    local screenshot_path = ".testing/runs/module-a-cdp/evidence/screenshots/failure.png"
    t.eq(result.status, "failed")
    t.eq(result.native_summary.failure_screenshot.path, screenshot_path)
    t.eq(result.native_summary.failure_screenshot.sha256, screenshot_digest)
    t.is_true(runtime_written[".testing/runs/module-a-cdp/browser-execution-request.json"]:find('"redaction_selectors":["[data-fkst-sensitive]"]', 1, true) ~= nil)

    local index = written[".testing/runs/module-a-cdp/evidence/screenshot-index.json"]
    t.is_true(index:find('"ref_count":1', 1, true) ~= nil)
    t.is_true(index:find('"path":"' .. screenshot_path .. '"', 1, true) ~= nil)
    t.is_true(index:find('"sha256":"' .. screenshot_digest .. '"', 1, true) ~= nil)

    local failures = written[".testing/runs/module-a-cdp/evidence/failures.json"]
    t.is_true(failures:find('"failed_assertion_count":1', 1, true) ~= nil)
    t.is_true(failures:find('"screenshot_artifact":{"media_type":"image/png","path":"' .. screenshot_path, 1, true) ~= nil)

    local report = written[".testing/runs/module-a-cdp/stage-report.md"]
    t.is_true(report:find("## Failed assertions", 1, true) ~= nil)
    t.is_true(report:find("## Screenshot index", 1, true) ~= nil)
    t.is_true(report:find(screenshot_path, 1, true) ~= nil)
    t.eq(report:find("fixture-secret", 1, true), nil)

    local metadata = written[".testing/runs/module-a-cdp/metadata.json"]
    t.is_true(metadata:find('"failure_screenshot":{"media_type":"image/png","path":"' .. screenshot_path, 1, true) ~= nil)
    t.eq(metadata:find("data:image", 1, true), nil)
  end,

  test_fkst_native_module_cdp_execution_blocks_malformed_receipt = function()
    local value = passed_receipt()
    table.remove(value.actions[1].assertion_results, 2)
    local runtime = runtime_dependencies(value)
    local result = core.run("module", request(), runtime)

    t.eq(result.status, "blocked")
    t.eq(result.native_summary.classification, "runtime-receipt-invalid")
    t.eq(result.native_summary.outcome_classification, "harness-tooling-issue")
    t.eq(result.native_summary.executed_action_count, 0)
  end,

  test_fkst_native_module_cdp_execution_blocks_runtime_process_failure = function()
    local written = {}
    local runtime = runtime_dependencies(passed_receipt(), {
      execute_result = {
        exit_code = 1,
        stdout = "",
        stderr = "CDP disconnected token=secret http://127.0.0.1:9222",
      },
    })
    local result = core.run("module", request({
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    }), runtime)

    t.eq(result.status, "blocked")
    t.eq(result.native_summary.classification, "cdp-runtime-failure")
    t.eq(result.native_summary.outcome_classification, "harness-tooling-issue")
    local execution = written[".testing/runs/module-a-cdp/cdp-execution.json"]
    t.eq(execution:find("secret", 1, true), nil)
    t.eq(execution:find("127.0.0.1:9222", 1, true), nil)
  end,

  test_fkst_native_module_cdp_execution_blocks_without_reused_session = function()
    local result = core.run("module", request({
      preflight_result = {
        schema = "browser-readiness.result.v1",
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready" },
        },
      },
    }))
    t.eq(result.status, "blocked")
    t.eq(result.adapter.mode, "module-cdp-execution-blocked")
    t.eq(result.native_summary.execution_status, "blocked")
    t.eq(result.native_summary.classification, "missing-cdp-session")
  end,

  test_fkst_native_module_cdp_execution_blocks_userinfo_authority_before_planning = function()
    local result = core.run("module", request({
      ui_loop = {
        base_url = "http://localhost:8080@evil.example/app",
        allowed_origins = { "http://localhost:8080@evil.example" },
        cdp_readiness_ref = "cdp-ready",
        mutation_policy = "read-only",
      },
    }))

    t.eq(result.status, "blocked")
    t.eq(result.adapter.mode, "module-ui-loop-blocked")
    t.is_true(result.stderr_excerpt:find("blocked unsafe runtime input", 1, true) ~= nil)
  end,

  test_fkst_native_module_cdp_execution_writes_safe_mutation_lifecycle_only_to_artifact = function()
    local written = {}
    local cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 8,
      case_priorities = { "P2" },
      mutation_fixtures = {
        {
          case_id = "dashboard:write-flow",
          mutation_kind = "edit-test-data",
          fixture_lifecycle_path = ".testing/runs/fixtures/dashboard-lifecycle",
        },
      },
    }
    local result = core.run("module", request({
      ui_loop = {
        base_url = fixture_base_url,
        allowed_origins = { fixture_origin },
        cdp_readiness_ref = "cdp-ready",
        mutation_policy = "host-approved",
      },
      cdp_execution = cdp_execution,
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    }))
    t.eq(result.status, "degraded")
    t.eq(result.native_summary.classification, "mutation-execution-deferred")
    t.eq(result.native_summary.action_count, 1)
    t.eq(result.native_summary.planned_action_count, 1)
    t.eq(result.native_summary.blocked_action_count, 0)
    t.eq(result.native_summary.fixture_lifecycle_path, nil)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"action":"safe-mutation-fixture"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"execution_status":"planned"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"fixture_lifecycle_path":".testing/runs/fixtures/dashboard-lifecycle"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/test-plan.json"]:find('"classification":"safe-local-test-data"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/evidence/action-trace.json"]:find('"action":"safe-mutation-fixture"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/evidence/action-trace.json"]:find('"fixture_lifecycle_path":".testing/runs/fixtures/dashboard-lifecycle"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/metadata.json"]:find("fixture_lifecycle_path", 1, true) == nil)
  end,
}
