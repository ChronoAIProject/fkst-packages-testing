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

local function browser_driver_result(overrides)
  local result = testing_result("failed")
  result.adapter = { name = "fkst-native", mode = "browser-driver" }
  result.native_summary = {
    schema = "testing-runner.browser-driver-summary.v1",
    module = "module-a",
    driver = "multi_session_browser_harness",
    status = result.status,
    mode = "argv",
    readiness = {
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "admin", status = "ready" },
      },
    },
  }
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
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

local function prepare_artifact_dir()
  local ok = os.execute("mkdir -p .testing/runs/module-a")
  if ok ~= true and ok ~= 0 then
    error("failed to prepare test artifact directory")
  end
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

  test_run_graph_classifies_harness_uncertainty_and_raises_gap_backlog = function()
    local trace = graph.require_quiescent(graph.run({
      queue = "testing-runner.testing_result",
      payload = browser_driver_result(),
      source_ref = { kind = "external", reference = "module-a" },
    }, { max_steps = 10 }))

    graph.require_delivery(trace, {
      queue = "testing-runner.testing_result",
      consumer = "testing-pipeline.classify_result",
    })

    local classification = graph.require_raise(trace, "testing-pipeline.outcome_classification")
    t.eq(classification.payload.schema, "testing-pipeline.outcome-classification.v1")
    t.eq(classification.payload.category, "harness_tooling_issue")
    t.eq(classification.payload.reason, "harness or CDP uncertainty prevents product defect classification")
    t.eq(#classification.payload.evidence_refs, 0)

    local backlog = graph.require_raise(trace, "testing-pipeline.gap_backlog")
    t.eq(backlog.payload.schema, "testing-pipeline.gap-backlog.v1")
    t.eq(backlog.payload.blocked_modules[1].module, "module-a")
    t.eq(backlog.payload.required_follow_up[1].follow_up, "stabilize harness or CDP signal and rerun")
    t.eq(backlog.payload.backlog_ref.ref, ".testing/runs/module-a/gap-backlog.json")
  end,

  test_run_graph_allows_product_defect_only_with_user_facing_repro_evidence = function()
    local trace = graph.require_quiescent(graph.run({
      queue = "testing-runner.testing_result",
      payload = browser_driver_result({
        adapter = { name = "fkst-native", mode = "module-no-browser" },
        native_summary = {
          schema = "testing-runner.module-no-browser-summary.v1",
          module = "module-a",
          status = "failed",
          mode = "argv",
        },
        evidence_refs = {
          { kind = "artifact", ref = ".testing/runs/module-a/evidence/product.json", user_facing = true, reproducible = true },
        },
      }),
      source_ref = { kind = "external", reference = "module-a" },
    }, { max_steps = 10 }))

    local classification = graph.require_raise(trace, "testing-pipeline.outcome_classification")
    t.eq(classification.payload.category, "product_defect")
    t.eq(classification.payload.evidence_refs[1].user_facing, true)
    t.eq(classification.payload.evidence_refs[1].reproducible, true)
    t.eq(graph.find_raise(trace, "testing-pipeline.gap_backlog"), nil)
  end,

  test_run_graph_rejects_unbound_product_evidence_refs = function()
    local trace = graph.require_quiescent(graph.run({
      queue = "testing-runner.testing_result",
      payload = browser_driver_result({
        adapter = { name = "fkst-native", mode = "module-no-browser" },
        native_summary = {
          schema = "testing-runner.module-no-browser-summary.v1",
          module = "module-a",
          status = "failed",
          mode = "argv",
        },
        evidence_refs = {
          { kind = "artifact", ref = ".testing/runs/other/evidence/product.json", user_facing = true, reproducible = true },
        },
      }),
      source_ref = { kind = "external", reference = "module-a" },
    }, { max_steps = 10 }))

    local classification = graph.require_raise(trace, "testing-pipeline.outcome_classification")
    t.eq(classification.payload.category, "not_executed_risk")
    t.eq(#classification.payload.evidence_refs, 0)
  end,
}
