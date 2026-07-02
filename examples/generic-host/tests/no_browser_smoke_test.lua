local graph = require("testkit.graph")
local profile = require("profile")
local t = fkst.test

local function host_profile(overrides)
  local value = {
    module = "module-a",
    base_url = "http://localhost:8080/",
    allowed_origins = { "http://localhost:8080" },
    sessions = {
      { role = "default", browser_harness_command = "true" },
    },
    no_browser = true,
    dry_run = false,
    native_argv = { "true" },
    artifact_root = ".testing/runs/generic-host-module-a",
    trace_id = "trace-generic-host-module-a",
    dedup_key = "generic-host-module-a",
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function has_raised_queue(trace, queue)
  for _, step in ipairs(trace.steps or {}) do
    for _, raised in ipairs(step.raises or {}) do
      if raised.queue == queue then return true end
    end
  end
  return false
end

local function payload_text(value)
  if type(value) ~= "table" then return tostring(value or "") end
  local parts = {}
  for key, item in pairs(value) do
    table.insert(parts, tostring(key) .. "=" .. payload_text(item))
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

local function run_host_profile(value)
  local readiness_trace = graph.require_quiescent(graph.run(profile.readiness_check(value), { max_steps = 4 }))
  graph.require_delivery(readiness_trace, {
    queue = "browser-readiness.browser_readiness_check",
    consumer = "browser-readiness.check_readiness",
  })
  local readiness = graph.require_raise(readiness_trace, "browser-readiness.browser_readiness_result").payload
  local pipeline_trace = graph.require_quiescent(graph.run(profile.module_start(value, readiness), { max_steps = 12 }))
  return readiness, pipeline_trace
end

local function mock_local_base_url()
  t.mock_command("curl -fsS --max-time 2 'http://localhost:8080/' >/dev/null 2>&1", {
    stdout = "",
    stderr = "",
    exit_code = 0,
  })
end

return {
  test_profile_builds_generic_readiness_and_module_start_events = function()
    local value = host_profile()
    local readiness = profile.readiness_check(value)
    t.eq(readiness.payload.schema, "browser-readiness.check.v1")
    t.eq(readiness.payload.base_url, "http://localhost:8080/")
    t.eq(readiness.payload.allowed_origins[1], "http://localhost:8080")
    t.eq(readiness.payload.request_context.native_argv[1], "true")
    t.eq(readiness.payload.request_context.no_browser, true)
    t.eq(readiness.payload.request_context.dry_run, false)

    local start = profile.module_start(value, { schema = "browser-readiness.result.v1", status = "ready" })
    t.eq(start.payload.schema, "testing-pipeline.module-start.v1")
    t.eq(start.payload.backend, "fkst-native")
    t.eq(start.payload.module, "module-a")
    t.eq(start.payload.artifact_root, ".testing/runs/generic-host-module-a")
    t.eq(start.payload.agentic_testing_repo_root, nil)
  end,

  test_no_browser_host_flow_reaches_publication_handoff = function()
    mock_local_base_url()
    t.mock_command("'true'", {
      stdout = "",
      stderr = "",
      exit_code = 0,
    })

    local readiness, pipeline_trace = run_host_profile(host_profile())
    t.eq(readiness.schema, "browser-readiness.result.v1")
    t.eq(readiness.status, "ready")
    t.eq(readiness.request_context.native_argv[1], "true")
    t.eq(readiness.request_context.no_browser, true)
    t.eq(readiness.request_context.dry_run, false)

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
    t.eq(result.adapter.command, nil)
    t.eq(result.dedup_key, "generic-host-module-a")

    local summary = graph.require_raise(pipeline_trace, "test-artifacts.artifact_summary").payload
    t.eq(summary.schema, "test-artifacts.summary.v1")
    t.eq(summary.artifact_root, ".testing/runs/generic-host-module-a")
    t.eq(summary.metadata_path, ".testing/runs/generic-host-module-a/metadata.json")

    local publication = graph.require_raise(pipeline_trace, "test-publication.publication_request").payload
    t.eq(publication.schema, "test-publication.publication-request.v1")
    t.eq(publication.status, "passed")
    t.eq(publication.severity, "success")
    t.eq(publication.dedup_key, "generic-host-module-a")
    t.eq(publication.artifact_root, ".testing/runs/generic-host-module-a")
    t.eq(publication.metadata_path, ".testing/runs/generic-host-module-a/metadata.json")

    t.eq(has_raised_queue(pipeline_trace, "github-proxy.write_request"), false)
    t.eq(has_raised_queue(pipeline_trace, "github.write_request"), false)
    t.eq(payload_text(result):find("agentic_testing.cli", 1, true), nil)
    t.eq(payload_text(publication):find("github", 1, true), nil)
  end,

  test_non_local_host_url_blocks_before_native_execution = function()
    local readiness, pipeline_trace = run_host_profile(host_profile({
      base_url = "https://example.com/",
      allowed_origins = { "http://localhost:8080" },
      artifact_root = ".testing/runs/generic-host-non-local",
      trace_id = "trace-generic-host-non-local",
      dedup_key = "generic-host-non-local",
    }))

    t.eq(readiness.status, "blocked")
    t.eq(readiness.sessions[1].role, "base_url")
    t.eq(readiness.sessions[1].status, "blocked")

    local result = graph.require_raise(pipeline_trace, "testing-runner.testing_result").payload
    t.eq(result.status, "blocked")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "readiness-blocked")
    t.eq(result.exit_code, nil)
    t.eq(payload_text(result):find("agentic_testing.cli", 1, true), nil)
  end,

  test_legacy_cli_native_argv_is_blocked = function()
    mock_local_base_url()
    local readiness, pipeline_trace = run_host_profile(host_profile({
      native_argv = { "python3", "-m", "agentic_testing.cli" },
      artifact_root = ".testing/runs/generic-host-legacy-cli",
      trace_id = "trace-generic-host-legacy-cli",
      dedup_key = "generic-host-legacy-cli",
    }))

    t.eq(readiness.status, "ready")

    local result = graph.require_raise(pipeline_trace, "testing-runner.testing_result").payload
    t.eq(result.status, "blocked")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "legacy-cli-blocked")
    t.is_true(result.stderr_excerpt:find("must not target agentic_testing.cli", 1, true) ~= nil)
  end,
}
