local core = require("core")
local t = fkst.test

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function expect_failure(fragment, fn)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(fragment, 1, true) ~= nil)
end

local function request()
  return {
    schema = core.schemas.request,
    module = "module-a",
    backend = "fkst-native",
    artifact_root = ".testing/runs/module-a",
    preflight_result = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      request_context = { native_argv = { "fixture-check", "module-a" }, dry_run = false, no_browser = true },
    },
    testing_design_context = {
      schema = "testing-design.context-reference.v1",
      analysis_key = string.rep("a", 64),
    },
    source_ref = { kind = "workflow-qa", ref = "run-a" },
    trace_id = "trace-module-a",
    dedup_key = "dedup-module-a",
  }
end

local function runtime()
  local states, versions = {}, {}
  return {
    load_state = function(ref) return states[ref] end,
    save_state = function(ref, value, expected)
      if (versions[ref] or 0) ~= expected then return false end
      states[ref] = value
      versions[ref] = value.version
      return true
    end,
    list_pending_states = function()
      local refs = {}
      for ref, _ in pairs(states) do table.insert(refs, ref) end
      table.sort(refs)
      return refs
    end,
    artifact_digest = function() return string.rep("b", 64) end,
  }, states
end

local function runner_result(action, status)
  return {
    schema = "testing-runner.result.v1",
    job = "module-test-loop",
    status = status or "passed",
    artifact_root = action.payload.artifact_root,
    source_ref = action.payload.source_ref,
    trace_id = action.payload.trace_id,
    dedup_key = action.payload.dedup_key,
    adapter = { name = "fkst-native", mode = "module" },
    native_summary = {
      schema = "testing-runner.module-inventory-summary.v1",
      test_plan_path = action.payload.artifact_root .. "/test-plan.json",
    },
  }
end

return {
  test_runner_request_preserves_typed_context_and_readiness_defaults = function()
    local value = request()
    local runner = core.runner_request(value)
    t.eq(runner.schema, "testing-runner.module-test-loop.request.v1")
    t.eq(runner.native_argv[1], "fixture-check")
    t.eq(runner.dry_run, false)
    t.eq(runner.no_browser, true)
    t.eq(runner.testing_design_context.analysis_key, value.testing_design_context.analysis_key)
  end,

  test_reviewed_state_reference_survives_persistence_replay_and_attempt_request = function()
    local value = request()
    value.ai_design_loop_state_ref = {
      artifact_pointer = value.artifact_root .. "/design/ai-design-loop-state.json",
      artifact_digest = "design-state-digest",
    }
    local ports, states = runtime()
    local first = core.start(value, ports)
    local replay = core.start(value, ports)
    local state = states[value.artifact_root .. "/module-loop-state.json"]
    t.eq(state.request.ai_design_loop_state_ref, value.ai_design_loop_state_ref)
    t.eq(first[1].payload.ai_design_loop_state_ref, value.ai_design_loop_state_ref)
    t.eq(replay[1].payload.ai_design_loop_state_ref, value.ai_design_loop_state_ref)
    t.eq(first[1].payload.dedup_key, value.dedup_key .. "/attempt/1")
  end,

  test_start_persists_attempt_and_replay_returns_same_action = function()
    local ports, states = runtime()
    local first = core.start(request(), ports)
    local replay = core.start(request(), ports)
    t.eq(first[1].queue, "testing-runner.module_test_request")
    t.eq(first[1].payload.source_ref.kind, "module-test-loop-attempt")
    t.eq(first[1].payload.dedup_key, "dedup-module-a/attempt/1")
    t.eq(replay[1].payload.dedup_key, first[1].payload.dedup_key)
    t.eq(states[request().artifact_root .. "/module-loop-state.json"].attempt, 1)
  end,

  test_blocked_result_emits_stable_terminal_without_runner_owned_retry = function()
    local ports = runtime()
    local first = core.start(request(), ports)
    local terminal = core.handle_result(runner_result(first[1], "blocked"), ports)
    t.eq(terminal[1].queue, "module_loop_terminal")
    t.eq(terminal[1].payload.schema, core.schemas.terminal)
    t.eq(terminal[1].payload.attempt, 1)
    t.eq(terminal[1].payload.max_attempts, 1)
    t.eq(terminal[1].payload.source_ref.kind, "workflow-qa")
    t.eq(terminal[1].payload.module_plan_sha256, string.rep("b", 64))
    local replay = core.handle_result(runner_result(first[1], "blocked"), ports)
    t.eq(replay[1].payload.dedup_key, terminal[1].payload.dedup_key)
  end,

  test_passed_result_terminates_after_one_runner_effect = function()
    local ports = runtime()
    local first = core.start(request(), ports)
    local terminal = core.handle_result(runner_result(first[1], "passed"), ports)
    t.eq(terminal[1].queue, "module_loop_terminal")
    t.eq(terminal[1].payload.attempt, 1)
    t.eq(terminal[1].payload.status, "passed")
  end,

  test_request_state_and_result_boundaries_fail_closed = function()
    local mutations = {
      function(value) value.artifact_root = nil end,
      function(value) value.state_ref = ".testing/runs/foreign/state.json" end,
      function(value) value.max_attempts = 2 end,
      function(value) value.source_ref = nil end,
      function(value) value.dedup_key = nil end,
      function(value)
        value.browser_readiness_ref = value.artifact_root .. "/browser-readiness.json"
        value.browser_readiness_sha256 = "bad"
      end,
    }
    for _, mutate in ipairs(mutations) do
      local value = request()
      mutate(value)
      expect_failure("module-test-loop:", function() core.start(value, runtime()) end)
    end

    local ports = runtime()
    local original_save = ports.save_state
    ports.save_state = function() return false end
    expect_failure("state-save-conflict", function() core.start(request(), ports) end)
    ports.save_state = original_save

    local first = core.start(request(), ports)
    local foreign = request()
    foreign.module = "module-b"
    expect_failure("foreign-state", function() core.start(foreign, ports) end)
    expect_failure("foreign-result", function() core.handle_result({}, ports) end)

    local missing_ports = runtime()
    expect_failure("state-unavailable", function()
      core.handle_result(runner_result(first[1], "passed"), missing_ports)
    end)
    local stale = runner_result(first[1], "passed")
    stale.dedup_key = "foreign"
    expect_failure("stale-result", function() core.handle_result(stale, ports) end)
  end,

  test_redrive_validates_limits_and_replays_pending_actions = function()
    local ports = runtime()
    core.start(request(), ports)
    local actions = core.redrive({ limit = 1 }, ports)
    t.eq(actions[1].queue, "testing-runner.module_test_request")
    for _, limit in ipairs({ 0, 65, 1.5 }) do
      expect_failure("malformed-redrive", function() core.redrive({ limit = limit }, ports) end)
    end
    ports.list_pending_states = function() return "invalid" end
    expect_failure("redrive-unavailable", function() core.redrive({}, ports) end)
  end,

  test_rejects_missing_durable_identity = function()
    local value = request()
    value.source_ref = nil
    t.raises(function() core.start(value, runtime()) end)
  end,

  test_saga_conformance_hook_passes = function()
    t.eq(#core.saga_conformance_errors(), 0)
    local original = core.runner_request
    core.runner_request = function() return { schema = "other" } end
    local errors = core.saga_conformance_errors()
    core.runner_request = original
    t.eq(errors[1].id, "module-test-loop.saga.schema")
  end,
}
