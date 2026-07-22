local core = require("core")
local result_department = require("departments.result.main")
local seam_department = require("departments.seam.main")
local start_department = require("departments.start.main")
local testing = require("testkit.testing")
local t = fkst.test

local function ports()
  local states, versions = {}, {}
  return {
    load_state = function(ref) return states[ref] end,
    save_state = function(ref, value, expected)
      if (versions[ref] or 0) ~= expected then return false end
      states[ref] = value; versions[ref] = value.version; return true
    end,
    list_pending_states = function()
      local refs = {}
      for ref, _ in pairs(states) do table.insert(refs, ref) end
      table.sort(refs)
      return refs
    end,
    artifact_digest = function() return string.rep("a", 64) end,
  }
end

local function event(queue, payload, runtime)
  local value = { queue = queue, payload = payload }
  value["test_" .. "ports"] = runtime
  return value
end

local function request()
  return {
    schema = "module-test-loop.start.v1",
    module = "module-a",
    backend = "fkst-native",
    preflight_result = {
      schema = "browser-readiness.result.v1", status = "ready",
      request_context = { native_argv = { "fixture-check", "module-a" }, dry_run = false, no_browser = true },
    },
    artifact_root = ".testing/runs/module-a",
    source_ref = { kind = "workflow-qa", ref = "run-a" },
    trace_id = "trace-module-a",
    dedup_key = "dedup-module-a",
  }
end

return {
  test_start_and_result_departments_drive_terminal_event = function()
    local runtime = ports()
    local started = testing.run_fake(start_department,
      event("module_loop_request", request(), runtime))
    t.eq(started.raises[1].queue, "testing-runner.module_test_request")
    local runner = started.raises[1].payload
    local finished = testing.run_fake(result_department, event("testing-runner.testing_result", {
      schema = "testing-runner.result.v1", job = "module-test-loop", status = "passed",
      artifact_root = runner.artifact_root, source_ref = runner.source_ref,
      trace_id = runner.trace_id, dedup_key = runner.dedup_key,
      native_summary = { schema = "testing-runner.module-inventory-summary.v1", test_plan_path = runner.artifact_root .. "/test-plan.json" },
    }, runtime))
    t.eq(finished.raises[1].queue, "module_loop_terminal")
    t.eq(finished.raises[1].payload.source_ref.kind, "workflow-qa")
  end,

  test_start_department_rejects_malformed_input = function()
    local trace = testing.run_fake_expecting_failure(start_department,
      event("module_loop_request", { schema = "module-test-loop.start.v1" }, ports()))
    t.eq(#trace.raises, 0)
  end,

  test_seam_department_redrives_pending_runner_action = function()
    local runtime = ports()
    core.start(request(), runtime)
    local trace = testing.run_fake(seam_department,
      event("module_loop_keepalive_tick", { limit = 1 }, runtime))
    t.eq(trace.raises[1].queue, "testing-runner.module_test_request")
  end,
}
