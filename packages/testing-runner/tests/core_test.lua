local core = require("core")
local t = fkst.test

local function assert_payload(actual, expected)
  t.eq(type(actual), "table")
  for key, expected_value in pairs(expected) do
    if type(expected_value) == "table" then
      assert_payload(actual[key], expected_value)
    else
      t.eq(actual[key], expected_value)
    end
  end
  for key, _ in pairs(actual) do
    t.is_true(expected[key] ~= nil)
  end
end

local function module_discovery()
  return {
    schema = "testing-runner.module-discovery.v1",
    observations = {
      {
        id = "dashboard",
        name = "Dashboard",
        entry_url = "http://localhost:8080/app/dashboard?user=secret#state",
        visible_label = "Dashboard",
        discovery_source = "navigation",
        confidence = "high",
        evidence_pointer = ".testing/runs/evidence/dashboard",
      },
      {
        id = "admin",
        name = "Admin",
        entry_url = "http://localhost:8080/admin",
        visible_label = "Admin",
        discovery_source = "navigation",
        confidence = "high",
        evidence_pointer = ".testing/runs/evidence/admin",
      },
    },
    limitations = { "Routes hidden behind inactive feature flags are not included." },
  }
end

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

  test_fkst_native_blocked_preflight_payload_is_golden = function()
    local result = core.run("online_regression", {
      schema = "testing-runner.online-regression.request.v1",
      backend = "fkst-native",
      artifact_root = ".testing/runs/preflight-blocked",
      source_ref = { kind = "host", ref = "preflight-blocked" },
      trace_id = "trace-preflight-blocked",
      dedup_key = "dedup-preflight-blocked",
      preflight_result = { status = "blocked" },
      artifact_writer = function()
        return true
      end,
    })
    assert_payload(result, {
      schema = "testing-runner.result.v1",
      job = "online-regression",
      status = "blocked",
      artifact_root = ".testing/runs/preflight-blocked",
      source_ref = { kind = "host", ref = "preflight-blocked" },
      trace_id = "trace-preflight-blocked",
      dedup_key = "dedup-preflight-blocked",
      adapter = { name = "fkst-native", mode = "readiness-blocked" },
      stderr_excerpt = "fkst-native preflight is blocked",
    })
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

  test_fkst_native_module_no_browser_failure_payload_is_golden = function()
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      no_browser = true,
      native_argv = { "lua", "checks/module-a.lua" },
      artifact_root = ".testing/runs/module-a-failed",
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a",
      dedup_key = "dedup-module-a-failed",
      artifact_writer = function()
        return true
      end,
    }, function()
      return { exit_code = 3, stderr = "check failed" }
    end)
    assert_payload(result, {
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/module-a-failed",
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a",
      dedup_key = "dedup-module-a-failed",
      adapter = { name = "fkst-native", mode = "module-no-browser" },
      native_summary = {
        schema = "testing-runner.module-no-browser-summary.v1",
        module = "module-a",
        status = "failed",
        mode = "argv",
      },
      exit_code = 3,
      stderr_excerpt = "check failed",
    })
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

  test_fkst_native_legacy_cli_block_payload_and_metadata_are_golden = function()
    local called = false
    local written = {}
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      no_browser = true,
      native_argv = { "python3", "-m", "agentic_testing.cli" },
      artifact_root = ".testing/runs/module-a",
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a",
      dedup_key = "dedup-module-a",
      artifact_writer = function(path, body)
        written.path = path
        written.body = body
        return true
      end,
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    assert_payload(result, {
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "blocked",
      artifact_root = ".testing/runs/module-a",
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a",
      dedup_key = "dedup-module-a",
      adapter = { name = "fkst-native", mode = "legacy-cli-blocked" },
      stderr_excerpt = "fkst-native native_argv must not target agentic_testing.cli",
    })
    t.eq(written.path, ".testing/runs/module-a/metadata.json")
    t.eq(written.body, "{\"adapter\":{\"mode\":\"legacy-cli-blocked\",\"name\":\"fkst-native\"},\"artifact_root\":\".testing/runs/module-a\",\"dedup_key\":\"dedup-module-a\",\"job\":\"module-test-loop\",\"schema\":\"testing-runner.native-metadata.v1\",\"source_ref\":{\"kind\":\"host\",\"ref\":\"module-a\"},\"status\":\"blocked\",\"trace_id\":\"trace-module-a\"}\n")
    t.eq(called, false)
  end,

  test_fkst_native_module_ui_loop_returns_degraded_pointer_summary = function()
    local called = false
    local written = {}
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      ui_loop = {
        base_url = "http://localhost:8080/app?token=secret#frag",
        allowed_origins = { "http://localhost:8080" },
        browser_readiness_ref = ".testing/runs/readiness",
        cdp_readiness_ref = "cdp-ready",
        mutation_policy = "read-only",
        gap_ref = ".testing/runs/gap",
        backlog_ref = "backlog-item-1",
      },
      artifact_root = ".testing/runs/module-a-ui",
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a-ui",
      dedup_key = "dedup-module-a-ui",
      artifact_writer = function(path, body)
        written.path, written.body, written[path] = path, body, body
        return true
      end,
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    t.is_true(written[".testing/runs/module-a-ui/evidence-bundle.json"]:find('"planning_path":".testing/runs/module-a-ui/evidence/planning.json"', 1, true) ~= nil)
    t.is_true(written[".testing/runs/module-a-ui/evidence/failures.json"]:find('"classification":"browser-exploration-deferred"', 1, true) ~= nil)
    assert_payload(result, {
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "degraded",
      artifact_root = ".testing/runs/module-a-ui",
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a-ui",
      dedup_key = "dedup-module-a-ui",
      adapter = { name = "fkst-native", mode = "module-ui-loop-contract" },
      native_summary = {
        schema = "testing-runner.module-ui-loop-summary.v1",
        module = "module-a",
        status = "degraded",
        classification = "browser-exploration-deferred",
        mode = "contract-envelope",
        artifact_root = ".testing/runs/module-a-ui",
        metadata_path = ".testing/runs/module-a-ui/metadata.json",
        evidence_bundle_path = ".testing/runs/module-a-ui/evidence-bundle.json",
        gap_backlog_path = ".testing/runs/module-a-ui/gap-backlog.json", outcome_classification = "harness-tooling-issue", stage_report_path = ".testing/runs/module-a-ui/stage-report.md", issue_drafts_path = ".testing/runs/module-a-ui/issue-drafts.json", publication_dry_run = true,
        gap_ref = ".testing/runs/gap",
        backlog_ref = "backlog-item-1",
      },
      stderr_excerpt = "fkst-native module ui loop contract accepted; browser exploration is not implemented in this slice",
    })
    t.eq(written.path, ".testing/runs/module-a-ui/metadata.json")
    t.is_true(written.body:find('"schema":"testing-runner.module-ui-loop-summary.v1"', 1, true) ~= nil)
    t.is_true(written.body:find('"evidence_bundle_path":".testing/runs/module-a-ui/evidence-bundle.json"', 1, true) ~= nil)
    t.eq(written.body:find("secret", 1, true), nil)
    t.eq(called, false)
  end,

  test_fkst_native_module_discovery_writes_inventory_plan_and_pointer_summary = function()
    local called = false
    local written = {}
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      ui_loop = {
        base_url = "http://localhost:8080/app?token=secret#frag",
        allowed_origins = { "http://localhost:8080" },
        mutation_policy = "read-only",
      },
      module_discovery = module_discovery(),
      artifact_root = ".testing/runs/module-a-inventory",
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a-inventory",
      dedup_key = "dedup-module-a-inventory",
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
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    t.eq(result.status, "degraded")
    t.eq(result.adapter.mode, "module-ui-loop-contract")
    t.eq(result.native_summary.schema, "testing-runner.module-inventory-summary.v1")
    t.eq(result.native_summary.discovery_status, "complete")
    t.eq(result.native_summary.inventory_path, ".testing/runs/module-a-inventory/module-inventory.json")
    t.eq(result.native_summary.feature_inventory_path, ".testing/runs/module-a-inventory/feature-inventory.json")
    t.eq(result.native_summary.test_plan_path, ".testing/runs/module-a-inventory/test-plan.json")
    t.eq(result.native_summary.plan_status, "complete")
    t.eq(result.native_summary.module_count, 1)
    t.eq(result.native_summary.coverage, "visible-session-only")
    t.eq(called, false)

    local inventory = written[".testing/runs/module-a-inventory/module-inventory.json"]
    local feature_inventory = written[".testing/runs/module-a-inventory/feature-inventory.json"]
    local test_plan = written[".testing/runs/module-a-inventory/test-plan.json"]
    local metadata = written[".testing/runs/module-a-inventory/metadata.json"]
    t.is_true(inventory:find('"schema":"testing-runner.module-inventory.v1"', 1, true) ~= nil)
    t.is_true(inventory:find('"artifact_kind":"module-inventory"', 1, true) ~= nil)
    t.is_true(inventory:find('"entry_url":"http://localhost:8080/app/dashboard"', 1, true) ~= nil)
    t.is_true(inventory:find('"evidence_pointer":".testing/runs/evidence/dashboard"', 1, true) ~= nil)
    t.is_true(inventory:find('"module_count":1', 1, true) ~= nil)
    t.eq(inventory:find("secret", 1, true), nil)
    t.eq(inventory:find("/admin", 1, true), nil)
    t.is_true(inventory:find("visible to the current local session", 1, true) ~= nil)
    t.is_true(feature_inventory:find('"schema":"testing-runner.feature-inventory.v1"', 1, true) ~= nil)
    t.is_true(test_plan:find('"schema":"testing-runner.module-test-plan.v1"', 1, true) ~= nil)
    t.is_true(metadata:find('"schema":"testing-runner.module-inventory-summary.v1"', 1, true) ~= nil)
    t.is_true(metadata:find('"inventory_path":".testing/runs/module-a-inventory/module-inventory.json"', 1, true) ~= nil)
    t.is_true(metadata:find('"feature_inventory_path":".testing/runs/module-a-inventory/feature-inventory.json"', 1, true) ~= nil)
    t.is_true(metadata:find('"test_plan_path":".testing/runs/module-a-inventory/test-plan.json"', 1, true) ~= nil)
    t.eq(metadata:find('"cases"', 1, true), nil)
    t.eq(metadata:find("Dashboard", 1, true), nil)
  end,

  test_fkst_native_module_discovery_degrades_when_readiness_blocks = function()
    local written = {}
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      ui_loop = {
        base_url = "http://localhost:8080/app",
        allowed_origins = { "http://localhost:8080" },
        mutation_policy = "read-only",
      },
      module_discovery = module_discovery(),
      artifact_root = ".testing/runs/module-a-inventory-blocked",
      preflight_result = {
        schema = "browser-readiness.result.v1",
        status = "blocked",
        sessions = {
          { role = "base_url", status = "blocked" },
        },
      },
      artifact_writer = function(path, body)
        written[path] = body
        return true
      end,
    })
    t.eq(result.status, "blocked")
    t.eq(result.adapter.mode, "readiness-blocked")
    t.eq(result.native_summary.schema, "testing-runner.module-inventory-summary.v1")
    t.eq(result.native_summary.discovery_status, "degraded")
    t.eq(result.native_summary.plan_status, "degraded")
    t.eq(result.native_summary.module_count, 0)
    local inventory = written[".testing/runs/module-a-inventory-blocked/module-inventory.json"]
    local test_plan = written[".testing/runs/module-a-inventory-blocked/test-plan.json"]
    t.is_true(inventory:find('"modules":[]', 1, true) ~= nil)
    t.is_true(inventory:find('"readiness":{"sessions":[{"role":"base_url","status":"blocked"}],"status":"blocked"}', 1, true) ~= nil)
    t.is_true(test_plan:find('"plan_status":"degraded"', 1, true) ~= nil)
    t.is_true(test_plan:find('"readiness_status":"blocked"', 1, true) ~= nil)
  end,

  test_module_discovery_requires_ui_loop_scope_and_rejects_embedded_payload = function()
    t.raises(function()
      core.run("module", {
        schema = "testing-runner.module-test-loop.request.v1",
        backend = "fkst-native",
        module = "module-a",
        module_discovery = module_discovery(),
      })
    end)
    t.raises(function()
      core.run("module", {
        schema = "testing-runner.module-test-loop.request.v1",
        backend = "fkst-native",
        module = "module-a",
        ui_loop = {
          base_url = "http://localhost:8080/app",
          allowed_origins = { "http://localhost:8080" },
        },
        module_discovery = {
          schema = "testing-runner.module-discovery.v1",
          observations = {
            {
              id = "dashboard",
              entry_url = "http://localhost:8080/app/dashboard",
              visible_label = "Dashboard",
              discovery_source = "navigation",
              confidence = "high",
              evidence_pointer = ".testing/runs/evidence/dashboard",
              screenshot = "inline-browser-state",
            },
          },
        },
      })
    end)
  end,

  test_fkst_native_module_ui_loop_blocks_unsafe_runtime_input = function()
    local called = false
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      ui_loop = {
        base_url = "https://example.com/app",
        allowed_origins = { "https://example.com" },
        mutation_policy = "read-only",
      },
      artifact_root = ".testing/runs/module-a-ui-blocked",
      artifact_writer = function()
        return true
      end,
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    t.eq(result.status, "blocked")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.mode, "module-ui-loop-blocked")
    t.eq(result.native_summary.schema, "testing-runner.module-ui-loop-summary.v1")
    t.eq(result.native_summary.classification, "unsafe-runtime-input")
    t.eq(result.native_summary.status, "blocked")
    t.is_true(result.stderr_excerpt:find("blocked unsafe runtime input", 1, true) ~= nil)
    t.eq(called, false)
  end,

  test_fkst_native_module_ui_loop_blocks_legacy_cli_native_argv = function()
    local called = false
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      native_argv = { "python3", "-m", "agentic_testing.cli" },
      ui_loop = {
        base_url = "http://localhost:8080/app",
        allowed_origins = { "http://localhost:8080" },
        mutation_policy = "read-only",
      },
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

  test_module_ui_loop_rejects_embedded_non_pointer_payload = function()
    t.raises(function()
      core.run("module", {
        schema = "testing-runner.module-test-loop.request.v1",
        backend = "fkst-native",
        module = "module-a",
        dry_run = false,
        ui_loop = {
          base_url = "http://localhost:8080/app",
          allowed_origins = { "http://localhost:8080" },
          mutation_policy = "read-only",
          screenshot = "base64-inline-browser-state",
        },
      })
    end)
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

  test_fkst_native_module_browser_driver_without_native_argv_plans_with_readiness_envelope = function()
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
    t.eq(result.status, "planned")
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.command, nil)
    t.eq(result.adapter.mode, "browser-driver-plan")
    t.eq(result.native_summary.schema, "testing-runner.browser-driver-summary.v1")
    t.eq(result.native_summary.module, "module-a")
    t.eq(result.native_summary.driver, "multi_session_browser_harness")
    t.eq(result.native_summary.mode, "readiness-gated-plan")
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

  test_fkst_native_module_browser_driver_runs_native_argv = function()
    local called = false
    local written = {}
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      e2e_driver = "multi_session_browser_harness",
      native_argv = { "browser-harness", "run", "module-a" },
      preflight_result = {
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready" },
          { role = "admin", status = "ready" },
        },
      },
      artifact_writer = function(path, body)
        written.path = path
        written.body = body
        return true
      end,
    }, function(command)
      called = true
      t.eq(command, "'browser-harness' 'run' 'module-a'")
      t.eq(command:find("agentic_testing.cli", 1, true), nil)
      return { exit_code = 0, stderr = "" }
    end)
    t.eq(result.status, "passed")
    t.eq(result.exit_code, 0)
    t.eq(result.adapter.name, "fkst-native")
    t.eq(result.adapter.command, nil)
    t.eq(result.adapter.mode, "browser-driver")
    t.eq(result.native_summary.schema, "testing-runner.browser-driver-summary.v1")
    t.eq(result.native_summary.module, "module-a")
    t.eq(result.native_summary.driver, "multi_session_browser_harness")
    t.eq(result.native_summary.status, "passed")
    t.eq(result.native_summary.mode, "argv")
    t.eq(result.native_summary.readiness.status, "ready")
    t.eq(written.path, result.artifact_root .. "/metadata.json")
    t.is_true(written.body:find('"adapter":{"mode":"browser-driver","name":"fkst-native"}', 1, true) ~= nil)
    t.is_true(written.body:find('"schema":"testing-runner.browser-driver-summary.v1"', 1, true) ~= nil)
    t.eq(called, true)
  end,

  test_fkst_native_module_browser_driver_failure_payload_is_golden = function()
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      e2e_driver = "multi_session_browser_harness",
      native_argv = { "browser-harness", "run", "module-a" },
      artifact_root = ".testing/runs/module-a-browser-failed",
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a-browser",
      dedup_key = "dedup-module-a-browser-failed",
      preflight_result = {
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
          { role = "admin", status = "ready", checks = { { name = "cdp_endpoint_env", status = "ready" } } },
        },
      },
      artifact_writer = function()
        return true
      end,
    }, function()
      return { exit_code = 4, stderr = "browser check failed" }
    end)
    assert_payload(result, {
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/module-a-browser-failed",
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a-browser",
      dedup_key = "dedup-module-a-browser-failed",
      adapter = { name = "fkst-native", mode = "browser-driver" },
      native_summary = {
        schema = "testing-runner.browser-driver-summary.v1",
        module = "module-a",
        driver = "multi_session_browser_harness",
        status = "failed",
        mode = "argv",
        readiness = {
          status = "ready",
          sessions = {
            { role = "base_url", status = "ready" },
            { role = "admin", status = "ready" },
          },
        },
      },
      exit_code = 4,
      stderr_excerpt = "browser check failed",
    })
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

  test_fkst_native_unsupported_live_execution_payload_is_golden = function()
    local called = false
    local result = core.run("module", {
      schema = "testing-runner.module-test-loop.request.v1",
      backend = "fkst-native",
      module = "module-a",
      dry_run = false,
      artifact_root = ".testing/runs/module-a-live",
      source_ref = { kind = "host", ref = "module-a-live" },
      trace_id = "trace-module-a-live",
      dedup_key = "dedup-module-a-live",
      artifact_writer = function()
        return true
      end,
    }, function()
      called = true
      return { exit_code = 0 }
    end)
    assert_payload(result, {
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "blocked",
      artifact_root = ".testing/runs/module-a-live",
      source_ref = { kind = "host", ref = "module-a-live" },
      trace_id = "trace-module-a-live",
      dedup_key = "dedup-module-a-live",
      adapter = { name = "fkst-native", mode = "capability-gap" },
      stderr_excerpt = "fkst-native live execution for module is not implemented beyond the planning envelope",
    })
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
