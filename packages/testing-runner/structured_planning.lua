local contract = require("contract.structured_execution")
local browser_readiness_contract = require("contract.browser_readiness")
local environment_contract = require("contract.environment_factory")
local local_runtime = require("testing_runtime.structured_execution")

local M = {}

local copy = contract.copy

local function load_bound(ports, ref, expected_digest, label)
  local artifact = ports.load_artifact(ref)
  if type(artifact) ~= "table" or artifact.digest ~= expected_digest or type(artifact.value) ~= "table" then
    error("testing-runner: structured-planning: " .. label .. " digest mismatch")
  end
  return artifact.value
end

local function validate_local_http_cases(cases, base_url)
  local base_origin = contract.local_http_origin(base_url)
  if base_origin == nil then
    error("testing-runner: structured-planning: environment base_url must use loopback HTTP")
  end
  for _, case in ipairs(cases) do
    if case.kind == "http" then
      local origin = contract.local_http_origin(case.request.url)
      if origin == nil or origin ~= base_origin then
        error("testing-runner: structured-planning: HTTP case origin differs from ready environment")
      end
    end
  end
end

local function selected_cases(module_plan)
  if type(module_plan) ~= "table" or module_plan.schema ~= "testing-runner.module-test-plan.v1"
    or type(module_plan.modules) ~= "table" then
    error("testing-runner: structured-planning: malformed module test plan")
  end
  local selected = {}
  for _, module in ipairs(module_plan.modules) do
    if type(module) ~= "table" or type(module.cases) ~= "table" then
      error("testing-runner: structured-planning: malformed module entry")
    end
    for _, case in ipairs(module.cases) do
      if type(case) ~= "table" or type(case.id) ~= "string" then
        error("testing-runner: structured-planning: malformed designed case")
      end
      if case.review_status == "executable" then selected[case.id] = true end
    end
  end
  return selected
end

local function compile_inner(request, ports)
  contract.validate_plan_request(request)
  local module_plan = load_bound(ports, request.module_plan_ref, request.module_plan_sha256, "module plan")
  local catalog = load_bound(ports, request.case_catalog_ref, request.case_catalog_sha256, "case catalog")
  local environment = load_bound(ports, request.environment_receipt_ref, request.environment_receipt_sha256, "environment receipt")
  local readiness = load_bound(ports, request.browser_readiness_ref, request.browser_readiness_sha256, "browser readiness")
  contract.validate_catalog(catalog)
  if not contract.same_repository(catalog.repository, request.repository)
    or catalog.trace_id ~= request.trace_id or catalog.dedup_key ~= request.dedup_key then
    error("testing-runner: structured-planning: case catalog does not belong to this run")
  end
  local external_mapping
  if catalog.external_case_mapping_ref ~= nil then
    external_mapping = load_bound(ports, catalog.external_case_mapping_ref,
      catalog.external_case_mapping_sha256, "external case mapping")
    contract.validate_external_case_mapping(external_mapping)
    load_bound(ports, external_mapping.source_intake_ref,
      external_mapping.source_intake_sha256, "external case intake")
    if not contract.same_repository(external_mapping.repository, request.repository)
      or external_mapping.trace_id ~= request.trace_id
      or external_mapping.dedup_key ~= request.dedup_key then
      error("testing-runner: structured-planning: external case mapping does not belong to this run")
    end
    local catalog_by_id, catalog_by_design_id = {}, {}
    for _, case in ipairs(catalog.cases) do
      catalog_by_id[case.case_id] = case
      catalog_by_design_id[case.design_case_id] = case
    end
    for _, entry in ipairs(external_mapping.entries) do
      local mapped_case = catalog_by_design_id[entry.proposed_case_id]
      if entry.status == "mapped" then
        if mapped_case == nil or mapped_case.case_id ~= entry.catalog_case_id
          or catalog_by_id[entry.catalog_case_id] ~= mapped_case then
          error("testing-runner: structured-planning: external case mapping differs from catalog")
        end
      elseif mapped_case ~= nil then
        error("testing-runner: structured-planning: rejected external case appears in catalog")
      end
    end
  end
  environment_contract.validate_receipt(environment)
  if environment.status ~= "ready"
    or not contract.same_repository(environment.repository, request.repository)
    or type(environment.browser_readiness) ~= "table" or environment.browser_readiness.status ~= "ready"
    or environment.trace_id ~= request.trace_id or environment.dedup_key ~= request.dedup_key then
    error("testing-runner: structured-planning: environment receipt does not prove browser readiness")
  end
  local readiness_ok = pcall(browser_readiness_contract.validate_result, readiness)
  if not readiness_ok or readiness.status ~= "ready"
    or type(readiness.source_ref) ~= "table" or readiness.source_ref.kind ~= "workflow-qa"
    or readiness.source_ref.ref ~= request.source_ref.ref
    or type(readiness.correlation) ~= "table"
    or readiness.correlation.trace_id ~= request.trace_id
    or readiness.correlation.dedup_key ~= request.dedup_key then
    error("testing-runner: structured-planning: post-design browser readiness does not belong to this run")
  end

  local selected = selected_cases(module_plan)
  local cases, catalog_ids = {}, {}
  for _, case in ipairs(catalog.cases) do
    catalog_ids[case.design_case_id] = true
    if selected[case.design_case_id] then
      local executable = copy(case)
      executable.design_case_id = nil
      table.insert(cases, executable)
    end
  end
  local residual = {}
  for case_id, _ in pairs(selected) do
    if not catalog_ids[case_id] then table.insert(residual, case_id) end
  end
  table.sort(residual)
  if #cases == 0 then error("testing-runner: structured-planning: no designed case has a host-authorized execution mapping") end
  validate_local_http_cases(cases, environment.base_url)
  local browser_count = 0
  for _, case in ipairs(cases) do if case.kind == "browser" then browser_count = browser_count + 1 end end
  if browser_count > 0 and (browser_count ~= 1 or #cases ~= 1) then
    error("testing-runner: structured-planning: browser execution cannot be mixed with fixed execution")
  end

  local plan = {
    schema = contract.schemas.plan,
    execution_mode = browser_count == 1 and "agentic-browser" or "structured-api-cli",
    repository = copy(request.repository),
    environment_receipt_sha256 = request.environment_receipt_sha256,
    browser_readiness_sha256 = request.browser_readiness_sha256,
    case_catalog_sha256 = request.case_catalog_sha256,
    module_plan_sha256 = request.module_plan_sha256,
    cases = cases,
    residual_risk_case_ids = residual,
    external_case_mapping_ref = catalog.external_case_mapping_ref,
    external_case_mapping_sha256 = catalog.external_case_mapping_sha256,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  contract.validate_plan(plan)
  if ports.write_artifact(request.plan_ref, plan) ~= true then
    error("testing-runner: structured-planning: plan write failed")
  end
  local written = ports.load_artifact(request.plan_ref)
  if type(written) ~= "table" or type(written.digest) ~= "string" or written.value == nil then
    error("testing-runner: structured-planning: persisted plan digest is unavailable")
  end
  contract.validate_plan(written.value)
  return contract.validate_plan_result({
    schema = contract.schemas.plan_result,
    status = "compiled",
    plan_ref = request.plan_ref,
    plan_sha256 = written.digest,
    residual_risk_count = #residual,
    source_ref = copy(request.source_ref),
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  })
end

function M.compile(request, ports)
  local ok, result = pcall(compile_inner, request, ports)
  if ok then return result end
  local source = type(request) == "table" and request.source_ref or nil
  if type(source) ~= "table" then source = { kind = "testing-runner", ref = "structured-plan" } end
  local blocked = { schema = contract.schemas.plan_result, status = "blocked", residual_risk_count = 0,
    failure_class = tostring(result):match("structured%-planning:%s*([%w%-]+)") or "plan-compilation-failed",
    source_ref = copy(source), trace_id = type(request) == "table" and request.trace_id or "structured-plan-blocked",
    dedup_key = type(request) == "table" and request.dedup_key or "structured-plan-blocked" }
  return contract.validate_plan_result(blocked)
end

function M.production_ports()
  local ports = _G.structured_execution_runtime
  if type(ports) ~= "table" then ports = local_runtime.production() end
  for _, name in ipairs({ "load_artifact", "write_artifact" }) do
    if type(ports[name]) ~= "function" then error("testing-runner: structured-planning: missing runtime port " .. name) end
  end
  return ports
end

return M
