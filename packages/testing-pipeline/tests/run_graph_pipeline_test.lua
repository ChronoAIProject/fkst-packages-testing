local graph = require("testkit.graph")
local t = fkst.test

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

local function planned_module_start_event()
  local event = module_start_event()
  event.payload.dry_run = true
  event.payload.no_browser = nil
  event.payload.native_argv = nil
  event.payload.artifact_root = ".testing/runs/module-a-planning"
  event.payload.dedup_key = "module-a-planning-run"
  event.payload.module_evidence = {
    entry = { route = "/modules/a", loaded = true, title = "Module A" },
    visible_elements = { "Module A heading", "Search box" },
    signals = { console = { clean = true }, network = { status = "clean" } },
    interactions = {
      { kind = "navigation", label = "Open details" },
      { kind = "search", label = "Search records" },
      { kind = "write-flow", label = "Create record" },
      { kind = "negative-path", label = "Invalid search input" },
    },
  }
  return event
end

local function prepare_artifact_dir()
  local ok = os.execute("mkdir -p .testing/runs/module-a")
  if ok ~= true and ok ~= 0 then
    error("failed to prepare test artifact directory")
  end
end

local function read_file(path)
  local file = io.open(path, "r")
  if file == nil then return nil end
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

  test_module_start_writes_feature_inventory_and_plan_artifacts = function()
    local trace = graph.require_quiescent(graph.run(planned_module_start_event(), { max_steps = 8 }))

    graph.require_delivery(trace, {
      queue = "testing-pipeline.module_start",
      consumer = "testing-pipeline.start_module",
    })

    local request = graph.require_raise(trace, "module-test-loop.module_loop_request")
    t.eq(request.payload.planning_artifacts.schema, "testing-pipeline.planning-artifacts.v1")
    t.eq(request.payload.planning_artifacts.feature_inventory_path, ".testing/runs/module-a-planning/feature-inventory.json")
    t.eq(request.payload.planning_artifacts.test_plan_path, ".testing/runs/module-a-planning/test-plan.json")

    local inventory = read_file(".testing/runs/module-a-planning/feature-inventory.json")
    local plan = read_file(".testing/runs/module-a-planning/test-plan.json")
    t.is_true(inventory:find('"schema":"testing-pipeline.feature-inventory.v1"', 1, true) ~= nil)
    t.is_true(inventory:find('"label":"Module A heading"', 1, true) ~= nil)
    t.is_true(plan:find('"schema":"testing-pipeline.test-plan.v1"', 1, true) ~= nil)
    t.is_true(plan:find('"priority":"P0"', 1, true) ~= nil)
    t.is_true(plan:find('"priority":"P1"', 1, true) ~= nil)
    t.is_true(plan:find('"priority":"P2"', 1, true) ~= nil)
    t.is_true(plan:find('"status":"executable"', 1, true) ~= nil)
    t.is_true(plan:find('"status":"blocked"', 1, true) ~= nil)
    t.is_true(plan:find('"status":"not-executed risk"', 1, true) ~= nil)
  end,
}
