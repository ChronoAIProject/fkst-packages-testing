local core = require("core")
local t = fkst.test

return {
  test_legacy_module_argv_uses_agentic_testing_cli = function()
    local argv = core.argv("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      module = "sample_module",
      e2e_driver = "multi_session_browser_harness",
      agentic_testing_repo_root = "/repo/agentic-testing",
    })
    t.eq(argv[1], "python3")
    t.eq(argv[3], "agentic_testing.cli")
    t.eq(argv[8], "module-test-loop")
    t.eq(argv[10], "--dry-run-github")
    t.is_true(table.concat(argv, " "):find("sample_module", 1, true) ~= nil)
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

  test_online_result_is_planned_by_default_on_legacy_backend = function()
    local result = core.run("online_regression", {
      schema = "testing-runner.online-regression.request.v1",
      driver = "ego_browser",
    })
    t.eq(result.schema, "testing-runner.result.v1")
    t.eq(result.job, "online-regression")
    t.eq(result.status, "planned")
    t.eq(result.adapter.name, "agentic-testing-cli")
    t.is_true(result.adapter.command:find("agentic_testing.cli", 1, true) ~= nil)
    t.is_true(result.artifact_root:find(".testing/runs/", 1, true) == 1)
  end,

  test_fkst_native_planned_result_has_no_legacy_command = function()
    local written = {}
    local result = core.run("online_regression", {
      schema = "testing-runner.online-regression.request.v1",
      backend = "fkst-native",
      driver = "ego_browser",
      artifact_writer = function(path, body)
        written.path = path
        written.body = body
        return true
      end,
    })
    t.eq(result.status, "planned")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "planning-envelope")
    t.eq(result.adapter.command, nil)
    t.eq(written.path, result.artifact_root .. "/metadata.json")
    t.is_true(written.body:find('"schema":"testing-runner.native-metadata.v1"', 1, true) ~= nil)
    t.is_true(written.body:find('"adapter":{"mode":"planning-envelope","name":"fkst-native"}', 1, true) ~= nil)
  end,

  test_rejects_unsafe_artifact_root = function()
    t.raises(function()
      core.run("module", {
        schema = "testing-runner.module-test-loop.request.v1",
        backend = "fkst-native",
        module = "module-a",
        artifact_root = "../outside",
      })
    end)
    t.raises(function()
      core.run("module", {
        schema = "testing-runner.module-test-loop.request.v1",
        backend = "fkst-native",
        module = "module-a",
        artifact_root = ".testing/runs/../outside",
      })
    end)
  end,

  test_fkst_native_artifact_write_failure_blocks = function()
    local result = core.run("online_regression", {
      schema = "testing-runner.online-regression.request.v1",
      backend = "fkst-native",
      artifact_writer = function()
        return nil, "disk full"
      end,
    })
    t.eq(result.status, "blocked")
    t.eq(result.adapter.name, "fkst-native")
    t.is_true(result.stderr_excerpt:find("artifact write failed", 1, true) ~= nil)
  end,

  test_fkst_native_blocked_preflight_blocks_before_planning = function()
    local result = core.run("online_regression", {
      schema = "testing-runner.online-regression.request.v1",
      backend = "fkst-native",
      preflight_result = { status = "blocked" },
      artifact_writer = function()
        return true
      end,
    })
    t.eq(result.status, "blocked")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "readiness-blocked")
    t.is_true(result.stderr_excerpt:find("preflight is blocked", 1, true) ~= nil)
  end,

  test_fkst_native_ready_preflight_allows_planning = function()
    local result = core.run("online_regression", {
      schema = "testing-runner.online-regression.request.v1",
      backend = "fkst-native",
      preflight_result = { status = "ready" },
      artifact_writer = function()
        return true
      end,
    })
    t.eq(result.status, "planned")
    t.eq(result.adapter.mode, "planning-envelope")
  end,

  test_malformed_preflight_is_rejected = function()
    t.raises(function()
      core.run("online_regression", {
        schema = "testing-runner.online-regression.request.v1",
        backend = "fkst-native",
        preflight_result = {},
      })
    end)
  end,

  test_fkst_native_online_heartbeat_passes_when_url_is_ready = function()
    local called = false
    local written = {}
    local result = core.run("online_regression", {
      schema = "testing-runner.online-regression.request.v1",
      backend = "fkst-native",
      dry_run = false,
      no_browser = true,
      heartbeat_url = "http://localhost:8080/?redacted=yes#section",
      artifact_writer = function(path, body)
        written.path = path
        written.body = body
        return true
      end,
      probe = {
        http_ready = function(url)
          t.eq(url, "http://localhost:8080/?redacted=yes#section")
          return true
        end,
      },
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    t.eq(result.status, "passed")
    t.eq(result.exit_code, 0)
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "online-heartbeat")
    t.eq(result.native_summary.target, "http://localhost:8080/")
    t.eq(written.path, result.artifact_root .. "/metadata.json")
    t.is_true(written.body:find('"schema":"testing-runner.online-heartbeat-summary.v1"', 1, true) ~= nil)
    t.is_true(written.body:find('"target":"http://localhost:8080/"', 1, true) ~= nil)
    t.eq(written.body:find("redacted", 1, true), nil)
    t.eq(called, false)
  end,

  test_fkst_native_online_heartbeat_fails_when_url_is_unavailable = function()
    local result = core.run("online_regression", {
      schema = "testing-runner.online-regression.request.v1",
      backend = "fkst-native",
      dry_run = false,
      no_browser = true,
      heartbeat_url = "http://localhost:8080/",
      artifact_writer = function()
        return true
      end,
      probe = {
        http_ready = function()
          return false
        end,
      },
    })
    t.eq(result.status, "failed")
    t.eq(result.exit_code, 1)
    t.eq(result.adapter.mode, "online-heartbeat")
    t.is_true(result.stderr_excerpt:find("online heartbeat failed", 1, true) ~= nil)
  end,

  test_fkst_native_no_browser_execution_without_native_argv_plans_without_exec = function()
    local called = false
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      no_browser = true,
      agentic_testing_repo_root = "/legacy/root",
      artifact_writer = function()
        return true
      end,
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    t.eq(result.status, "planned")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "no-browser-plan")
    t.eq(called, false)
  end,

  test_fkst_native_module_no_browser_runs_native_argv = function()
    local called = false
    local written = {}
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      no_browser = true,
      native_argv = { "lua", "checks/module-a.lua" },
      preflight_result = {
        schema = "browser-readiness.result.v1",
        status = "ready",
        request_context = {
          native_argv = { "lua", "checks/module-a.lua" },
          dry_run = false,
          no_browser = true,
        },
      },
      agentic_testing_repo_root = "/legacy/root",
      artifact_writer = function(path, body)
        written.path = path
        written.body = body
        return true
      end,
    }, function(command)
      called = true
      t.eq(command, "'lua' 'checks/module-a.lua'")
      t.eq(command:find("agentic_testing.cli", 1, true), nil)
      return { exit_code = 0, stderr = "" }
    end)
    t.eq(result.status, "passed")
    t.eq(result.exit_code, 0)
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "module-no-browser")
    t.eq(result.adapter.command, nil)
    t.eq(result.native_summary.schema, "testing-runner.module-no-browser-summary.v1")
    t.eq(result.native_summary.module, "module-a")
    t.eq(written.path, result.artifact_root .. "/metadata.json")
    t.is_true(written.body:find('"schema":"testing-runner.native-metadata.v1"', 1, true) ~= nil)
    t.is_true(written.body:find('"job":"module-test-loop"', 1, true) ~= nil)
    t.is_true(written.body:find('"status":"passed"', 1, true) ~= nil)
    t.is_true(written.body:find('"artifact_root":".testing/runs/module-a"', 1, true) ~= nil)
    t.is_true(written.body:find('"adapter":{"mode":"module-no-browser","name":"fkst-native"}', 1, true) ~= nil)
    t.is_true(written.body:find('"schema":"testing-runner.module-no-browser-summary.v1"', 1, true) ~= nil)
    t.eq(called, true)
  end,

  test_fkst_native_module_no_browser_without_exec_maps_to_failed = function()
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      no_browser = true,
      native_argv = { "lua", "checks/module-a.lua" },
      artifact_writer = function()
        return true
      end,
    })
    t.eq(result.status, "failed")
    t.eq(result.exit_code, -1)
    t.is_true(result.stderr_excerpt:find("unmocked external command", 1, true) ~= nil)
    t.eq(result.adapter.mode, "module-no-browser")
  end,

  test_fkst_native_module_no_browser_maps_native_argv_failure = function()
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      no_browser = true,
      native_argv = { "lua", "checks/module-a.lua" },
      artifact_writer = function()
        return true
      end,
    }, function()
      return { exit_code = 3, stderr = "check failed" }
    end)
    t.eq(result.status, "failed")
    t.eq(result.exit_code, 3)
    t.eq(result.stderr_excerpt, "check failed")
    t.eq(result.adapter.mode, "module-no-browser")
  end,

  test_fkst_native_module_no_browser_blocks_legacy_cli_native_argv = function()
    local called = false
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      no_browser = true,
      native_argv = { "python3", "-m", "agentic_testing.cli" },
      artifact_writer = function()
        return true
      end,
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    t.eq(result.status, "blocked")
    t.eq(result.adapter.mode, "legacy-cli-blocked")
    t.is_true(result.stderr_excerpt:find("must not target agentic_testing.cli", 1, true) ~= nil)
    t.eq(called, false)
  end,

  test_malformed_native_argv_is_rejected = function()
    t.raises(function()
      core.run("module", {
        schema = "testing-runner.module-test-loop.request.v1",
        backend = "fkst-native",
        module = "module-a",
        native_argv = {},
      })
    end)
  end,

  test_fkst_native_module_browser_driver_blocks_with_envelope = function()
    local called = false
    local written = {}
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      e2e_driver = "multi_session_browser_harness",
      preflight_result = {
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
          { role = "admin", status = "ready", checks = { { name = "cdp_endpoint_env", status = "ready" } } },
        },
      },
      artifact_writer = function(path, body)
        written.path = path
        written.body = body
        return true
      end,
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    t.eq(result.status, "blocked")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.command, nil)
    t.eq(result.adapter.mode, "browser-driver-envelope")
    t.eq(result.native_summary.schema, "testing-runner.browser-driver-summary.v1")
    t.eq(result.native_summary.module, "module-a")
    t.eq(result.native_summary.driver, "multi_session_browser_harness")
    t.eq(result.native_summary.readiness.status, "ready")
    t.eq(result.native_summary.readiness.sessions[1].role, "base_url")
    t.eq(result.native_summary.readiness.sessions[2].role, "admin")
    t.eq(result.native_summary.readiness.sessions[2].status, "ready")
    t.eq(result.native_summary.readiness.sessions[2].checks, nil)
    t.eq(written.path, result.artifact_root .. "/metadata.json")
    t.is_true(written.body:find('"schema":"testing-runner.browser-driver-summary.v1"', 1, true) ~= nil)
    t.is_true(written.body:find('"readiness":{"sessions":[{"role":"base_url","status":"ready"},{"role":"admin","status":"ready"}],"status":"ready"}', 1, true) ~= nil)
    t.eq(written.body:find('"checks"', 1, true), nil)
    t.eq(called, false)
  end,

  test_fkst_native_unsupported_live_execution_blocks_without_exec = function()
    local called = false
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      artifact_writer = function()
        return true
      end,
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    t.eq(result.status, "blocked")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "capability-gap")
    t.is_true(result.stderr_excerpt:find("fkst-native live execution", 1, true) ~= nil)
    t.eq(called, false)
  end,

  test_unknown_backend_is_rejected = function()
    t.raises(function()
      core.run("online_regression", {
        schema = "testing-runner.online-regression.request.v1",
        backend = "surprise",
      })
    end)
  end,

  test_legacy_execution_maps_exit_zero_to_passed = function()
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "agentic-testing-cli",
      module = "module-a",
      dry_run = false,
    }, function(command)
      t.is_true(command:find("agentic_testing.cli", 1, true) ~= nil)
      return { exit_code = 0, stderr = "" }
    end)
    t.eq(result.status, "passed")
    t.eq(result.exit_code, 0)
    t.eq(result.adapter.name, "agentic-testing-cli")
  end,

  test_legacy_execution_maps_nonzero_to_failed = function()
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "agentic-testing-cli",
      module = "module-a",
      dry_run = false,
    }, function()
      return { exit_code = 7, stderr = "boom" }
    end)
    t.eq(result.status, "failed")
    t.eq(result.exit_code, 7)
    t.eq(result.stderr_excerpt, "boom")
  end,

  test_shell_quote_handles_single_quotes = function()
    t.eq(core.shell_single_quote("a'b"), "'a'\\''b'")
  end,
}
