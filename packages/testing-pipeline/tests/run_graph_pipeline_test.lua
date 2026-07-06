local graph = require("testkit.graph")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"
local module_discovery_start_event

local function testing_result(status)
  return {
    schema = "testing-runner.result.v1",
    job = "module-test-loop",
    status = status or "failed",
    artifact_root = ".testing/runs/module-a",
    source_ref = { kind = "external", ref = "module-a" },
    dedup_key = "module-a-run",
    adapter = { name = "fkst-native", mode = "module-no-browser" },
    native_summary = {
      schema = "testing-runner.module-no-browser-summary.v1",
      module = "module-a",
      status = status or "failed",
      mode = "argv",
    },
    exit_code = status == "passed" and 0 or 1,
    stderr_excerpt = status == "passed" and "" or "check failed",
  }
end

local function result_event(status)
  return {
    queue = "testing-runner.testing_result",
    payload = testing_result(status),
    source_ref = { kind = "external", reference = "module-a" },
  }
end

local function module_start_event()
  return {
    queue = "module_start",
    payload = {
      schema = "testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      dry_run = false,
      no_browser = true,
      native_argv = { "true" },
      artifact_root = ".testing/runs/module-a",
      source_ref = { kind = "external", ref = "module-a" },
      dedup_key = "module-a-run",
    },
    source_ref = { kind = "external", reference = "module-a" },
  }
end

local function module_ui_loop_start_event()
  return {
    queue = "module_start",
    payload = {
      schema = "testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      dry_run = false,
      ui_loop = {
        base_url = fixture_base_url,
        allowed_origins = { fixture_origin },
        browser_readiness_ref = ".testing/runs/readiness",
        cdp_readiness_ref = "cdp-ready",
        mutation_policy = "read-only",
        gap_ref = ".testing/runs/gap",
        backlog_ref = "backlog-item-1",
      },
      artifact_root = ".testing/runs/module-a-ui",
      source_ref = { kind = "external", ref = "module-a" },
      dedup_key = "module-a-ui-run",
    },
    source_ref = { kind = "external", reference = "module-a" },
  }
end

local function module_cdp_execution_start_event()
  local event = module_discovery_start_event()
  event.payload.artifact_root = ".testing/runs/module-a-cdp"
  event.payload.dedup_key = "module-a-cdp-run"
  event.payload.ui_loop.cdp_readiness_ref = "cdp-ready"
  event.payload.cdp_execution = {
    schema = "testing-runner.module-cdp-execution.v1",
    step_budget = 8,
    case_priorities = { "P0", "P1" },
  }
  table.insert(event.payload.preflight_result.sessions, { role = "admin", status = "ready" })
  return event
end

local function module_mutation_execution_start_event()
  local event = module_discovery_start_event()
  event.payload.artifact_root = ".testing/runs/module-a-mutation"
  event.payload.dedup_key = "module-a-mutation-run"
  event.payload.ui_loop.cdp_readiness_ref = "cdp-ready"
  event.payload.ui_loop.mutation_policy = "host-approved"
  event.payload.cdp_execution = {
    schema = "testing-runner.module-cdp-execution.v1",
    step_budget = 8,
    case_priorities = { "P2" },
    mutation_fixtures = {
      {
        case_id = "dashboard:write-flow",
        mutation_kind = "create-test-data",
        fixture_ref = ".testing/runs/fixtures/dashboard-create",
        cleanup_ref = ".testing/runs/fixtures/dashboard-cleanup",
        evidence_pointer = ".testing/runs/evidence/dashboard-create",
      },
    },
  }
  table.insert(event.payload.preflight_result.sessions, { role = "admin", status = "ready" })
  return event
end

module_discovery_start_event = function()
  return {
    queue = "module_start",
    payload = {
      schema = "testing-pipeline.module-start.v1",
      module = "module-a",
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
            id = "dashboard",
            name = "Dashboard",
            entry_url = fixture_base_url .. "/dashboard?user=secret#state",
            visible_label = "Dashboard",
            discovery_source = "navigation",
            confidence = "high",
            evidence_pointer = ".testing/runs/evidence/dashboard",
          },
        },
      },
      preflight_result = {
        schema = "browser-readiness.result.v1",
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready" },
        },
      },
      artifact_root = ".testing/runs/module-a-inventory",
      source_ref = { kind = "external", ref = "module-a" },
      dedup_key = "module-a-inventory-run",
    },
    source_ref = { kind = "external", reference = "module-a" },
  }
end

local function prepare_artifact_dir()
  local ok = os.execute("mkdir -p .testing/runs/module-a")
  if ok ~= true and ok ~= 0 then
    error("failed to prepare test artifact directory")
  end
end

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local body = file:read("*a")
  file:close()
  return body
end

return {
  test_run_graph_artifact_summary_flows_to_publication_request = function()
    local trace = graph.require_quiescent(graph.run(result_event("failed"), { max_steps = 8 }))

    graph.require_delivery(trace, {
      queue = "testing-runner.testing_result",
      consumer = "testing-pipeline.summarize_result",
    })
    graph.require_delivery(trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local summary = graph.require_raise(trace, "test-artifacts.artifact_summary")
    t.eq(summary.payload.schema, "test-artifacts.summary.v1")
    t.eq(summary.payload.status, "failed")
    t.eq(summary.payload.artifact_root, ".testing/runs/module-a")
    t.eq(summary.payload.metadata_path, ".testing/runs/module-a/metadata.json")
    t.eq(summary.payload.source_ref.ref, "module-a")

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.schema, "test-publication.publication-request.v1")
    t.eq(publication.payload.publication_kind, "testing-summary")
    t.eq(publication.payload.channel, "testing")
    t.eq(publication.payload.severity, "failure")
    t.eq(publication.payload.subject, "Testing failed: module-test-loop")
    t.eq(publication.payload.dedup_key, "module-a-run")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a")
    t.eq(publication.payload.metadata_path, ".testing/runs/module-a/metadata.json")
  end,

  test_run_graph_no_browser_module_reaches_publication_request = function()
    prepare_artifact_dir()
    t.mock_command("'true'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local trace = graph.require_quiescent(graph.run(module_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "testing-pipeline.module_start",
      consumer = "testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "module-test-loop.module_loop_request",
      consumer = "module-test-loop.start",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "passed")
    t.eq(result.payload.exit_code, 0)
    t.eq(result.payload.adapter.name, "fkst-native")
    t.eq(result.payload.adapter.mode, "module-no-browser")
    t.eq(result.payload.native_summary.mode, "argv")

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "passed")
    t.eq(publication.payload.severity, "success")
    t.eq(publication.payload.subject, "Testing passed: module-test-loop")
    t.eq(publication.payload.dedup_key, "module-a-run")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a")
  end,

  test_run_graph_module_discovery_reaches_inventory_publication_request = function()
    local trace = graph.require_quiescent(graph.run(module_discovery_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "testing-pipeline.module_start",
      consumer = "testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "module-test-loop.module_loop_request",
      consumer = "module-test-loop.start",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "degraded")
    t.eq(result.payload.native_summary.schema, "testing-runner.module-inventory-summary.v1")
    t.eq(result.payload.native_summary.discovery_status, "complete")
    t.eq(result.payload.native_summary.inventory_path, ".testing/runs/module-a-inventory/module-inventory.json")
    t.eq(result.payload.native_summary.feature_inventory_path, ".testing/runs/module-a-inventory/feature-inventory.json")
    t.eq(result.payload.native_summary.test_plan_path, ".testing/runs/module-a-inventory/test-plan.json")
    t.eq(result.payload.native_summary.plan_status, "complete")
    t.eq(result.payload.native_summary.module_count, 1)

    local summary = graph.require_raise(trace, "test-artifacts.artifact_summary")
    t.eq(summary.payload.native_summary.schema, "testing-runner.module-inventory-summary.v1")
    t.eq(summary.payload.native_summary.inventory_path, ".testing/runs/module-a-inventory/module-inventory.json")
    t.eq(summary.payload.native_summary.feature_inventory_path, ".testing/runs/module-a-inventory/feature-inventory.json")
    t.eq(summary.payload.native_summary.test_plan_path, ".testing/runs/module-a-inventory/test-plan.json")
    t.eq(summary.payload.native_summary.plan_status, "complete")
    t.eq(summary.payload.native_summary.module_count, 1)

    local plan = read_file(".testing/runs/module-a-inventory/test-plan.json")
    t.is_true(plan:find('"schema":"testing-runner.module-test-plan.v1"', 1, true) ~= nil)
    t.is_true(plan:find('"priority":"P0"', 1, true) ~= nil)
    t.is_true(plan:find('"priority":"P1"', 1, true) ~= nil)
    t.is_true(plan:find('"priority":"P2"', 1, true) ~= nil)
    t.is_true(plan:find('"review_status":"executable"', 1, true) ~= nil)
    t.is_true(plan:find('"review_status":"blocked"', 1, true) ~= nil)
    t.is_true(plan:find('"review_status":"not-executed-risk"', 1, true) ~= nil)

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "degraded")
    t.eq(publication.payload.severity, "warning")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a-inventory")
    t.eq(publication.payload.metadata_path, ".testing/runs/module-a-inventory/metadata.json")
  end,

  test_run_graph_module_cdp_execution_reaches_publication_request = function()
    local trace = graph.require_quiescent(graph.run(module_cdp_execution_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "testing-pipeline.module_start",
      consumer = "testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "module-test-loop.module_loop_request",
      consumer = "module-test-loop.start",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "passed")
    t.eq(result.payload.adapter.name, "fkst-native")
    t.eq(result.payload.adapter.mode, "module-cdp-execution")
    t.eq(result.payload.native_summary.schema, "testing-runner.module-cdp-execution-summary.v1")
    t.eq(result.payload.native_summary.execution_path, ".testing/runs/module-a-cdp/cdp-execution.json")
    t.eq(result.payload.native_summary.action_count, 5)

    local summary = graph.require_raise(trace, "test-artifacts.artifact_summary")
    t.eq(summary.payload.status, "passed")
    t.eq(summary.payload.native_summary.schema, "testing-runner.module-cdp-execution-summary.v1")
    t.eq(summary.payload.native_summary.execution_path, ".testing/runs/module-a-cdp/cdp-execution.json")
    t.eq(summary.payload.native_summary.action_count, 5)

    local execution = read_file(".testing/runs/module-a-cdp/cdp-execution.json")
    t.is_true(execution:find('"action":"navigate"', 1, true) ~= nil)
    t.is_true(execution:find('"url":"' .. fixture_base_url .. '/dashboard"', 1, true) ~= nil)
    t.eq(execution:find("secret", 1, true), nil)

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "passed")
    t.eq(publication.payload.severity, "success")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a-cdp")
    t.eq(publication.payload.metadata_path, ".testing/runs/module-a-cdp/metadata.json")
  end,

  test_run_graph_safe_mutation_execution_reaches_publication_request = function()
    local trace = graph.require_quiescent(graph.run(module_mutation_execution_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "testing-pipeline.module_start",
      consumer = "testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "passed")
    t.eq(result.payload.native_summary.schema, "testing-runner.module-cdp-execution-summary.v1")
    t.eq(result.payload.native_summary.action_count, 1)
    t.eq(result.payload.native_summary.cleanup_ref, nil)

    local execution = read_file(".testing/runs/module-a-mutation/cdp-execution.json")
    t.is_true(execution:find('"action":"safe-mutation-fixture"', 1, true) ~= nil)
    t.is_true(execution:find('"cleanup_ref":".testing/runs/fixtures/dashboard-cleanup"', 1, true) ~= nil)

    local metadata = read_file(".testing/runs/module-a-mutation/metadata.json")
    t.eq(metadata:find("cleanup_ref", 1, true), nil)

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "passed")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a-mutation")
  end,

  test_run_graph_module_ui_loop_reaches_degraded_publication_request = function()
    local trace = graph.require_quiescent(graph.run(module_ui_loop_start_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "testing-pipeline.module_start",
      consumer = "testing-pipeline.start_module",
    })
    graph.require_delivery(trace, {
      queue = "module-test-loop.module_loop_request",
      consumer = "module-test-loop.start",
    })
    graph.require_delivery(trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(trace, "testing-runner.testing_result")
    t.eq(result.payload.status, "degraded")
    t.eq(result.payload.adapter.name, "fkst-native")
    t.eq(result.payload.adapter.mode, "module-ui-loop-contract")
    t.eq(result.payload.native_summary.schema, "testing-runner.module-ui-loop-summary.v1")
    t.eq(result.payload.native_summary.classification, "browser-exploration-deferred")
    t.eq(result.payload.native_summary.artifact_root, ".testing/runs/module-a-ui")
    t.eq(result.payload.native_summary.metadata_path, ".testing/runs/module-a-ui/metadata.json")
    t.eq(result.payload.native_summary.gap_ref, ".testing/runs/gap")
    t.eq(result.payload.native_summary.backlog_ref, "backlog-item-1")

    local summary = graph.require_raise(trace, "test-artifacts.artifact_summary")
    t.eq(summary.payload.status, "degraded")
    t.eq(summary.payload.native_summary.schema, "testing-runner.module-ui-loop-summary.v1")
    t.eq(summary.payload.native_summary.metadata_path, ".testing/runs/module-a-ui/metadata.json")
    t.eq(summary.payload.artifact_root, ".testing/runs/module-a-ui")

    local publication = graph.require_raise(trace, "test-publication.publication_request")
    t.eq(publication.payload.status, "degraded")
    t.eq(publication.payload.severity, "warning")
    t.eq(publication.payload.subject, "Testing degraded: module-test-loop")
    t.eq(publication.payload.dedup_key, "module-a-ui-run")
    t.eq(publication.payload.artifact_root, ".testing/runs/module-a-ui")
    t.eq(publication.payload.metadata_path, ".testing/runs/module-a-ui/metadata.json")
  end,
}
