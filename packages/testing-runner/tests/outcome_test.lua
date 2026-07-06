local core = require("core")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"

local function discovery()
  return {
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
  }
end

local function request(overrides)
  overrides = overrides or {}
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
    module_discovery = discovery(),
    artifact_root = ".testing/runs/module-a-outcome",
    preflight_result = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "admin", status = "ready" },
      },
    },
    artifact_writer = function()
      return true
    end,
  }
  for key, item in pairs(overrides) do value[key] = item end
  if overrides.module_discovery == false then value.module_discovery = nil end
  return value
end

return {
  test_ui_loop_deferred_classifies_as_harness_tooling_and_writes_gap_backlog = function()
    local written = {}
    local result = core.run("module", request({
      module_discovery = false,
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    }))

    t.eq(result.status, "degraded")
    t.eq(result.native_summary.outcome_classification, "harness-tooling-issue")
    t.eq(result.native_summary.gap_backlog_path, ".testing/runs/module-a-outcome/gap-backlog.json")
    t.is_true(written[".testing/runs/module-a-outcome/evidence-bundle.json"]:find('"gap_backlog_path":".testing/runs/module-a-outcome/gap-backlog.json"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-outcome/gap-backlog.json"]:find('"outcome_classification":"harness-tooling-issue"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-outcome/gap-backlog.json"]:find('"blocked_modules"', 1, true) ~= nil)
    t.eq(written[".testing/runs/module-a-outcome/metadata.json"]:find("blocked_modules", 1, true), nil)
  end,

  test_missing_cdp_session_classifies_as_environment_session = function()
    local written = {}
    local cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 8,
      case_priorities = { "P0" },
    }
    local result = core.run("module", request({
      cdp_execution = cdp_execution,
      preflight_result = {
        schema = "browser-readiness.result.v1",
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready" },
        },
      },
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    }))

    t.eq(result.status, "blocked")
    t.eq(result.native_summary.classification, "missing-cdp-session")
    t.eq(result.native_summary.outcome_classification, "environment-session-issue")
    t.eq(result.native_summary.gap_backlog_path, ".testing/runs/module-a-outcome/gap-backlog.json")
    t.is_true(written[".testing/runs/module-a-outcome/gap-backlog.json"]:find('"outcome_classification":"environment-session-issue"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-outcome/gap-backlog.json"]:find("Restore local server/readiness/login/CDP session inputs", 1, true) ~= nil)
  end,

  test_missing_mutation_fixture_classifies_as_data_fixture_gap = function()
    local written = {}
    local cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 8,
      case_priorities = { "P2" },
      mutation_fixtures = {
        {
          case_id = "dashboard:write-flow",
          mutation_kind = "create-test-data",
          fixture_ref = ".testing/runs/fixtures/dashboard-create",
          evidence_pointer = ".testing/runs/evidence/dashboard-create",
        },
      },
    }
    local result = core.run("module", request({
      ui_loop = {
        base_url = fixture_base_url,
        allowed_origins = { fixture_origin },
        cdp_readiness_ref = "cdp-ready",
        mutation_policy = "host-approved",
      },
      cdp_execution = cdp_execution,
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    }))

    t.eq(result.status, "degraded")
    t.eq(result.native_summary.classification, "no-executable-safe-cases")
    t.eq(result.native_summary.outcome_classification, "data-fixture-gap")
    t.is_true(written[".testing/runs/module-a-outcome/gap-backlog.json"]:find('"outcome_classification":"data-fixture-gap"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-outcome/gap-backlog.json"]:find("cleanup or rollback", 1, true) ~= nil)
    t.eq(written[".testing/runs/module-a-outcome/metadata.json"]:find("cleanup_ref", 1, true), nil)
  end,
}
