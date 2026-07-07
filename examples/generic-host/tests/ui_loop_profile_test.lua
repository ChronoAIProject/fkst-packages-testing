local graph = require("testkit.graph")
local profile = require("host_native_ui_loop_profile")
local t = fkst.test

local function read_file(path)
  local file = assert(io.open(path, "r"))
  local body = file:read("*a")
  file:close()
  return body
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function assert_no_legacy_cli(trace)
  for _, step in ipairs(trace.steps or {}) do
    t.eq(tostring(step.queue or ""):find("agentic_testing.cli", 1, true), nil)
    t.eq(tostring(step.consumer or ""):find("agentic_testing.cli", 1, true), nil)
    for _, raised in ipairs(step.raises or {}) do
      local payload = raised.payload or {}
      local adapter = payload.adapter or {}
      t.eq(tostring(adapter.command or ""):find("agentic_testing.cli", 1, true), nil)
      t.eq(tostring(payload.stderr_excerpt or ""):find("agentic_testing.cli", 1, true), nil)
    end
  end
end

return {
  test_native_ui_loop_profile_reaches_dry_run_publication_handoff = function()
    local module_profile = profile.modules[1]
    local request = profile.readiness_check(module_profile)
    t.eq(request.payload.base_url, "http://localhost:4173/catalog")
    t.eq(request.payload.request_context.no_browser, false)
    t.eq(request.payload.request_context.dry_run, false)
    t.eq(request.payload.request_context.native_argv, nil)

    local readiness = profile.ready_result(module_profile)
    local trace = graph.require_quiescent(graph.run(profile.module_start(module_profile, readiness), { max_steps = 12 }))

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
    assert_no_legacy_cli(trace)

    local result = graph.require_raise(trace, "testing-runner.testing_result").payload
    t.eq(result.status, "passed")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "module-cdp-execution")
    t.eq(result.artifact_root, module_profile.artifact_root)
    t.eq(result.native_summary.schema, "testing-runner.module-cdp-execution-summary.v1")
    t.eq(result.native_summary.execution_path, module_profile.artifact_root .. "/cdp-execution.json")
    t.eq(result.native_summary.stage_report_path, module_profile.artifact_root .. "/stage-report.md")
    t.eq(result.native_summary.issue_drafts_path, module_profile.artifact_root .. "/issue-drafts.json")
    t.eq(result.native_summary.publication_dry_run, true)

    local summary = graph.require_raise(trace, "test-artifacts.artifact_summary").payload
    t.eq(summary.status, "passed")
    t.eq(summary.native_summary.stage_report_path, module_profile.artifact_root .. "/stage-report.md")
    t.eq(summary.native_summary.issue_drafts_path, module_profile.artifact_root .. "/issue-drafts.json")
    t.eq(summary.native_summary.publication_dry_run, true)

    local report = read_file(module_profile.artifact_root .. "/stage-report.md")
    t.is_true(report:find("Discovered modules", 1, true) ~= nil)
    t.is_true(report:find("Coverage status", 1, true) ~= nil)
    t.is_true(report:find("Executed user-facing scenarios", 1, true) ~= nil)
    t.is_true(report:find("Publication handoff: dry-run pointer handoff only", 1, true) ~= nil)
    t.eq(report:find("token=", 1, true), nil)
    t.eq(report:find("#state", 1, true), nil)

    local drafts = read_file(module_profile.artifact_root .. "/issue-drafts.json")
    t.is_true(drafts:find('"publication_dry_run":true', 1, true) ~= nil)
    t.is_true(drafts:find('"external_write":false', 1, true) ~= nil)

    local publication = graph.require_raise(trace, "test-publication.publication_request").payload
    t.eq(publication.schema, "test-publication.publication-request.v1")
    t.eq(publication.status, "passed")
    t.eq(publication.severity, "success")
    t.eq(publication.artifact_root, module_profile.artifact_root)
    t.eq(publication.stage_report_path, module_profile.artifact_root .. "/stage-report.md")
    t.eq(publication.issue_drafts_path, module_profile.artifact_root .. "/issue-drafts.json")
    t.eq(publication.publication_dry_run, true)
    t.eq(publication.issue_body, nil)
    t.eq(publication.github_comment, nil)
    t.eq(publication.github_issue, nil)
  end,

  test_native_ui_loop_profile_blocks_non_local_base_url = function()
    local module_profile = copy(profile.modules[1])
    module_profile.base_url = "https://example.com/catalog"
    module_profile.allowed_origins = { "https://example.com" }
    local ok, err = pcall(profile.validate, module_profile)
    t.eq(ok, false)
    t.is_true(tostring(err):find("base_url must be a local http URL", 1, true) ~= nil)
  end,

  test_native_ui_loop_profile_rejects_legacy_cli_argv_and_product_names = function()
    local module_profile = profile.modules[1]
    t.eq(module_profile.module:find("ornn", 1, true), nil)
    t.eq(module_profile.base_url:find("ornn", 1, true), nil)

    local event = profile.module_start(module_profile, profile.ready_result(module_profile))
    event.payload.native_argv = { "python3", "-m", "agentic_testing.cli" }
    local trace = graph.require_quiescent(graph.run(event, { max_steps = 12 }))
    local result = graph.require_raise(trace, "testing-runner.testing_result").payload
    t.eq(result.status, "blocked")
    t.eq(result.adapter.mode, "legacy-cli-blocked")
  end,

}
