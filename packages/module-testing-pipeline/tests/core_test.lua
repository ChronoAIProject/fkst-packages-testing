local core = require("core")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"

local function testing_design_context()
  local root = ".testing/runs/module-a-design"
  local function ref(schema, name, char)
    return {
      schema = "testing-design.artifact-reference.v1",
      artifact_schema = schema,
      artifact_pointer = root .. "/" .. name,
      artifact_digest = string.rep(char, 64),
    }
  end
  return {
    schema = "testing-design.context-reference.v1",
    analysis_key = string.rep("a", 64),
    repository_analysis = ref("testing-design.repository-analysis.v1", "repository.json", "b"),
    requirements_index = ref("testing-design.requirements-index.v1", "requirements.json", "c"),
    traceability_seed = ref("testing-design.traceability-seed.v1", "traceability.json", "d"),
  }
end

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
      schema = "module-testing-pipeline.module-start.v1",
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
      schema = "module-testing-pipeline.module-start.v1",
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
    local context = testing_design_context()
    local request = core.module_loop_request({
      schema = "module-testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      dry_run = false,
      ui_loop = {
        base_url = fixture_base_url,
        allowed_origins = { fixture_origin },
      },
      cdp_execution = cdp_execution,
      testing_design_context = context,
      artifact_root = ".testing/runs/module-a-cdp",
    })
    t.eq(request.cdp_execution, cdp_execution)
    t.eq(request.testing_design_context.analysis_key, context.analysis_key)
    context.analysis_key = string.rep("e", 64)
    t.eq(request.testing_design_context.analysis_key, string.rep("a", 64))
  end,

  test_rejects_malformed_top_level_testing_design_context = function()
    local context = testing_design_context()
    context.inline_repository = "forbidden"
    t.raises(function()
      core.module_loop_request({
        schema = "module-testing-pipeline.module-start.v1",
        module = "module-a",
        testing_design_context = context,
      })
    end)
  end,

  test_saga_conformance_hook_passes = function()
    t.eq(#core.saga_conformance_errors(), 0)
  end,

  test_validation_and_saga_failure_branches_are_covered = function()
    t.raises(function() core.validate_module_start(nil) end)
    local invalid_starts = {
      {},
      { schema = "wrong", module = "module-a" },
      { schema = "module-testing-pipeline.module-start.v1" },
      {
        schema = "module-testing-pipeline.module-start.v1",
        module = "module-a",
        artifact_root = "unsafe",
      },
      {
        schema = "module-testing-pipeline.module-start.v1",
        module = "module-a",
        browser_readiness_ref = ".testing/runs/readiness.json",
      },
      {
        schema = "module-testing-pipeline.module-start.v1",
        module = "module-a",
        browser_readiness_ref = ".testing/runs/readiness.json",
        browser_readiness_sha256 = 42,
      },
      {
        schema = "module-testing-pipeline.module-start.v1",
        module = "module-a",
        browser_readiness_ref = ".testing/runs/readiness.json",
        browser_readiness_sha256 = string.rep("z", 64),
      },
    }
    for _, value in ipairs(invalid_starts) do
      t.raises(function() core.validate_module_start(value) end)
    end

    t.raises(function() core.validate_testing_result(nil) end)
    t.raises(function() core.validate_testing_result({ schema = "wrong" }) end)
    t.raises(function() core.validate_artifact_summary(nil) end)
    t.raises(function() core.validate_artifact_summary({ schema = "wrong" }) end)
    t.raises(function()
      core.validate_artifact_summary({
        schema = "test-artifacts.summary.v1",
        status = "unknown",
        artifact_root = ".testing/runs/module-a",
      })
    end)
    t.raises(function()
      core.validate_artifact_summary({
        schema = "test-artifacts.summary.v1",
        status = "passed",
        artifact_root = "unsafe",
      })
    end)

    local original = core.module_loop_request
    core.module_loop_request = function() error("forced conformance failure") end
    local failed = core.saga_conformance_errors()
    core.module_loop_request = original
    t.eq(failed[1].id, "module-testing-pipeline.saga.module-loop-request")

    core.module_loop_request = function() return {} end
    local mismatched = core.saga_conformance_errors()
    core.module_loop_request = original
    t.is_true(#mismatched > 1)
  end,
}
