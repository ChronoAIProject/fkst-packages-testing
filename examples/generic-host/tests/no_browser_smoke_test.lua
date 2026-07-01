local graph = require("testkit.graph")
local t = fkst.test

local function readiness_check()
  return {
    queue = "browser-readiness.browser_readiness_check",
    payload = {
      schema = "browser-readiness.check.v1",
      sessions = {
        { role = "default", browser_harness_command = "true" },
      },
      request_context = {
        no_browser = true,
        dry_run = false,
        native_argv = { "true" },
      },
      source_ref = { kind = "host-module", ref = "module-a" },
    },
    source_ref = { kind = "external", reference = "module-a" },
  }
end

local function module_start(readiness)
  return {
    queue = "testing-pipeline.module_start",
    payload = {
      schema = "testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      preflight_result = readiness,
      artifact_root = ".testing/runs/generic-host-module-a",
      source_ref = { kind = "host-module", ref = "module-a" },
      trace_id = "trace-generic-host-module-a",
      dedup_key = "generic-host-module-a",
    },
    source_ref = { kind = "external", reference = "module-a" },
  }
end

return {
  test_no_browser_host_flow_reaches_publication_handoff = function()
    t.mock_command("'true'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local readiness_trace = graph.require_quiescent(graph.run(readiness_check(), { max_steps = 4 }))
    graph.require_delivery(readiness_trace, {
      queue = "browser-readiness.browser_readiness_check",
      consumer = "browser-readiness.check_readiness",
    })

    local readiness = graph.require_raise(readiness_trace, "browser-readiness.browser_readiness_result").payload
    t.eq(readiness.schema, "browser-readiness.result.v1")
    t.eq(readiness.status, "ready")
    t.eq(readiness.request_context.native_argv[1], "true")
    t.eq(readiness.request_context.no_browser, true)
    t.eq(readiness.request_context.dry_run, false)

    local pipeline_trace = graph.require_quiescent(graph.run(module_start(readiness), { max_steps = 12 }))
    graph.require_delivery(pipeline_trace, {
      queue = "testing-pipeline.module_start",
      consumer = "testing-pipeline.start_module",
    })
    graph.require_delivery(pipeline_trace, {
      queue = "module-test-loop.module_loop_request",
      consumer = "module-test-loop.start",
    })
    graph.require_delivery(pipeline_trace, {
      queue = "testing-runner.module_test_request",
      consumer = "testing-runner.run_module_loop",
    })
    graph.require_delivery(pipeline_trace, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(pipeline_trace, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })

    local result = graph.require_raise(pipeline_trace, "testing-runner.testing_result").payload
    t.eq(result.status, "passed")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "module-no-browser")
    t.eq(result.dedup_key, "generic-host-module-a")

    local publication = graph.require_raise(pipeline_trace, "test-publication.publication_request").payload
    t.eq(publication.schema, "test-publication.publication-request.v1")
    t.eq(publication.status, "passed")
    t.eq(publication.severity, "success")
    t.eq(publication.dedup_key, "generic-host-module-a")
    t.eq(publication.artifact_root, ".testing/runs/generic-host-module-a")
    t.eq(publication.metadata_path, ".testing/runs/generic-host-module-a/metadata.json")
  end,
}
