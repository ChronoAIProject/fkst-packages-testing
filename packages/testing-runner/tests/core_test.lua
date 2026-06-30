local core = require("core")
local t = fkst.test

return {
  test_module_argv_uses_agentic_testing_cli = function()
    local argv = core.argv("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      module = "ornn_redemption_code",
      e2e_driver = "multi_session_browser_harness",
      agentic_testing_repo_root = "/repo/agentic-testing",
    })
    t.eq(argv[1], "python3")
    t.eq(argv[3], "agentic_testing.cli")
    t.eq(argv[8], "module-test-loop")
    t.eq(argv[10], "--dry-run-github")
    t.is_true(table.concat(argv, " "):find("ornn_redemption_code", 1, true) ~= nil)
    t.is_true(table.concat(argv, " "):find("multi_session_browser_harness", 1, true) ~= nil)
  end,

  test_module_requires_module = function()
    t.raises(function()
      core.argv("module", { schema = "testing-runner.module-test-loop.request.v1" })
    end)
  end,

  test_platform_argv_repeats_modules_and_priorities = function()
    local argv = core.argv("platform", {
      schema = "testing-runner.platform-test-loop.request.v1",
      modules = { "a", "b" },
      priority = { "P0", "P1" },
    })
    local text = table.concat(argv, " ")
    t.is_true(text:find("platform-test-loop", 1, true) ~= nil)
    t.is_true(text:find("--module a --module b", 1, true) ~= nil)
    t.is_true(text:find("--priority P0 --priority P1", 1, true) ~= nil)
  end,

  test_online_result_is_planned_by_default = function()
    local result = core.run("online_regression", {
      schema = "testing-runner.online-regression.request.v1",
      driver = "ego_browser",
    })
    t.eq(result.schema, "testing-runner.result.v1")
    t.eq(result.job, "online-regression")
    t.eq(result.status, "planned")
    t.is_true(result.artifact_root:find(".testing/runs/", 1, true) == 1)
  end,

  test_shell_quote_handles_single_quotes = function()
    t.eq(core.shell_single_quote("a'b"), "'a'\\''b'")
  end,
}
