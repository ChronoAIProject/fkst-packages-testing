local core = require("core")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"

return {
  test_module_ui_loop_flows_to_module_loop_request = function()
    local ui_loop = {
      base_url = fixture_base_url,
      allowed_origins = { fixture_origin },
      browser_readiness_ref = ".testing/runs/readiness",
      cdp_readiness_ref = "cdp-ready",
      mutation_policy = "read-only",
      gap_ref = ".testing/runs/gap",
      backlog_ref = "backlog-item-1",
    }
    local request = core.module_loop_request({
      schema = "testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      dry_run = false,
      ui_loop = ui_loop,
      artifact_root = ".testing/runs/module-a-ui",
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a-ui",
      dedup_key = "module-a-ui-run",
    })
    t.eq(request.schema, "module-test-loop.start.v1")
    t.eq(request.module, "module-a")
    t.eq(request.backend, "fkst-native")
    t.eq(request.dry_run, false)
    t.eq(request.ui_loop, ui_loop)
    t.eq(request.artifact_root, ".testing/runs/module-a-ui")
    t.eq(request.trace_id, "trace-module-a-ui")
    t.eq(request.dedup_key, "module-a-ui-run")
  end,

  test_module_discovery_flows_to_module_loop_request = function()
    local module_discovery = {
      schema = "testing-runner.module-discovery.v1",
      observations = {
        {
          id = "dashboard",
          entry_url = fixture_base_url .. "/dashboard",
          visible_label = "Dashboard",
          discovery_source = "navigation",
          evidence_pointer = ".testing/runs/evidence/dashboard",
        },
      },
    }
    local request = core.module_loop_request({
      schema = "testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      dry_run = false,
      ui_loop = {
        base_url = fixture_base_url,
        allowed_origins = { fixture_origin },
      },
      module_discovery = module_discovery,
      artifact_root = ".testing/runs/module-a-inventory",
    })
    t.eq(request.module_discovery, module_discovery)
  end,

  test_cdp_execution_flows_to_module_loop_request = function()
    local cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 4,
      case_priorities = { "P0", "P1" },
    }
    local request = core.module_loop_request({
      schema = "testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      dry_run = false,
      ui_loop = {
        base_url = fixture_base_url,
        allowed_origins = { fixture_origin },
      },
      cdp_execution = cdp_execution,
      artifact_root = ".testing/runs/module-a-cdp",
    })
    t.eq(request.cdp_execution, cdp_execution)
  end,

  test_saga_conformance_hook_passes = function()
    t.eq(#core.saga_conformance_errors(), 0)
  end,
}
