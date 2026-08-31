local browser_control = require("contract.browser_control")
local environment_factory = require("contract.environment_factory")
local structured_execution = require("contract.structured_execution")
local workflow_qa = require("contract.workflow_qa")

local M = {}

local required_ports = {
  "load_artifact", "write_artifact", "artifact_digest", "claim_preauthorization",
  "grant_values", "record_terminal",
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

function M.new(options)
  options = options or {}
  local error_prefix = options.error_prefix or "workflow-qa-host"
  local default_ports = options.default_ports or function() return nil end
  if type(error_prefix) ~= "string" or error_prefix == "" then
    error("testing-runtime: workflow-qa-host-error-prefix-invalid: error_prefix must be a non-empty string")
  end
  if type(default_ports) ~= "function" then
    error("testing-runtime: workflow-qa-host-default-ports-invalid: default_ports must be a function")
  end

  local adapter = {}

  local function fail(message)
    error(error_prefix .. ": " .. message)
  end

  local function digest(value, field)
    if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
      fail(field .. " must be a lowercase SHA-256 digest")
    end
    return value
  end

  local function resolve_ports(ports)
    ports = ports or default_ports()
    for _, name in ipairs(required_ports) do
      if type(ports) ~= "table" or type(ports[name]) ~= "function" then
        fail("workflow-qa runtime port unavailable: " .. name)
      end
    end
    return ports
  end

  local function load_bound(ports, ref, expected_digest, label)
    local artifact = ports.load_artifact(ref)
    if type(artifact) ~= "table" or type(artifact.value) ~= "table"
      or artifact.digest ~= expected_digest then
      fail(label .. " immutable binding failed")
    end
    return copy(artifact.value)
  end

  local function validate_environment_binding(request, environment)
    local ok = pcall(environment_factory.validate_receipt, environment)
    if not ok or environment.status ~= "ready"
      or type(environment.repository) ~= "table"
      or environment.repository.url ~= request.repository.url
      or environment.repository.commit_sha ~= request.repository.commit_sha
      or environment.trace_id ~= request.trace_id
      or environment.dedup_key ~= request.dedup_key then
      fail("environment receipt binding differs from grant request")
    end
    return environment
  end

  local function validate_grant_binding(request, grant, environment)
    if request.execution_mode == "structured-api-cli" then
      structured_execution.validate_grant(grant)
      local base_origin = structured_execution.local_http_origin(environment.base_url)
      if base_origin == nil then fail("ready environment base_url must use loopback HTTP") end
      for _, capability in ipairs(grant.http_capabilities or {}) do
        if structured_execution.local_http_origin(capability.origin) ~= base_origin then
          fail("structured HTTP grant origin differs from ready environment")
        end
      end
      if grant.plan_sha256 ~= request.plan_sha256
        or grant.environment_receipt_sha256 ~= request.environment_receipt_sha256
        or grant.parent_authorization_sha256 ~= request.preauthorization_sha256 then
        fail("structured grant binding differs from request")
      end
      return grant
    end
    browser_control.validate_grant(grant)
    if grant.reviewed_plan_sha256 ~= request.plan_sha256
      or grant.environment_receipt_sha256 ~= request.environment_receipt_sha256
      or grant.parent_authorization_sha256 ~= request.preauthorization_sha256 then
      fail("browser grant binding differs from request")
    end
    return grant
  end

  function adapter.qa_run_event(request, supplied_ports)
    workflow_qa.validate_request(request)
    local accepted = true
    local ports = supplied_ports or default_ports()
    if type(ports) == "table" and type(ports.claim_qa_run_intake) == "function" then
      local claim = ports.claim_qa_run_intake(copy(request))
      if type(claim) ~= "table" or claim.status ~= "claimed"
        or type(claim.claim_id) ~= "string" or claim.claim_id == "" then
        fail("Local QA intake claim failed")
      end
      accepted = claim.replayed ~= true
    end
    return {
      queue = "workflow-qa.qa_run_request",
      payload = request,
      source_ref = { kind = "external", reference = request.run_id },
      accepted = accepted,
    }
  end

  function adapter.derive_execution_grant(request, materials, values)
    structured_execution.validate_grant_request(request)
    if type(materials) ~= "table" then fail("grant materials are required") end
    local environment = validate_environment_binding(request, materials.environment)
    if request.execution_mode == "structured-api-cli" then
      return validate_grant_binding(request, structured_execution.derive_grant(
        materials.preauthorization, materials.preauthorization_sha256,
        materials.plan, materials.plan_sha256, materials.environment_receipt_sha256,
        request, values
      ), environment)
    end
    return validate_grant_binding(request, browser_control.derive_grant(
      materials.preauthorization, materials.preauthorization_sha256,
      materials.plan, materials.plan_sha256, materials.environment_receipt_sha256,
      request, values
    ), environment)
  end

  function adapter.execution_grant_result_event(request, grant_sha256)
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

  function adapter.handle_execution_grant(request, supplied_ports)
    structured_execution.validate_grant_request(request)
    local ports = resolve_ports(supplied_ports)
    local environment = validate_environment_binding(request, load_bound(ports,
      request.environment_receipt_ref, request.environment_receipt_sha256, "environment receipt"))
    local existing = ports.load_artifact(request.grant_ref)
    if existing ~= nil then
      if type(existing) ~= "table" or type(existing.value) ~= "table" then
        fail("replayed grant artifact is malformed")
      end
      local existing_digest = digest(existing.digest, "existing grant digest")
      validate_grant_binding(request, existing.value, environment)
      return adapter.execution_grant_result_event(request, existing_digest)
    end

    local materials = {
      preauthorization = load_bound(ports, request.preauthorization_ref,
        request.preauthorization_sha256, "preauthorization"),
      preauthorization_sha256 = request.preauthorization_sha256,
      plan = load_bound(ports, request.plan_ref, request.plan_sha256, "plan"),
      plan_sha256 = request.plan_sha256,
      environment = environment,
      environment_receipt_sha256 = request.environment_receipt_sha256,
    }
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
      fail("preauthorization single-use claim failed")
    end
    local grant = adapter.derive_execution_grant(request, materials,
      ports.grant_values(copy(request), copy(materials)))
    if ports.write_artifact(request.grant_ref, copy(grant)) ~= true then
      fail("execution grant write failed")
    end
    local grant_sha256 = digest(ports.artifact_digest(request.grant_ref), "grant_sha256")
    local persisted = load_bound(ports, request.grant_ref, grant_sha256, "persisted grant")
    validate_grant_binding(request, persisted, environment)
    return adapter.execution_grant_result_event(request, grant_sha256)
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
      fail("aggregate publication receipt binding differs from terminal handoff")
    end
    local report = load_bound(ports, payload.aggregate_report_ref,
      payload.aggregate_report_sha256, "aggregate report")
    if report.schema ~= "test-publication.qa-aggregate-report.v1" or report.run_id ~= payload.run_id
      or report.status ~= payload.status
      or report.trace_id ~= payload.trace_id or report.dedup_key ~= payload.dedup_key
      or type(report.repository) ~= "table" or report.repository.slug ~= payload.repository
      or not workflow_qa.same_request(report.counts, payload.counts) then
      fail("aggregate report binding differs from terminal handoff")
    end
    local cleanup = load_bound(ports, payload.cleanup_receipt_ref,
      payload.cleanup_receipt_sha256, "cleanup receipt")
    local cleanup_ok = pcall(environment_factory.validate_cleanup_receipt, cleanup)
    if not cleanup_ok or cleanup.status ~= "complete" or cleanup.operation_id ~= payload.run_id
      or cleanup.trace_id ~= payload.trace_id or cleanup.dedup_key ~= payload.dedup_key then
      fail("cleanup receipt binding differs from terminal handoff")
    end
  end

  function adapter.handle_terminal(payload, supplied_ports)
    workflow_qa.validate_terminal(payload)
    local ports = resolve_ports(supplied_ports)
    validate_terminal_artifacts(payload, ports)
    if ports.record_terminal(copy(payload)) ~= true then
      fail("terminal handoff was not recorded")
    end
    return copy(payload)
  end

  return adapter
end

return M
