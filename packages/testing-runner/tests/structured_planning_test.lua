local contract = require("contract.structured_execution")
local department = require("departments.compile_structured_plan.main")
local fixtures = require("tests.structured_execution_helpers")
local planning = require("structured_planning")
local testing = require("testkit.testing")
local t = fkst.test

local function digest(char) return string.rep(char, 64) end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[copy(key)] = copy(item) end
  return result
end

local function fixture()
  local root = ".testing/runs/structured-planning"
  local repository = { url = "https://github.com/owner/repo.git", commit_sha = string.rep("a", 40) }
  local request = {
    schema = contract.schemas.plan_request,
    repository = repository,
    module_plan_ref = root .. "/module-plan.json",
    module_plan_sha256 = digest("1"),
    case_catalog_ref = root .. "/case-catalog.json",
    case_catalog_sha256 = digest("2"),
    environment_receipt_ref = root .. "/environment-receipt-ready.json",
    environment_receipt_sha256 = digest("3"),
    browser_readiness_ref = root .. "/browser-readiness.json",
    browser_readiness_sha256 = digest("8"),
    plan_ref = root .. "/execution/structured-plan.json",
    artifact_root = root .. "/execution",
    trace_id = "trace-structured-planning",
    dedup_key = "dedup-structured-planning",
    source_ref = { kind = "workflow-qa", ref = "run-1" },
  }
  local artifacts = {
    [request.module_plan_ref] = { digest = request.module_plan_sha256, value = {
      schema = "testing-runner.module-test-plan.v1",
      modules = { { id = "api", cases = {
        { id = "api:health", review_status = "executable" },
        { id = "api:unmapped", review_status = "executable" },
        { id = "api:blocked", review_status = "blocked" },
      } } },
    } },
    [request.case_catalog_ref] = { digest = request.case_catalog_sha256, value = {
      schema = contract.schemas.case_catalog,
      repository = repository,
      cases = { {
        design_case_id = "api:health",
        case_id = "api-health",
        kind = "http",
        request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} },
        timeout_seconds = 10,
        assertions = { { type = "status-code", expected = 200 } },
      } },
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    } },
    [request.environment_receipt_ref] = {
      digest = request.environment_receipt_sha256,
      value = fixtures.receipt(request),
    },
    [request.browser_readiness_ref] = {
      digest = request.browser_readiness_sha256,
      value = fixtures.readiness(request),
    },
  }
  local ports = {
    load_artifact = function(ref) return artifacts[ref] end,
    write_artifact = function(ref, value)
      artifacts[ref] = { digest = digest("4"), value = value }
      return true
    end,
  }
  return request, artifacts, ports
end

return {
  test_compiles_only_host_catalog_cases_selected_by_design = function()
    local request, artifacts, ports = fixture()
    local result = planning.compile(request, ports)
    t.eq(result.status, "compiled")
    t.eq(result.plan_ref, request.plan_ref)
    t.eq(result.residual_risk_count, 1)
    local plan = artifacts[request.plan_ref].value
    t.eq(plan.schema, contract.schemas.plan)
    t.eq(plan.browser_readiness_sha256, request.browser_readiness_sha256)
    t.eq(#plan.cases, 1)
    t.eq(plan.cases[1].case_id, "api-health")
    t.eq(plan.residual_risk_case_ids[1], "api:unmapped")
  end,

  test_rejects_shell_catalog_capability = function()
    local request, artifacts, ports = fixture()
    artifacts[request.case_catalog_ref].value.cases[1] = {
      design_case_id = "api:health", case_id = "api-health", kind = "cli",
      argv = { "env", "TOKEN=value", "BASH", "-c", "true" }, timeout_seconds = 10,
      assertions = { { type = "exit-code", expected = 0 } },
    }
    local result = planning.compile(request, ports)
    t.eq(result.status, "blocked")
    t.eq(artifacts[request.plan_ref], nil)
  end,

  test_rejects_environment_without_browser_gate = function()
    local request, artifacts, ports = fixture()
    artifacts[request.environment_receipt_ref].value.browser_readiness.status = "blocked"
    local result = planning.compile(request, ports)
    t.eq(result.status, "blocked")
  end,

  test_fail_closed_compilation_boundaries = function()
    local mutations = {
      function(request, artifacts) artifacts[request.module_plan_ref].digest = "bad" end,
      function(request, artifacts) artifacts[request.module_plan_ref].value.schema = "foreign" end,
      function(request, artifacts) artifacts[request.module_plan_ref].value.modules[1].cases = nil end,
      function(request, artifacts) artifacts[request.module_plan_ref].value.modules[1].cases[1].id = nil end,
      function(request, artifacts) artifacts[request.case_catalog_ref].value.trace_id = "foreign" end,
      function(request, artifacts)
        local duplicate = copy(artifacts[request.case_catalog_ref].value.cases[1])
        duplicate.case_id = "duplicate-case"
        artifacts[request.case_catalog_ref].value.cases[2] = duplicate
      end,
      function(request, artifacts)
        artifacts[request.environment_receipt_ref].value.repository.url = "https://github.com/other/repo.git"
        artifacts[request.environment_receipt_ref].value.repository.commit_sha = string.rep("9", 40)
      end,
      function(request, artifacts) artifacts[request.environment_receipt_ref].value.workspace_ref = nil end,
      function(request, artifacts)
        local environment = artifacts[request.environment_receipt_ref].value
        environment.base_url = "https://127.0.0.1:4173/health"
        environment.browser_readiness.correlation.base_url = environment.base_url
      end,
      function(request, artifacts)
        artifacts[request.case_catalog_ref].value.cases[1].request.url = "http://127.0.0.1:43110/health"
      end,
      function(request, artifacts) artifacts[request.browser_readiness_ref].value.source_ref.ref = "foreign" end,
    }
    for _, mutate in ipairs(mutations) do
      local request, artifacts, ports = fixture()
      mutate(request, artifacts)
      t.eq(planning.compile(request, ports).status, "blocked")
    end

    do
      local request, artifacts, ports = fixture()
      artifacts[request.module_plan_ref].value.modules[1].cases[2].id = "api:browser"
      artifacts[request.case_catalog_ref].value.cases[2] = {
        design_case_id = "api:browser", case_id = "api-browser", kind = "browser",
        goal = "Verify browser login", success_conditions = { "authenticated" },
        completion_assertions = {
          { assertion_id = "callback-observed", type = "browser-callback-observed", required = true, completion_field = "callback_observed" },
          { assertion_id = "process-exit-zero", type = "browser-process-exit-zero", required = true, completion_field = "process_exit_zero" },
          { assertion_id = "whoami-succeeded", type = "browser-whoami-succeeded", required = true, completion_field = "whoami_succeeded" },
          { assertion_id = "status-authenticated", type = "browser-status-authenticated", required = true, completion_field = "status_authenticated" },
        },
      }
      t.eq(planning.compile(request, ports).status, "blocked")
    end
    do
      local request, _, ports = fixture()
      ports.write_artifact = function() return false end
      t.eq(planning.compile(request, ports).status, "blocked")
    end
    do
      local request, artifacts, ports = fixture()
      ports.write_artifact = function(ref, value)
        artifacts[ref] = { value = copy(value) }
        return true
      end
      t.eq(planning.compile(request, ports).status, "blocked")
    end
    t.eq(planning.compile(nil, {}).status, "blocked")
  end,

  test_production_ports_fail_closed_and_return_complete_runtime = function()
    local previous = _G.structured_execution_runtime
    _G.structured_execution_runtime = nil
    local defaults = planning.production_ports()
    t.is_true(type(defaults.load_artifact) == "function")
    t.is_true(type(defaults.write_artifact) == "function")
    _G.structured_execution_runtime = { load_artifact = function() end }
    t.raises(function() planning.production_ports() end)
    local runtime = { load_artifact = function() end, write_artifact = function() end }
    _G.structured_execution_runtime = runtime
    t.eq(planning.production_ports(), runtime)
    _G.structured_execution_runtime = previous
  end,

  test_department_raises_compiled_plan_result = function()
    local request, _, ports = fixture()
    local trace = testing.run_fake(department, {
      queue = "structured_plan_request", payload = request, test_ports = ports,
    })
    t.eq(department.spec.consumes[1], "structured_plan_request")
    t.eq(department.spec.produces[1], "structured_plan_result")
    t.eq(trace.raises[1].queue, "structured_plan_result")
    t.eq(trace.raises[1].payload.status, "compiled")
  end,
}
