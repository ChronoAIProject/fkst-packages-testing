local core = require("core")
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
