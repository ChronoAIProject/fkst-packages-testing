local graph = require("testkit.graph")
local profile = require("host_native_module_profile")
local t = fkst.test

local function rendered_argv(argv)
  local parts = {}
  for _, value in ipairs(argv) do
    table.insert(parts, "'" .. value .. "'")
  end
  return table.concat(parts, " ")
end

local function assert_native_argv(actual, expected)
  t.eq(#actual, #expected)
  for index, value in ipairs(expected) do
    t.eq(actual[index], value)
  end
end

local function assert_module(module_profile)
  t.mock_command("'true'", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
  t.mock_command(rendered_argv(module_profile.native_argv), {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })

  local readiness_trace = graph.require_quiescent(graph.run(profile.readiness_check(module_profile), { max_steps = 4 }))
  graph.require_delivery(readiness_trace, {
    queue = "browser-readiness.browser_readiness_check",
    consumer = "browser-readiness.check_readiness",
  })

  local readiness = graph.require_raise(readiness_trace, "browser-readiness.browser_readiness_result").payload
  t.eq(readiness.schema, "browser-readiness.result.v1")
  t.eq(readiness.status, "ready")
  assert_native_argv(readiness.request_context.native_argv, module_profile.native_argv)
  t.eq(readiness.request_context.no_browser, true)
  t.eq(readiness.request_context.dry_run, false)

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
  t.eq(result.adapter.mode, "module-no-browser")
  t.eq(result.dedup_key, module_profile.dedup_key .. "/attempt/1")
  t.eq(result.trace_id, module_profile.trace_id)
  t.eq(result.artifact_root, module_profile.artifact_root)
  t.eq(result.native_summary.schema, "testing-runner.module-no-browser-summary.v1")
  t.eq(result.native_summary.module, module_profile.module)
  t.eq(result.native_summary.status, "passed")

  local publication = graph.require_raise(pipeline_trace, "test-publication.publication_request").payload
  t.eq(publication.schema, "test-publication.publication-request.v1")
  t.eq(publication.status, "passed")
  t.eq(publication.severity, "success")
  t.eq(publication.dedup_key, module_profile.dedup_key .. "/attempt/1")
  t.eq(publication.artifact_root, module_profile.artifact_root)
  t.eq(publication.metadata_path, module_profile.artifact_root .. "/metadata.json")

  return publication
end

return {
  test_native_module_profile_reaches_publication_handoff_per_module = function()
    local seen = {}
    local count = 0
    for _, module_profile in ipairs(profile.modules) do
      local publication = assert_module(module_profile)
      t.eq(seen[publication.dedup_key], nil)
      seen[publication.dedup_key] = true
      count = count + 1
    end
    t.eq(count, 2)
  end,
}
