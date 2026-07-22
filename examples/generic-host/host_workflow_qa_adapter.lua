local browser_control = require("contract.browser_control")
local environment_factory = require("contract.environment_factory")
local structured_execution = require("contract.structured_execution")
local workflow_qa = require("contract.workflow_qa")

local M = {}

local required_ports = {
  "load_artifact", "write_artifact", "artifact_digest", "claim_preauthorization",
  "grant_values", "record_terminal",
}

local function digest(value, field)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    error("generic-host: " .. field .. " must be a lowercase SHA-256 digest")
  end
  return value
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function resolve_ports(ports)
  ports = ports or _G.generic_host_workflow_qa_runtime
  for _, name in ipairs(required_ports) do
    if type(ports) ~= "table" or type(ports[name]) ~= "function" then
      error("generic-host: workflow-qa runtime port unavailable: " .. name)
    end
  end
  return ports
end

local function load_bound(ports, ref, expected_digest, label)
  local artifact = ports.load_artifact(ref)
  if type(artifact) ~= "table" or type(artifact.value) ~= "table"
    or artifact.digest ~= expected_digest then
    error("generic-host: " .. label .. " immutable binding failed")
  end
  return copy(artifact.value)
end

local function validate_grant_binding(request, grant)
  if request.execution_mode == "structured-api-cli" then
    structured_execution.validate_grant(grant)
    if grant.plan_sha256 ~= request.plan_sha256
      or grant.environment_receipt_sha256 ~= request.environment_receipt_sha256
      or grant.parent_authorization_sha256 ~= request.preauthorization_sha256 then
      error("generic-host: structured grant binding differs from request")
    end
    return grant
  end
  if request.execution_mode == "agentic-browser" then
    browser_control.validate_grant(grant)
    if grant.reviewed_plan_sha256 ~= request.plan_sha256
      or grant.environment_receipt_sha256 ~= request.environment_receipt_sha256
      or grant.parent_authorization_sha256 ~= request.preauthorization_sha256 then
      error("generic-host: browser grant binding differs from request")
    end
    return grant
  end
  error("generic-host: unsupported execution mode")
end

function M.qa_run_event(request)
  workflow_qa.validate_request(request)
  return {
    queue = "workflow-qa.qa_run_request",
    payload = request,
    source_ref = { kind = "external", reference = request.run_id },
  }
end

function M.derive_execution_grant(request, materials, values)
  structured_execution.validate_grant_request(request)
  if type(materials) ~= "table" then error("generic-host: grant materials are required") end
  if request.execution_mode == "structured-api-cli" then
    return structured_execution.derive_grant(
      materials.preauthorization,
      materials.preauthorization_sha256,
      materials.plan,
      materials.plan_sha256,
      materials.environment_receipt_sha256,
      request,
      values
    )
  end
  if request.execution_mode == "agentic-browser" then
    return browser_control.derive_grant(
      materials.preauthorization,
      materials.preauthorization_sha256,
      materials.plan,
      materials.plan_sha256,
      materials.environment_receipt_sha256,
      request,
      values
    )
  end
  error("generic-host: unsupported execution mode")
end

function M.execution_grant_result_event(request, grant_sha256)
  structured_execution.validate_grant_request(request)
  digest(grant_sha256, "grant_sha256")
  local payload = structured_execution.validate_grant_result({
    schema = structured_execution.schemas.grant_result,
    status = "granted",
    grant_ref = request.grant_ref,
    grant_sha256 = grant_sha256,
    source_ref = request.source_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  })
  return {
    queue = "workflow-qa.execution_grant_result",
    payload = payload,
    source_ref = { kind = "external", reference = request.source_ref.ref },
  }
end

function M.handle_execution_grant(request, supplied_ports)
  structured_execution.validate_grant_request(request)
  local ports = resolve_ports(supplied_ports)
  local existing = ports.load_artifact(request.grant_ref)
  if existing ~= nil then
    if type(existing) ~= "table" or type(existing.value) ~= "table" then
      error("generic-host: replayed grant artifact is malformed")
    end
    local existing_digest = digest(existing.digest, "existing grant digest")
    validate_grant_binding(request, existing.value)
    return M.execution_grant_result_event(request, existing_digest)
  end

  local materials = {
    preauthorization = load_bound(ports, request.preauthorization_ref,
      request.preauthorization_sha256, "preauthorization"),
    preauthorization_sha256 = request.preauthorization_sha256,
    plan = load_bound(ports, request.plan_ref, request.plan_sha256, "plan"),
    plan_sha256 = request.plan_sha256,
    environment_receipt_sha256 = request.environment_receipt_sha256,
  }
  load_bound(ports, request.environment_receipt_ref,
    request.environment_receipt_sha256, "environment receipt")
  local claim = ports.claim_preauthorization({
    authorization_id = materials.preauthorization.authorization_id,
    preauthorization_sha256 = request.preauthorization_sha256,
    repository = copy(request.repository),
    plan_sha256 = request.plan_sha256,
    environment_receipt_sha256 = request.environment_receipt_sha256,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  })
  if type(claim) ~= "table" or claim.status ~= "claimed"
    or type(claim.claim_id) ~= "string" or claim.claim_id == "" then
    error("generic-host: preauthorization single-use claim failed")
  end
  local grant = validate_grant_binding(request,
    M.derive_execution_grant(request, materials, ports.grant_values(copy(request), copy(materials))))
  if ports.write_artifact(request.grant_ref, copy(grant)) ~= true then
    error("generic-host: execution grant write failed")
  end
  local grant_sha256 = digest(ports.artifact_digest(request.grant_ref), "grant_sha256")
  local persisted = load_bound(ports, request.grant_ref, grant_sha256, "persisted grant")
  validate_grant_binding(request, persisted)
  return M.execution_grant_result_event(request, grant_sha256)
end

local function validate_terminal_artifacts(payload, ports)
  local receipt = load_bound(ports, payload.aggregate_publication_receipt_ref,
    payload.aggregate_publication_receipt_sha256, "aggregate publication receipt")
  if receipt.schema ~= "test-publication.qa-publication-receipt.v2"
    or receipt.status ~= "published" or receipt.stage ~= "aggregate-report" or receipt.attempt ~= 1
    or receipt.run_id ~= payload.run_id or receipt.artifact_sha256 ~= payload.aggregate_report_sha256
    or receipt.receipt_ref ~= payload.aggregate_publication_receipt_ref
    or receipt.trace_id ~= payload.trace_id or receipt.dedup_key ~= payload.dedup_key
    or type(receipt.repository) ~= "table" or receipt.repository.slug ~= payload.repository then
    error("generic-host: aggregate publication receipt binding differs from terminal handoff")
  end
  local report = load_bound(ports, payload.aggregate_report_ref,
    payload.aggregate_report_sha256, "aggregate report")
  if report.schema ~= "test-publication.qa-aggregate-report.v1" or report.run_id ~= payload.run_id
    or report.trace_id ~= payload.trace_id or report.dedup_key ~= payload.dedup_key
    or type(report.repository) ~= "table" or report.repository.slug ~= payload.repository
    or not workflow_qa.same_request(report.counts, payload.counts) then
    error("generic-host: aggregate report binding differs from terminal handoff")
  end
  local cleanup = load_bound(ports, payload.cleanup_receipt_ref,
    payload.cleanup_receipt_sha256, "cleanup receipt")
  local cleanup_ok = pcall(environment_factory.validate_cleanup_receipt, cleanup)
  if not cleanup_ok or cleanup.status ~= "complete" or cleanup.operation_id ~= payload.run_id
    or cleanup.trace_id ~= payload.trace_id or cleanup.dedup_key ~= payload.dedup_key then
    error("generic-host: cleanup receipt binding differs from terminal handoff")
  end
end

function M.handle_terminal(payload, supplied_ports)
  workflow_qa.validate_terminal(payload)
  local ports = resolve_ports(supplied_ports)
  validate_terminal_artifacts(payload, ports)
  if ports.record_terminal(copy(payload)) ~= true then
    error("generic-host: terminal handoff was not recorded")
  end
  return copy(payload)
end

return M
