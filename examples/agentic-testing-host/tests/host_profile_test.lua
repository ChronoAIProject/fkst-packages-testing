local graph = require("testkit.graph")
local profile = require("host_agentic_testing_profile")
local t = fkst.test

local function assert_native_profile(module_profile)
  t.eq(module_profile.module, "project_public_navigation")
  t.eq(module_profile.base_url, "http://localhost:8080/")
  t.eq(module_profile.config_path, nil)
  t.eq(module_profile.wrapper, nil)
  t.eq(module_profile.native_argv, nil)
  t.eq(module_profile.e2e_driver, nil)
  t.eq(module_profile.allowed_origins[1], "http://localhost:8080")
  t.eq(module_profile.sessions[1].role, "base")
  t.eq(module_profile.sessions[2].role, "cdp")
  t.eq(module_profile.observations[1].id, "project_public_navigation-surface")
  t.eq(module_profile.cdp_execution.schema, "testing-runner.module-cdp-execution.v1")
end

local function assert_readiness_request(module_profile)
  local request = profile.readiness_check(module_profile)
  t.eq(request.queue, "browser-readiness.browser_readiness_check")
  t.eq(request.payload.schema, "browser-readiness.check.v1")
  t.eq(request.payload.base_url, "http://localhost:8080/")
  t.eq(request.payload.sessions[1].role, "base")
  t.eq(request.payload.sessions[1].browser_harness_command, "true")
  t.eq(request.payload.sessions[2].role, "cdp")
  t.eq(request.payload.sessions[2].cdp_url, "http://127.0.0.1:9222")
  t.eq(request.payload.request_context.no_browser, false)
  t.eq(request.payload.request_context.dry_run, false)
  t.eq(request.payload.request_context.native_argv, nil)
end

local function assert_module_pipeline(module_profile)
  local readiness = profile.ready_result(module_profile)
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
  t.eq(result.adapter.mode, "module-cdp-execution")
  t.eq(result.artifact_root, ".testing/runs/sample-project-project_public_navigation")
  t.eq(result.trace_id, "trace-sample-project-project_public_navigation")
  t.eq(result.dedup_key, "sample-project-project_public_navigation")
  t.eq(result.native_summary.schema, "testing-runner.module-cdp-execution-summary.v1")
  t.eq(result.native_summary.module, "project_public_navigation")
  t.eq(result.native_summary.status, "passed")
  t.eq(result.native_summary.execution_path, ".testing/runs/sample-project-project_public_navigation/cdp-execution.json")
  t.eq(result.native_summary.evidence_bundle_path, ".testing/runs/sample-project-project_public_navigation/evidence-bundle.json")
  t.eq(result.native_summary.stage_report_path, ".testing/runs/sample-project-project_public_navigation/stage-report.md")
  t.eq(result.native_summary.issue_drafts_path, ".testing/runs/sample-project-project_public_navigation/issue-drafts.json")
  t.eq(result.native_summary.publication_dry_run, true)

  local publication = graph.require_raise(pipeline_trace, "test-publication.publication_request").payload
  t.eq(publication.schema, "test-publication.publication-request.v1")
  t.eq(publication.status, "passed")
  t.eq(publication.severity, "success")
  t.eq(publication.dedup_key, result.dedup_key)
  t.eq(publication.artifact_root, result.artifact_root)
  t.eq(publication.stage_report_path, result.native_summary.stage_report_path)
  t.eq(publication.issue_drafts_path, result.native_summary.issue_drafts_path)
  t.eq(publication.publication_dry_run, true)
  return result
end

return {
  test_agentic_testing_host_uses_fkst_native_facts = function()
    local modules = profile.modules()
    t.eq(#modules, 1)
    local module_profile = modules[1]
    assert_native_profile(module_profile)
    assert_readiness_request(module_profile)

    local start = profile.module_start(module_profile, profile.ready_result(module_profile))
    t.eq(start.queue, "testing-pipeline.module_start")
    t.eq(start.payload.schema, "testing-pipeline.module-start.v1")
    t.eq(start.payload.module, "project_public_navigation")
    t.eq(start.payload.backend, "fkst-native")
    t.eq(start.payload.e2e_driver, nil)
    t.eq(start.payload.native_argv, nil)
    t.eq(start.payload.no_browser, nil)
    t.eq(start.payload.dry_run, false)
    t.eq(start.payload.ui_loop.base_url, "http://localhost:8080/")
    t.eq(start.payload.module_discovery.schema, "testing-runner.module-discovery.v1")
    t.eq(start.payload.cdp_execution.schema, "testing-runner.module-cdp-execution.v1")
  end,

  test_agentic_testing_host_profile_reaches_publication_handoff_without_legacy_runner = function()
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
      adapter = { name = "fkst-native", mode = "module-cdp-execution" },
      native_summary = {
        schema = "testing-runner.module-cdp-execution-summary.v1",
        module = module_profile.module,
        status = "passed",
        execution_status = "passed",
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
