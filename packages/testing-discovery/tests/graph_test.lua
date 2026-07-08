local graph = require("testkit.graph")
local core = require("core")
local t = fkst.test

local function app_scope_event(observations)
  return {
    queue = "app_scope",
    source_ref = { kind = "external", reference = "discovery" },
    payload = {
      schema = core.scope_schema,
      base_url = "http://localhost:8080/app?drop=yes#frag",
      allowed_origins = { "http://localhost:8080" },
      sessions = {
        { role = "base", browser_harness_command = "true" },
        { role = "cdp", cdp_url = "http://127.0.0.1:9222" },
      },
      observations = observations or {
        {
          id = "dashboard",
          name = "Dashboard",
          entry_url = "http://localhost:8080/app/dashboard?private=yes#state",
          visible_label = "Dashboard",
          discovery_source = "browser-visible",
          confidence = "high",
          evidence_pointer = ".testing/runs/discovery/evidence/dashboard",
        },
      },
      artifact_root = ".testing/runs/discovery",
      source_ref = { kind = "host-app", ref = "local-app" },
      trace_id = "trace-discovery",
      dedup_key = "dedup-discovery",
    },
  }
end

local function ready_result_event()
  return {
    queue = "browser-readiness.browser_readiness_result",
    source_ref = { kind = "external", reference = "discovery-readiness" },
    payload = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "base", status = "ready" },
        { role = "cdp", status = "ready" },
      },
      source_ref = { kind = "testing-discovery-plan", ref = ".testing/runs/discovery" },
      request_context = { dry_run = false },
    },
  }
end

local function blocked_result_event()
  local event = ready_result_event()
  event.payload.status = "blocked"
  event.payload.sessions[1].status = "blocked"
  return event
end

local function inspect_pointer_only(value)
  local kind = type(value)
  if kind == "string" then
    t.eq(value:find("private=yes", 1, true), nil)
    t.eq(value:find("drop=yes", 1, true), nil)
    t.eq(value:find("#", 1, true), nil)
    t.eq(value:find("raw_dom", 1, true), nil)
    t.eq(value:find("screenshot_body", 1, true), nil)
    t.eq(value:find("model_transcript", 1, true), nil)
    t.eq(value:find("cookie", 1, true), nil)
    t.eq(value:find("token", 1, true), nil)
    t.eq(value:find("password", 1, true), nil)
  elseif kind == "table" then
    for key, item in pairs(value) do
      inspect_pointer_only(key)
      inspect_pointer_only(item)
    end
  end
end

local function inspect_raised_payloads(trace)
  for _, step in ipairs(trace.steps or {}) do
    for _, raised in ipairs(step.raises or {}) do
      inspect_pointer_only(raised.payload)
    end
  end
end

return {
  test_app_scope_reaches_readiness_check = function()
    local trace = graph.require_quiescent(graph.run(app_scope_event(), { max_steps = 12 }))

    graph.require_delivery(trace, {
      queue = "testing-discovery.app_scope",
      consumer = "testing-discovery.start",
    })
    graph.require_delivery(trace, {
      queue = "browser-readiness.browser_readiness_check",
      consumer = "browser-readiness.check_readiness",
    })
    local readiness = graph.require_raise(trace, "browser-readiness.browser_readiness_result").payload
    t.eq(readiness.source_ref.kind, "testing-discovery-plan")
    inspect_raised_payloads(trace)
  end,

  test_ready_result_emits_module_start_and_pipeline_publication = function()
    core.write_plan(core.plan(app_scope_event().payload))

    local trace = graph.require_quiescent(graph.run(ready_result_event(), { max_steps = 14 }))

    graph.require_delivery(trace, {
      queue = "browser-readiness.browser_readiness_result",
      consumer = "testing-discovery.emit_modules",
    })
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

    local start = graph.require_raise(trace, "testing-pipeline.module_start").payload
    t.eq(start.module, "dashboard")
    t.eq(start.module_discovery.observations[1].discovery_source, "browser-visible")
    local result = graph.require_raise(trace, "testing-runner.testing_result").payload
    t.eq(result.status, "passed")
    t.eq(result.adapter.mode, "module-cdp-execution")
    local publication = graph.require_raise(trace, "test-publication.publication_request").payload
    t.eq(publication.schema, "test-publication.publication-request.v1")
    t.eq(publication.status, "passed")
    t.eq(publication.artifact_root, ".testing/runs/discovery/modules/dashboard")
    t.eq(publication.publication_dry_run, true)
    inspect_raised_payloads(trace)
  end,

  test_blocked_readiness_is_environment_session_issue_not_product_defect = function()
    core.write_plan(core.plan(app_scope_event().payload))

    local trace = graph.require_quiescent(graph.run(blocked_result_event(), { max_steps = 14 }))

    local result = graph.require_raise(trace, "testing-runner.testing_result").payload
    t.eq(result.status, "blocked")
    t.eq(result.adapter.mode, "readiness-blocked")
    t.eq(result.native_summary.outcome_classification, "environment-session-issue")
    local publication = graph.require_raise(trace, "test-publication.publication_request").payload
    t.eq(publication.severity, "warning")
    t.eq(publication.status, "blocked")
    inspect_raised_payloads(trace)
  end,

  test_empty_observations_flow_as_gap_module = function()
    core.write_plan(core.plan(app_scope_event({}).payload))

    local trace = graph.require_quiescent(graph.run(ready_result_event(), { max_steps = 14 }))
    local start = graph.require_raise(trace, "testing-pipeline.module_start").payload
    t.eq(start.module, "app-discovery")
    t.eq(#start.module_discovery.observations, 0)
    local result = graph.require_raise(trace, "testing-runner.testing_result").payload
    t.eq(result.status, "degraded")
    t.eq(result.native_summary.outcome_classification, "harness-tooling-issue")
    inspect_raised_payloads(trace)
  end,
}
