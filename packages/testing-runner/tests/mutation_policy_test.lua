local core = require("core")
local t = fkst.test

local function safe_mutation_policy()
  return {
    schema = "testing-runner.mutation-policy.v1",
    priority = "P2",
    actions = {
      {
        action = "create_test_data",
        target = "local_test_data",
        evidence_path = ".testing/runs/module-a",
        cleanup_path = ".testing/runs/module-a",
      },
    },
  }
end

local function run_p2(extra, exec)
  local payload = {
    schema = "testing-runner.module-test-loop.request.v1",
    backend = "fkst-native",
    module = "module-a",
    priority = "P2",
    dry_run = false,
    no_browser = true,
    native_argv = { "lua", "checks/module-a.lua" },
    artifact_writer = function()
      return true
    end,
  }
  for key, value in pairs(extra or {}) do
    payload[key] = value
  end
  return core.run("module", payload, exec)
end

return {
  test_fkst_native_p2_without_mutation_policy_blocks_before_exec = function()
    local called = false
    local result = run_p2(nil, function()
      called = true
      return { exit_code = 0 }
    end)
    t.eq(result.status, "blocked")
    t.eq(result.adapter.mode, "mutation-policy-blocked")
    t.eq(result.native_summary.schema, "testing-runner.mutation-policy-summary.v1")
    t.eq(result.native_summary.classification, "NOT_EXECUTED_RISK")
    t.eq(result.native_summary.action_count, 0)
    t.eq(called, false)
  end,

  test_fkst_native_p2_destructive_mutation_blocks_before_exec = function()
    local called = false
    local result = run_p2({
      mutation_policy = {
        schema = "testing-runner.mutation-policy.v1",
        priority = "P2",
        actions = {
          {
            action = "delete",
            target = "local_test_data",
            evidence_path = ".testing/runs/module-a",
            rollback_path = ".testing/runs/module-a",
          },
        },
      },
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    t.eq(result.status, "blocked")
    t.eq(result.adapter.mode, "mutation-policy-blocked")
    t.eq(result.native_summary.classification, "NOT_EXECUTED_RISK")
    t.eq(result.native_summary.actions[1].action, "delete")
    t.eq(called, false)
  end,

  test_fkst_native_p2_external_notification_blocks_as_risk = function()
    local called = false
    local result = run_p2({
      mutation_policy = {
        schema = "testing-runner.mutation-policy.v1",
        priority = "P2",
        actions = {
          {
            action = "external_notification",
            target = "external_service",
            evidence_path = ".testing/runs/module-a",
            cleanup_path = ".testing/runs/module-a",
          },
        },
      },
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    t.eq(result.status, "blocked")
    t.eq(result.native_summary.classification, "NOT_EXECUTED_RISK")
    t.eq(result.native_summary.reason, "mutation action is not allow-listed")
    t.eq(called, false)
  end,

  test_fkst_native_p2_safe_mutation_requires_evidence_and_cleanup_pointer = function()
    local called = false
    local result = run_p2({
      mutation_policy = {
        schema = "testing-runner.mutation-policy.v1",
        priority = "P2",
        actions = {
          {
            action = "edit_test_data",
            target = "local_test_data",
            evidence_path = ".testing/runs/module-a",
          },
        },
      },
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    t.eq(result.status, "blocked")
    t.eq(result.native_summary.classification, "FIXTURE_GAP")
    t.is_true(result.native_summary.reason:find("fixture", 1, true) ~= nil)
    t.eq(called, false)
  end,

  test_fkst_native_p2_safe_mutation_runs_and_records_policy_pointers = function()
    local called = false
    local written = {}
    local result = run_p2({
      mutation_policy = safe_mutation_policy(),
      artifact_writer = function(path, body)
        written.path = path
        written.body = body
        return true
      end,
    }, function()
      called = true
      return { exit_code = 0, stderr = "" }
    end)
    t.eq(result.status, "passed")
    t.eq(result.native_summary.schema, "testing-runner.mutation-policy-summary.v1")
    t.eq(result.native_summary.classification, "SAFE_MUTATION_ALLOWED")
    t.eq(result.native_summary.actions[1].evidence_path, ".testing/runs/module-a")
    t.eq(result.native_summary.actions[1].cleanup_path, ".testing/runs/module-a")
    t.is_true(written.body:find('"schema":"testing-runner.mutation-policy-summary.v1"', 1, true) ~= nil)
    t.is_true(written.body:find('"cleanup_path":".testing/runs/module-a"', 1, true) ~= nil)
    t.eq(called, true)
  end,
}
