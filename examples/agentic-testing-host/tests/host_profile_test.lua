local graph = require("testkit.graph")
local profile = require("host_agentic_testing_profile")
local t = fkst.test

local function rendered_argv(argv)
  local parts = {}
  for _, value in ipairs(argv) do
    table.insert(parts, "'" .. value .. "'")
  end
  return table.concat(parts, " ")
end

local function assert_argv(actual, expected)
  t.eq(#actual, #expected)
  for index, value in ipairs(expected) do
    t.eq(actual[index], value)
  end
end

local function argv_text(argv)
  return table.concat(argv, " ")
end

local function ready_result(module_profile)
  local readiness = profile.readiness_check(module_profile).payload
  return {
    schema = "browser-readiness.result.v1",
    status = "ready",
    sessions = {
      { role = "base_url", status = "ready" },
      { role = "default", status = "ready" },
    },
    source_ref = readiness.source_ref,
    request_context = readiness.request_context,
  }
end

local function assert_agentic_testing_profile(module_profile)
  t.eq(module_profile.module, "project_public_navigation")
  t.eq(module_profile.config_path, "config/generic-exploratory-functional.yaml")
  t.eq(module_profile.wrapper, "scripts/fkst-host-module-ui-check")
  t.eq(module_profile.base_url, "http://localhost:8080/")
  t.eq(module_profile.e2e_driver, "browser_harness")
  t.eq(argv_text(module_profile.native_argv):find("agentic_testing.cli", 1, true), nil)
  t.eq(argv_text(module_profile.native_argv):find("python3 -m agentic_testing", 1, true), nil)
  t.eq(module_profile.native_argv[1], "scripts/fkst-host-module-ui-check")
end

local function assert_readiness_request(module_profile)
  local request = profile.readiness_check(module_profile)
  t.eq(request.queue, "browser-readiness.browser_readiness_check")
  t.eq(request.payload.schema, "browser-readiness.check.v1")
  t.eq(request.payload.base_url, "http://localhost:8080/")
  t.eq(request.payload.sessions[1].role, "default")
  t.eq(request.payload.sessions[1].browser_harness_command, "true")
  t.eq(request.payload.request_context.no_browser, false)
  t.eq(request.payload.request_context.dry_run, false)
  assert_argv(request.payload.request_context.native_argv, module_profile.native_argv)
end

local function assert_module_pipeline(module_profile)
  t.mock_command(rendered_argv(module_profile.native_argv), {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })

  local readiness = ready_result(module_profile)
  local pipeline_trace = graph.require_quiescent(graph.run(profile.module_start(module_profile, readiness), { max_steps = 12 }))
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
  t.eq(result.schema, "testing-runner.result.v1")
  t.eq(result.status, "passed")
  t.eq(result.adapter.name, "fkst-native")
  t.eq(result.adapter.mode, "browser-driver")
  t.eq(result.artifact_root, ".testing/runs/sample-project-project_public_navigation")
  t.eq(result.trace_id, "trace-sample-project-project_public_navigation")
  t.eq(result.dedup_key, "sample-project-project_public_navigation")
  t.eq(result.native_summary.schema, "testing-runner.browser-driver-summary.v1")
  t.eq(result.native_summary.module, "project_public_navigation")
  t.eq(result.native_summary.driver, "browser_harness")
  t.eq(result.native_summary.readiness.status, "ready")

  local publication = graph.require_raise(pipeline_trace, "test-publication.publication_request").payload
  t.eq(publication.schema, "test-publication.publication-request.v1")
  t.eq(publication.status, "passed")
  t.eq(publication.severity, "success")
  t.eq(publication.dedup_key, result.dedup_key)
  t.eq(publication.artifact_root, result.artifact_root)
  return result
end

return {
  test_agentic_testing_generic_config_maps_to_fkst_events = function()
    local modules = profile.modules()
    t.eq(#modules, 1)
    local module_profile = modules[1]
    assert_agentic_testing_profile(module_profile)
    assert_readiness_request(module_profile)

    local start = profile.module_start(module_profile, ready_result(module_profile))
    t.eq(start.queue, "testing-pipeline.module_start")
    t.eq(start.payload.schema, "testing-pipeline.module-start.v1")
    t.eq(start.payload.module, "project_public_navigation")
    t.eq(start.payload.backend, "fkst-native")
    t.eq(start.payload.e2e_driver, "browser_harness")
    t.eq(start.payload.no_browser, false)
    t.eq(start.payload.dry_run, false)
  end,

  test_agentic_testing_host_profile_reaches_publication_handoff = function()
    local result = assert_module_pipeline(profile.modules()[1])
    t.eq(result.status, "passed")
  end,

  test_agentic_testing_host_builds_platform_aggregate_payload = function()
    local module_profile = profile.modules()[1]
    local module_result = {
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      module = module_profile.module,
      status = "passed",
      artifact_root = module_profile.artifact_root,
      source_ref = { kind = "host-module", ref = module_profile.module },
      trace_id = module_profile.trace_id,
      dedup_key = module_profile.dedup_key,
      adapter = { name = "fkst-native", mode = "browser-driver" },
      native_summary = {
        schema = "testing-runner.browser-driver-summary.v1",
        module = module_profile.module,
        driver = module_profile.e2e_driver,
        status = "passed",
        mode = "argv",
      },
    }

    local aggregate = profile.platform_aggregate({ module_result })
    t.eq(aggregate.schema, "platform-test-loop.aggregate.v1")
    t.eq(aggregate.platform, "sample-project")
    t.eq(aggregate.artifact_root, ".testing/runs/agentic-testing-host-platform")
    t.eq(aggregate.source_ref.kind, "host-platform")
    t.eq(aggregate.source_ref.ref, "sample-project")
    t.eq(aggregate.trace_id, "trace-agentic-testing-host-platform")
    t.eq(aggregate.dedup_key, "agentic-testing-host-platform")
    t.eq(#aggregate.module_results, 1)
    t.eq(aggregate.module_results[1].module, "project_public_navigation")
  end,
}
