local core = require("core")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"

local function request(overrides)
  local value = {
    schema = "testing-runner.module-test-loop.request.v1",
    backend = "fkst-native",
    module = "module-a",
    dry_run = false,
    ui_loop = {
      base_url = fixture_base_url,
      allowed_origins = { fixture_origin },
      cdp_readiness_ref = "cdp-ready",
      mutation_policy = "read-only",
    },
    module_discovery = {
      schema = "testing-runner.module-discovery.v1",
      observations = {
        {
          id = "dashboard",
          name = "Dashboard",
          entry_url = fixture_base_url .. "/dashboard?secret=value#state",
          visible_label = "Dashboard",
          discovery_source = "navigation",
          confidence = "high",
          evidence_pointer = ".testing/runs/evidence/dashboard",
        },
      },
    },
    cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 8,
      case_priorities = { "P0", "P1" },
    },
    preflight_result = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "admin", status = "ready" },
      },
    },
    artifact_root = ".testing/runs/module-a-cdp",
    artifact_writer = function()
      return true
    end,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

return {
  test_fkst_native_module_cdp_execution_writes_artifact_and_pointer_summary = function()
    local written = {}
    local result = core.run("module", request({
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    }))
    t.eq(result.status, "passed")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "module-cdp-execution")
    t.eq(result.native_summary.schema, "testing-runner.module-cdp-execution-summary.v1")
    t.eq(result.native_summary.execution_status, "passed")
    t.eq(result.native_summary.classification, "bounded-exploration-complete")
    t.eq(result.native_summary.execution_path, ".testing/runs/module-a-cdp/cdp-execution.json")
    t.eq(result.native_summary.metadata_path, ".testing/runs/module-a-cdp/metadata.json")
    t.eq(result.native_summary.action_count, 5)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"action":"navigate"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find('"url":"' .. fixture_base_url .. '/dashboard"', 1, true) ~= nil)
    t.eq(written[".testing/runs/module-a-cdp/cdp-execution.json"]:find("secret", 1, true), nil)
    t.is_true(written[".testing/runs/module-a-cdp/test-plan.json"]:find('"priority":"P0"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-cdp/metadata.json"]:find('"schema":"testing-runner.module-cdp-execution-summary.v1"', 1, true) ~= nil)
  end,

  test_fkst_native_module_cdp_execution_blocks_without_reused_session = function()
    local result = core.run("module", request({
      preflight_result = {
        schema = "browser-readiness.result.v1",
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready" },
        },
      },
    }))
    t.eq(result.status, "blocked")
    t.eq(result.adapter.mode, "module-cdp-execution-blocked")
    t.eq(result.native_summary.execution_status, "blocked")
    t.eq(result.native_summary.classification, "missing-cdp-session")
  end,
}
