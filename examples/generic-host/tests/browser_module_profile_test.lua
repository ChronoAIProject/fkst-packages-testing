local graph = require("testkit.graph")
local profile = require("host_native_browser_module_profile")
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

local function assert_readiness_request(module_profile)
  local request = profile.readiness_check(module_profile)
  t.eq(request.queue, "browser-readiness.browser_readiness_check")
  t.eq(request.payload.schema, "browser-readiness.check.v1")
  t.eq(request.payload.base_url, module_profile.base_url)
  t.eq(request.payload.sessions[1].role, "default")
  t.eq(request.payload.sessions[1].browser_harness_command, "true")
  t.eq(request.payload.request_context.no_browser, false)
  t.eq(request.payload.request_context.dry_run, false)
  assert_argv(request.payload.request_context.native_argv, module_profile.native_argv)
  return request
end

local function ready_result(module_profile)
  local readiness = assert_readiness_request(module_profile).payload
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

local function assert_module(module_profile)
  t.mock_command(rendered_argv(module_profile.native_argv), {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })

  local readiness = ready_result(module_profile)
  t.eq(readiness.schema, "browser-readiness.result.v1")
  t.eq(readiness.status, "ready")
  t.eq(readiness.sessions[1].role, "base_url")
  t.eq(readiness.sessions[1].status, "ready")
  t.eq(readiness.sessions[2].role, "default")
  t.eq(readiness.sessions[2].status, "ready")
  t.eq(readiness.request_context.no_browser, false)
  t.eq(readiness.request_context.dry_run, false)
  assert_argv(readiness.request_context.native_argv, module_profile.native_argv)

  local pipeline_trace = graph.require_quiescent(graph.run(profile.module_start(module_profile, readiness), { max_steps = 12 }))
  graph.require_delivery(pipeline_trace, {
    queue = "module-testing-pipeline.module_start",
    consumer = "module-testing-pipeline.start_module",
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
  t.eq(result.adapter.mode, "browser-driver")
  t.eq(result.dedup_key, module_profile.dedup_key .. "/attempt/1")
  t.eq(result.trace_id, module_profile.trace_id)
  t.eq(result.artifact_root, module_profile.artifact_root)
  t.eq(result.native_summary.schema, "testing-runner.browser-driver-summary.v1")
  t.eq(result.native_summary.module, module_profile.module)
  t.eq(result.native_summary.driver, module_profile.e2e_driver)
  t.eq(result.native_summary.status, "passed")
  t.eq(result.native_summary.mode, "argv")
  t.eq(result.native_summary.readiness.status, "ready")
  t.eq(result.native_summary.readiness.sessions[1].role, "base_url")
  t.eq(result.native_summary.readiness.sessions[2].role, "default")

  local publication = graph.require_raise(pipeline_trace, "test-publication.publication_request").payload
  t.eq(publication.schema, "test-publication.publication-request.v1")
  t.eq(publication.status, "passed")
  t.eq(publication.severity, "success")
  t.eq(publication.dedup_key, module_profile.dedup_key .. "/attempt/1")
  t.eq(publication.artifact_root, module_profile.artifact_root)
  t.eq(publication.metadata_path, module_profile.artifact_root .. "/metadata.json")

  return result
end

return {
  test_native_browser_module_profile_reaches_publication_handoff_per_module = function()
    local results = {}
    local seen = {}
    for _, module_profile in ipairs(profile.modules) do
      local result = assert_module(module_profile)
      t.eq(seen[result.dedup_key], nil)
      seen[result.dedup_key] = true
      table.insert(results, result)
    end
    t.eq(#results, 2)
  end,

  test_native_browser_profile_builds_platform_aggregate_input = function()
    local module_results = {}
    for _, module_profile in ipairs(profile.modules) do
      table.insert(module_results, {
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
      })
    end

    local aggregate = profile.platform_aggregate(module_results)
    t.eq(aggregate.schema, "platform-test-loop.aggregate.v1")
    t.eq(aggregate.platform, "generic-host-browser-platform")
    t.eq(aggregate.artifact_root, ".testing/runs/generic-host-browser-platform")
    t.eq(aggregate.source_ref.kind, "host-platform")
    t.eq(aggregate.source_ref.ref, "generic-host-browser-platform")
    t.eq(aggregate.trace_id, "trace-generic-host-browser-platform")
    t.eq(aggregate.dedup_key, "generic-host-browser-platform")
    t.eq(#aggregate.module_results, 2)
    t.eq(aggregate.module_results[1].native_summary.driver, "generic-ai-browser-driver")
  end,
}
