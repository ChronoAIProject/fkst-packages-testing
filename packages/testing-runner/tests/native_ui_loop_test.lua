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
    t.is_true(result.stderr_excerpt:find("must not target the legacy agentic-testing host runner", 1, true) ~= nil)
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
}
