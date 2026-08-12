local contract = require("contract.workflow_qa")
local checkpoints = require("checkpoints")
local browser_contract = require("contract.browser_control")
local browser_readiness_contract = require("contract.browser_readiness")
local environment_contract = require("contract.environment_factory")
local design_contract = require("contract.testing_design")
local project_profile = require("contract.project_profile")
local execution_contract = require("contract.structured_execution")
local ports_module = require("ports")
local design_loop = require("testing_ai.module_ai_design_loop")

local M = {}

local function copy(value)
  if value == nil then return nil end
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function action(queue, payload)
  return { queue = queue, payload = payload }
end

local function digest(ports, pointer)
  local value = ports.artifact_digest(pointer)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    error("workflow-qa: artifact-digest-unavailable: " .. tostring(pointer))
  end
  return value
end

local function load_bound(ports, pointer, expected_digest, label)
  local artifact = ports.load_artifact(pointer)
  if type(artifact) ~= "table" or artifact.digest ~= expected_digest or type(artifact.value) ~= "table" then
    error("workflow-qa: artifact-binding-unavailable: " .. label .. " immutable binding failed")
  end
  return artifact.value
end

local function validate_authorization_chain(request, ports)
  local execution = request.structured_execution
  local preauthorization = load_bound(ports, execution.preauthorization_ref,
    execution.preauthorization_sha256, "preauthorization")
  local catalog = load_bound(ports, execution.case_catalog_ref,
    execution.case_catalog_sha256, "case-catalog")
  execution_contract.validate_preauthorization(preauthorization)
  execution_contract.validate_catalog(catalog)
  local receipt_artifact = ports.load_artifact(request.environment_start.validation_receipt_ref.ref)
  local receipt = type(receipt_artifact) == "table" and receipt_artifact.value or nil
  if type(receipt) ~= "table" then
    error("workflow-qa: validation-receipt-unavailable: profile validation receipt is missing")
  end
  project_profile.validate_validation_receipt(receipt)
  local profile_pointer = request.environment_start.profile_ref.ref
  local profile_sha256 = digest(ports, profile_pointer)
  local profile = load_bound(ports, profile_pointer, profile_sha256, "project-profile")
  project_profile.validate_profile(profile)
  if not execution_contract.same_repository(preauthorization.repository, request.repository)
    or not execution_contract.same_repository(catalog.repository, request.repository)
    or not execution_contract.same_repository(receipt.repository, request.repository)
    or preauthorization.profile_sha256 ~= receipt.profile_sha256
    or receipt.profile_revision ~= profile.revision
    or not execution_contract.same_repository(profile.repository, request.repository)
    or preauthorization.case_catalog_sha256 ~= execution.case_catalog_sha256
    or preauthorization.trace_id ~= request.trace_id or preauthorization.dedup_key ~= request.dedup_key
    or catalog.trace_id ~= request.trace_id or catalog.dedup_key ~= request.dedup_key
    or receipt.trace_id ~= request.trace_id or receipt.dedup_key ~= request.dedup_key
    or receipt.approval_ref.kind ~= request.environment_start.approval_ref.kind
    or receipt.approval_ref.ref ~= request.environment_start.approval_ref.ref then
    error("workflow-qa: authorization-binding-mismatch: profile, catalog, repository, or run identity differs")
  end
  return {
    profile_ref = profile_pointer,
    profile_artifact_sha256 = profile_sha256,
    profile_sha256 = receipt.profile_sha256,
    validation_receipt_ref = request.environment_start.validation_receipt_ref.ref,
    validation_receipt_sha256 = receipt_artifact.digest,
    preauthorization_ref = execution.preauthorization_ref,
    preauthorization_sha256 = execution.preauthorization_sha256,
    case_catalog_sha256 = execution.case_catalog_sha256,
  }
end

local function save(ports, state)
  local expected = state.version
  state.version = expected + 1
  if ports.save_state(state.state_ref, copy(state), expected) ~= true then
    error("workflow-qa: state-save-conflict: durable compare-and-swap failed")
  end
end

local function gate_checkpoint(state, stage, status, artifact_ref, counts, next_phase, next_actions, ports)
  local actions = checkpoints.gate(state, stage, status, artifact_ref, counts, next_phase, next_actions)
  save(ports, state)
  return actions
end

local function set_pending(state, phase, actions)
  state.phase = phase
  state.pending_actions = actions
end

local function seed_document(request)
  local cases = {}
  for _, proposed in ipairs(request.proposed_cases) do
    local item = copy(proposed)
    item.provenance = { origin = "user-seed", source_pointer = request.artifact_root .. "/intake.json" }
    table.insert(cases, item)
  end
  return design_loop.validate_seed_cases({ schema = design_loop.schemas.seed_cases, cases = cases })
end

local function load_for(request, ports)
  local state = ports.load_state(request.state_ref)
  if state == nil then return nil end
  if type(state) ~= "table" or state.schema ~= contract.schemas.state
    or not contract.same_request(state.request, request) then
    error("workflow-qa: foreign-state: saved request binding differs")
  end
  return state
end

local function resolve_request(payload, request, ports)
  if request ~= nil then return contract.validate_request(request) end
  local source = type(payload) == "table" and payload.source_ref or nil
  local recovered
  if type(source) == "table" and source.kind == "workflow-qa" then
    recovered = ports.load_run_by_id(source.ref)
  else
    recovered = ports.load_run(payload.trace_id, payload.dedup_key)
  end
  if type(recovered) ~= "table" then error("workflow-qa: run-identity-unavailable: durable run lookup failed") end
  return contract.validate_request(recovered)
end

local function exact_identity(state, payload)
  if payload.trace_id ~= state.request.trace_id or payload.dedup_key ~= state.request.dedup_key then
    error("workflow-qa: foreign-result: trace or dedup identity differs")
  end
end

local function source_identity(state, payload, kind, expected_dedup_key)
  if payload.trace_id ~= state.request.trace_id or type(payload.source_ref) ~= "table"
    or payload.dedup_key ~= expected_dedup_key
    or payload.source_ref.kind ~= kind or payload.source_ref.ref ~= state.request.run_id then
    error("workflow-qa: foreign-result: source or trace identity differs")
  end
end

local function runner_from_module_terminal(payload)
  if type(payload) ~= "table" then return nil end
  return payload.runner_result
end

local function browser_readiness_request(state)
  local receipt = state.environment_receipt
  local module_start = state.request.design_module_start
  local context = {
    dry_run = module_start.dry_run == true,
    no_browser = module_start.no_browser == true,
  }
  if module_start.native_argv ~= nil then context.native_argv = copy(module_start.native_argv) end
  return browser_readiness_contract.validate_request({
    schema = browser_readiness_contract.schemas.request,
    base_url = receipt.base_url,
    sessions = copy(receipt.sessions),
    request_context = context,
    source_ref = { kind = "workflow-qa", ref = state.request.run_id },
    correlation = copy(receipt.browser_readiness.correlation),
  })
end

local function terminal_summary(state, ports, status)
  local ref = state.request.publication.terminal_summary_ref
  local value = {
    schema = "workflow-qa.terminal-summary.v2",
    status = status,
    repository = copy(state.request.repository),
    run_id = state.request.run_id,
    phase = state.phase,
    counts = copy(state.counts or {
      planned = 0, executed = 0, passed = 0, failed = 0,
      skipped = 0, error = 0, blocked = 1,
    }),
    environment_receipt_ref = state.environment_receipt_ref,
    cleanup_receipt_ref = state.cleanup_result and state.cleanup_result.cleanup_receipt_ref
      and state.cleanup_result.cleanup_receipt_ref.ref or nil,
    browser_readiness_ref = state.artifacts.browser_readiness_ref,
    browser_readiness_sha256 = state.artifacts.browser_readiness_ref
      and state.digests[state.artifacts.browser_readiness_ref] or nil,
    module_plan_ref = state.artifacts.module_plan_ref,
    structured_plan_ref = state.artifacts.structured_plan_ref,
    case_results_ref = state.artifacts.case_results_ref,
    interruption = state.interruption_requested,
    trace_id = state.request.trace_id,
    dedup_key = state.request.dedup_key,
  }
  if ports.write_artifact(ref, value) ~= true then
    error("workflow-qa: terminal-summary-write-failed: bounded terminal summary was not persisted")
  end
  state.digests[ref] = digest(ports, ref)
  state.artifacts.terminal_summary_ref = ref
  state.terminal_status = status
  return ref
end

function M.start(request, supplied_ports)
  request = contract.validate_request(request)
  local ports = ports_module.resolve(supplied_ports)
  local authorization = validate_authorization_chain(request, ports)
  local existing = load_for(request, ports)
  if existing ~= nil then
    if not contract.same_request(existing.authorization, authorization) then
      error("workflow-qa: authorization-binding-changed: durable authorization identity differs")
    end
    return copy(existing.pending_actions or {})
  end

  local intake_ref = request.artifact_root .. "/intake.json"
  local seed_ref = request.artifact_root .. "/design/seed-cases.json"
  local seed = seed_document(request)
  if ports.write_artifact(intake_ref, {
    schema = "workflow-qa.intake.v2",
    repository = copy(request.repository),
    run_id = request.run_id,
    issue_number = request.issue.number,
    seed_case_count = #request.proposed_cases,
    preauthorization_ref = request.structured_execution.preauthorization_ref,
    case_catalog_ref = request.structured_execution.case_catalog_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }) ~= true or ports.write_artifact(seed_ref, seed) ~= true then
    error("workflow-qa: intake-artifact-write-failed: intake or seed artifact was not persisted")
  end
  local state = {
    schema = contract.schemas.state,
    version = 0,
    state_ref = request.state_ref,
    request = copy(request),
    authorization = copy(authorization),
    phase = "intake",
    pending_actions = {},
    digests = {},
    artifacts = {},
  }
  state.digests[intake_ref] = digest(ports, intake_ref)
  state.digests[seed_ref] = digest(ports, seed_ref)
  state.artifacts.intake_ref = intake_ref
  state.artifacts.seed_cases_ref = {
    artifact_pointer = seed_ref,
    artifact_digest = design_loop.document_digest(seed),
  }
  return gate_checkpoint(state, "intake", "planned", intake_ref, nil,
    "environment-pending", {
      action("environment-factory.environment_start", copy(request.environment_start)),
    }, ports)
end

local cleanup_action, begin_cleanup, prepare_finalization

function M.handle_environment_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: environment result has no durable run") end
  environment_contract.validate_result(payload)
  exact_identity(state, payload)
  if payload.operation_id ~= request.run_id
    or payload.source_ref.kind ~= request.environment_start.operation_state_ref.kind
    or payload.source_ref.ref ~= request.environment_start.operation_state_ref.ref then
    error("workflow-qa: foreign-environment-result: operation or source identity differs")
  end
  if state.phase ~= "environment-pending" and state.phase ~= "cleanup-pending" then
    return copy(state.pending_actions or {})
  end
  if state.phase == "cleanup-pending" then return M.handle_cleanup_result(payload, request, ports) end

  state.environment_result = copy(payload)
  state.environment_receipt_ref = payload.environment_receipt_ref.ref
  state.digests[state.environment_receipt_ref] = digest(ports, state.environment_receipt_ref)
  if payload.status == "ready" then
    local receipt = load_bound(ports, state.environment_receipt_ref,
      state.digests[state.environment_receipt_ref], "environment-receipt")
    if receipt.schema ~= "environment-factory.receipt.v2" or receipt.status ~= "ready"
      or receipt.operation_id ~= request.run_id or receipt.repository.url ~= request.repository.url
      or receipt.repository.commit_sha ~= request.repository.commit_sha
      or receipt.profile_sha256 ~= state.authorization.profile_sha256
      or type(receipt.browser_readiness) ~= "table" or receipt.browser_readiness.status ~= "ready"
      or receipt.trace_id ~= request.trace_id or receipt.dedup_key ~= request.dedup_key then
      error("workflow-qa: environment-readiness-unverified: ready receipt is foreign or missing browser proof")
    end
    state.environment_receipt = {
      base_url = receipt.base_url,
      sessions = copy(receipt.sessions),
      browser_readiness = copy(receipt.browser_readiness),
    }
    if state.interruption_requested ~= nil then return begin_cleanup(state, state.interruption_requested, ports) end
    return gate_checkpoint(state, "environment-ready", "passed", state.environment_receipt_ref, nil,
      "analysis-pending", {
        action("testing-design.analysis_request", copy(request.analysis_request)),
      }, ports)
  end

  if payload.cleanup_status ~= "complete" or payload.cleanup_receipt_ref == nil then
    error("workflow-qa: cleanup-unverified: blocked environment cleanup is incomplete")
  end
  state.cleanup_result = copy(payload)
  state.digests[payload.cleanup_receipt_ref.ref] = digest(ports, payload.cleanup_receipt_ref.ref)
  state.counts = { planned = 0, executed = 0, passed = 0, failed = 0, skipped = 0, error = 0, blocked = 1 }
  state.terminal_status = state.interruption_requested or payload.status
  return prepare_finalization(state, ports)
end

function M.handle_analysis_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: analysis result has no durable run") end
  design_contract.validate_result(payload)
  exact_identity(state, payload)
  if state.phase ~= "analysis-pending" then return copy(state.pending_actions or {}) end
  state.analysis_result = copy(payload)
  for _, ref in pairs(payload.context or {}) do
    if type(ref) == "table" and type(ref.artifact_pointer) == "string" then
      state.digests[ref.artifact_pointer] = ref.artifact_digest
    end
  end
  if state.interruption_requested ~= nil then return begin_cleanup(state, state.interruption_requested, ports) end

  local readiness_request = browser_readiness_request(state)
  state.browser_readiness_request = copy(readiness_request)
  return gate_checkpoint(state, "design-round",
    payload.status == "complete" and "passed" or payload.status,
    payload.context.traceability_seed.artifact_pointer, nil, "browser-readiness-pending", {
      action("browser-readiness.browser_readiness_check", readiness_request),
    }, ports)
end

function M.handle_browser_readiness_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: browser readiness result has no durable run") end
  local result_ok = pcall(browser_readiness_contract.validate_result, payload)
  local expected = state.browser_readiness_request
  if not result_ok or (payload.status ~= "ready" and payload.status ~= "blocked")
    or type(expected) ~= "table"
    or not browser_readiness_contract.equal(payload.source_ref, expected.source_ref)
    or not browser_readiness_contract.equal(payload.request_context, expected.request_context)
    or not browser_readiness_contract.equal(payload.correlation, expected.correlation) then
    error("workflow-qa: foreign-browser-readiness-result: result differs from the persisted readiness request")
  end
  if state.phase ~= "browser-readiness-pending" then return copy(state.pending_actions or {}) end
  if state.interruption_requested ~= nil then return begin_cleanup(state, state.interruption_requested, ports) end
  if payload.status ~= "ready" then return begin_cleanup(state, "blocked", ports) end

  local readiness_ref = request.artifact_root .. "/browser-readiness.json"
  if ports.write_artifact(readiness_ref, copy(payload)) ~= true then
    error("workflow-qa: browser-readiness-write-failed: readiness proof was not persisted")
  end
  state.browser_readiness = copy(payload)
  state.artifacts.browser_readiness_ref = readiness_ref
  state.digests[readiness_ref] = digest(ports, readiness_ref)

  local module_start = copy(request.design_module_start)
    if module_start.ai_design_loop_request ~= nil then
      module_start.ai_design_loop_request.seed_cases_ref = copy(state.artifacts.seed_cases_ref)
    end
  module_start.testing_design_context = copy(state.analysis_result.context)
  module_start.browser_readiness_ref = readiness_ref
  module_start.browser_readiness_sha256 = state.digests[readiness_ref]
  module_start.preflight_result = copy(payload)
  module_start.ui_loop = module_start.ui_loop or {}
  module_start.ui_loop.base_url = state.environment_receipt.base_url
  return gate_checkpoint(state, "browser-readiness", "passed", readiness_ref, nil,
    "module-pending", {
      action("module-testing-pipeline.module_start", module_start),
    }, ports)
end

function M.handle_module_terminal(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: module terminal has no durable run") end
  source_identity(state, payload, "workflow-qa", state.request.dedup_key .. "/terminal")
  if state.phase ~= "module-pending" then return copy(state.pending_actions or {}) end
  local runner = runner_from_module_terminal(payload)
  if type(runner) ~= "table" or runner.schema ~= "testing-runner.result.v1"
    or runner.job ~= "module-test-loop" or type(runner.native_summary) ~= "table" then
    error("workflow-qa: foreign-module-terminal: runner result is invalid")
  end
  if state.interruption_requested ~= nil then return begin_cleanup(state, state.interruption_requested, ports) end
  local module_plan_ref = payload.module_plan_ref or runner.native_summary.test_plan_path
  if runner.status == "blocked" or type(module_plan_ref) ~= "string" then
    return begin_cleanup(state, "blocked", ports)
  end
  local module_plan_sha256 = digest(ports, module_plan_ref)
  if payload.module_plan_sha256 ~= nil and payload.module_plan_sha256 ~= module_plan_sha256 then
    error("workflow-qa: foreign-module-terminal: module plan digest differs")
  end
  state.module_terminal = copy(payload)
  state.artifacts.module_plan_ref = module_plan_ref
  state.digests[module_plan_ref] = module_plan_sha256
  local plan_request = {
    schema = execution_contract.schemas.plan_request,
    repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
    module_plan_ref = module_plan_ref,
    module_plan_sha256 = state.digests[module_plan_ref],
    case_catalog_ref = request.structured_execution.case_catalog_ref,
    case_catalog_sha256 = request.structured_execution.case_catalog_sha256,
    environment_receipt_ref = state.environment_receipt_ref,
    environment_receipt_sha256 = state.digests[state.environment_receipt_ref],
    browser_readiness_ref = state.artifacts.browser_readiness_ref,
    browser_readiness_sha256 = state.digests[state.artifacts.browser_readiness_ref],
    plan_ref = request.structured_execution.structured_plan_ref,
    artifact_root = request.structured_execution.artifact_root,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    source_ref = { kind = "workflow-qa", ref = request.run_id },
  }
  return gate_checkpoint(state, "design-closure", "passed", module_plan_ref, nil,
    "structured-plan-pending", {
      action("testing-runner.structured_plan_request", plan_request),
    }, ports)
end

M.handle_design_result = M.handle_module_terminal

function M.handle_plan_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: plan result has no durable run") end
  execution_contract.validate_plan_result(payload)
  source_identity(state, payload, "workflow-qa", state.request.dedup_key)
  if state.phase ~= "structured-plan-pending" then return copy(state.pending_actions or {}) end
  if state.interruption_requested ~= nil then return begin_cleanup(state, state.interruption_requested, ports) end
  if payload.status ~= "compiled" or payload.plan_ref ~= request.structured_execution.structured_plan_ref then
    return begin_cleanup(state, "blocked", ports)
  end
  local plan = load_bound(ports, payload.plan_ref, payload.plan_sha256, "structured-plan")
  execution_contract.validate_plan(plan)
  if plan.repository.url ~= request.repository.url
    or plan.repository.commit_sha ~= request.repository.commit_sha
    or plan.environment_receipt_sha256 ~= state.digests[state.environment_receipt_ref]
    or plan.browser_readiness_sha256 ~= state.digests[state.artifacts.browser_readiness_ref]
    or plan.trace_id ~= request.trace_id or plan.dedup_key ~= request.dedup_key then
    error("workflow-qa: foreign-plan-result: compiled plan binding differs")
  end
  state.artifacts.structured_plan_ref = payload.plan_ref
  state.digests[payload.plan_ref] = payload.plan_sha256
  state.execution_mode = plan.execution_mode
  state.residual_risk_count = payload.residual_risk_count
  local grant_request = {
    schema = execution_contract.schemas.grant_request,
    execution_mode = plan.execution_mode,
    repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
    preauthorization_ref = request.structured_execution.preauthorization_ref,
    preauthorization_sha256 = request.structured_execution.preauthorization_sha256,
    plan_ref = payload.plan_ref,
    plan_sha256 = payload.plan_sha256,
    environment_receipt_ref = state.environment_receipt_ref,
    environment_receipt_sha256 = state.digests[state.environment_receipt_ref],
    grant_ref = request.structured_execution.grant_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    source_ref = { kind = "workflow-qa", ref = request.run_id },
  }
  set_pending(state, "execution-grant-pending", {
    action("workflow_qa_execution_grant_request", grant_request),
  })
  save(ports, state)
  return copy(state.pending_actions)
end

function M.handle_grant_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: grant result has no durable run") end
  execution_contract.validate_grant_result(payload)
  source_identity(state, payload, "workflow-qa", state.request.dedup_key)
  if state.phase ~= "execution-grant-pending" then return copy(state.pending_actions or {}) end
  if state.interruption_requested ~= nil then return begin_cleanup(state, state.interruption_requested, ports) end
  if payload.status ~= "granted" or payload.grant_ref ~= request.structured_execution.grant_ref then
    return begin_cleanup(state, "blocked", ports)
  end
  state.artifacts.execution_grant_ref = payload.grant_ref
  state.digests[payload.grant_ref] = payload.grant_sha256
  local grant = load_bound(ports, payload.grant_ref, payload.grant_sha256, "execution-grant")
  local dispatch
  if state.execution_mode == "structured-api-cli" then
    execution_contract.validate_grant(grant)
    if grant.parent_authorization_sha256 ~= state.authorization.preauthorization_sha256
      or grant.plan_sha256 ~= state.digests[state.artifacts.structured_plan_ref]
      or grant.environment_receipt_sha256 ~= state.digests[state.environment_receipt_ref] then
      error("workflow-qa: foreign-grant-result: structured grant binding differs")
    end
    dispatch = {
      phase = "structured-execution-pending",
      job = "structured-execution",
      queue = "testing-runner.structured_execution_request",
      payload = {
        schema = "testing-runner.structured-execution.request.v3",
        repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
        project_profile_ref = state.authorization.profile_ref,
        project_profile_artifact_sha256 = state.authorization.profile_artifact_sha256,
        profile_sha256 = state.authorization.profile_sha256,
        validation_receipt_ref = state.authorization.validation_receipt_ref,
        validation_receipt_sha256 = state.authorization.validation_receipt_sha256,
        preauthorization_ref = state.authorization.preauthorization_ref,
        preauthorization_sha256 = state.authorization.preauthorization_sha256,
        environment_receipt_ref = state.environment_receipt_ref,
        environment_receipt_sha256 = state.digests[state.environment_receipt_ref],
        browser_readiness_ref = state.artifacts.browser_readiness_ref,
        browser_readiness_sha256 = state.digests[state.artifacts.browser_readiness_ref],
        test_plan_ref = state.artifacts.structured_plan_ref,
        test_plan_sha256 = state.digests[state.artifacts.structured_plan_ref],
        execution_grant_ref = payload.grant_ref,
        execution_grant_sha256 = payload.grant_sha256,
        artifact_root = request.structured_execution.artifact_root,
        trace_id = request.trace_id,
        dedup_key = request.dedup_key,
        source_ref = { kind = "workflow-qa", ref = request.run_id },
      },
    }
  elseif state.execution_mode == "agentic-browser" then
    browser_contract.validate_grant(grant)
    if grant.parent_authorization_sha256 ~= state.authorization.preauthorization_sha256
      or grant.reviewed_plan_sha256 ~= state.digests[state.artifacts.structured_plan_ref]
      or grant.environment_receipt_sha256 ~= state.digests[state.environment_receipt_ref] then
      error("workflow-qa: foreign-grant-result: browser grant binding differs")
    end
    dispatch = {
      phase = "browser-control-pending",
      job = "ai-browser-control",
      queue = "testing-runner.ai_browser_control_request",
      payload = {
        schema = browser_contract.schemas.request,
        repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
        environment_receipt_ref = state.environment_receipt_ref,
        environment_receipt_sha256 = state.digests[state.environment_receipt_ref],
        reviewed_plan_ref = state.artifacts.structured_plan_ref,
        reviewed_plan_sha256 = state.digests[state.artifacts.structured_plan_ref],
        browser_grant_ref = payload.grant_ref,
        browser_grant_sha256 = payload.grant_sha256,
        artifact_root = request.structured_execution.artifact_root,
        trace_id = request.trace_id,
        dedup_key = request.dedup_key,
        source_ref = { kind = "workflow-qa", ref = request.run_id },
      },
    }
  else
    error("workflow-qa: unsupported-execution-mode: " .. tostring(state.execution_mode))
  end
  state.execution_job = dispatch.job
  set_pending(state, dispatch.phase, { action(dispatch.queue, dispatch.payload) })
  save(ports, state)
  return copy(state.pending_actions)
end

function M.handle_execution_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: execution result has no durable run") end
  source_identity(state, payload, "workflow-qa", state.request.dedup_key)
  local expected_phase = state.execution_mode == "agentic-browser"
    and "browser-control-pending" or "structured-execution-pending"
  if state.phase ~= expected_phase then return copy(state.pending_actions or {}) end
  if type(payload) ~= "table" or payload.schema ~= "testing-runner.result.v1"
    or payload.job ~= state.execution_job then
    error("workflow-qa: foreign-execution-result: selected execution binding differs")
  end
  state.execution_result = copy(payload)
  set_pending(state, "artifact-summary-pending", {
    action("test-artifacts.testing_result", copy(payload)),
  })
  save(ports, state)
  return copy(state.pending_actions)
end

local function publication_from_summary(state, summary)
  local native = summary.native_summary
  return {
    schema = "test-publication.publication-request.v1",
    publication_kind = "testing-summary",
    channel = "testing",
    severity = "failure",
    subject = (state.execution_mode == "agentic-browser" and "Agentic browser" or "Structured")
      .. " QA failures for " .. state.request.repository.slug,
    trace_id = state.request.trace_id,
    dedup_key = state.request.dedup_key,
    status = "failed",
    job = state.execution_job,
    artifact_root = summary.artifact_root,
    metadata_path = summary.metadata_path,
    source_ref = { kind = "workflow-qa", ref = state.request.run_id },
    test_plan_path = state.artifacts.structured_plan_ref,
    execution_path = native.execution_path,
    case_results_path = native.case_results_path,
    publication_dry_run = true,
  }
end

function M.handle_artifact_summary(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: artifact summary has no durable run") end
  source_identity(state, payload, "workflow-qa", state.request.dedup_key)
  if payload.schema ~= "test-artifacts.summary.v1" or payload.job ~= state.execution_job
    or payload.artifact_root ~= request.structured_execution.artifact_root then
    error("workflow-qa: foreign-artifact-summary: summary binding differs")
  end
  if state.phase ~= "artifact-summary-pending" then return copy(state.pending_actions or {}) end
  state.execution_summary = copy(payload)
  local summary = payload.native_summary
  if type(summary) ~= "table" or type(summary.case_results_path) ~= "string"
    or payload.status == "blocked" then
    state.counts = { planned = 0, executed = 0, passed = 0, failed = 0, skipped = 0, error = 0, blocked = 1 }
    return begin_cleanup(state, state.interruption_requested or "blocked", ports)
  end
  state.artifacts.case_results_ref = summary.case_results_path
  state.digests[summary.case_results_path] = digest(ports, summary.case_results_path)
  local counts = {
    planned = summary.case_count or 0,
    executed = summary.case_count or 0,
    passed = summary.passed_count or 0,
    failed = summary.failed_count or 0,
    skipped = summary.skipped_count or 0,
    error = summary.error_count or 0,
    blocked = 0,
  }
  state.counts = counts
  local next_phase, next_actions
  local next_status = state.interruption_requested or payload.status
  if state.interruption_requested ~= nil or counts.failed == 0 then
    if counts.failed == 0 then state.defect_terminal = { status = "published" } end
    state.terminal_status = next_status
    next_phase = "cleanup-pending"
    next_actions = { cleanup_action(state, next_status) }
  end
  local prepare = {
    schema = "test-publication.defect-preparation.request.v1",
    publication = publication_from_summary(state, payload),
    repository = { slug = request.repository.slug, commit_sha = request.repository.commit_sha },
    run_id = request.run_id,
    plan_ref = state.artifacts.structured_plan_ref,
    plan_sha256 = state.digests[state.artifacts.structured_plan_ref],
    case_results_ref = summary.case_results_path,
    case_results_sha256 = state.digests[summary.case_results_path],
    issue_drafts_ref = request.publication.issue_drafts_ref,
    ledger_ref = request.publication.defect_ledger_ref,
    receipt_ref = request.publication.defect_receipt_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  if next_phase == nil then
    next_phase = "defects-pending"
    next_actions = { action("test-publication.defect_preparation_request", prepare) }
  end
  return gate_checkpoint(state, "execution-batch", payload.status,
    summary.case_results_path, counts, next_phase, next_actions, ports)
end

function M.handle_defect_terminal(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: defect terminal has no durable run") end
  exact_identity(state, payload)
  if payload.schema ~= "test-publication.defect-publication-terminal.v1"
    or (payload.status ~= "published" and payload.status ~= "blocked") then
    error("workflow-qa: foreign-defect-terminal: publication receipt binding differs")
  end
  if state.phase ~= "defects-pending" then return copy(state.pending_actions or {}) end
  if payload.receipt_ref ~= request.publication.defect_receipt_ref then
    error("workflow-qa: foreign-defect-terminal: receipt pointer differs")
  end
  state.defect_terminal = copy(payload)
  state.digests[payload.receipt_ref] = digest(ports, payload.receipt_ref)
  local status = state.interruption_requested or (payload.status == "published"
    and state.execution_summary.status or "blocked")
  state.terminal_status = status
  return gate_checkpoint(state, "defect-publication",
    payload.status == "published" and "completed" or "blocked",
    payload.receipt_ref, state.counts, "cleanup-pending", {
      cleanup_action(state, status),
    }, ports)
end

cleanup_action = function(state, status)
  local ready = state.environment_result
  if type(ready) ~= "table" or ready.status ~= "ready" then
    error("workflow-qa: cleanup-unavailable: no owned ready environment exists")
  end
  local interrupted = status == "cancelled" or status == "interrupted" or status == "timed-out"
  local finalize = {
    schema = interrupted and environment_contract.schemas.interrupt or environment_contract.schemas.finalize,
    operation_id = state.request.run_id,
    cleanup_ref = copy(ready.cleanup_ref),
    operation_state_ref = copy(state.request.environment_start.operation_state_ref),
    trace_id = state.request.trace_id,
    dedup_key = state.request.dedup_key,
  }
  if interrupted then finalize.interruption = status == "cancelled" and "cancelled" or "interrupted" end
  return action(interrupted
    and "environment-factory.environment_interrupt" or "environment-factory.environment_finalize", finalize)
end

begin_cleanup = function(state, status, ports, counts)
  state.counts = counts or state.counts or {
    planned = 0, executed = 0, passed = 0, failed = 0,
    skipped = 0, error = 0, blocked = 1,
  }
  state.terminal_status = status
  set_pending(state, "cleanup-pending", { cleanup_action(state, status) })
  save(ports, state)
  return copy(state.pending_actions)
end

prepare_finalization = function(state, ports)
  local request = state.request
  local cleanup = state.cleanup_result
  local summary_ref = terminal_summary(state, ports, state.terminal_status or cleanup.status)
  local final = {
    schema = "test-publication.qa-finalize.request.v2",
    repository = { slug = request.repository.slug, commit_sha = request.repository.commit_sha },
    run_id = request.run_id,
    issue_number = request.issue.number,
    artifact_root = request.artifact_root,
    ledger_ref = request.publication.ledger_ref,
    terminal_summary_ref = summary_ref,
    terminal_summary_sha256 = state.digests[summary_ref],
    environment_receipt_ref = state.environment_receipt_ref,
    environment_receipt_sha256 = state.digests[state.environment_receipt_ref],
    cleanup_receipt_ref = cleanup.cleanup_receipt_ref.ref,
    cleanup_receipt_sha256 = state.digests[cleanup.cleanup_receipt_ref.ref],
    browser_readiness_ref = state.artifacts.browser_readiness_ref,
    browser_readiness_sha256 = state.artifacts.browser_readiness_ref
      and state.digests[state.artifacts.browser_readiness_ref] or nil,
    aggregate_report_ref = request.publication.aggregate_report_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  if request.publication.channel ~= nil then
    final.channel = request.publication.channel
  end
  if state.artifacts.structured_plan_ref ~= nil and state.artifacts.case_results_ref ~= nil then
    final.test_plan_ref = state.artifacts.structured_plan_ref
    final.test_plan_sha256 = state.digests[state.artifacts.structured_plan_ref]
    final.case_results_ref = state.artifacts.case_results_ref
    final.case_results_sha256 = state.digests[state.artifacts.case_results_ref]
  end
  if state.defect_terminal and state.defect_terminal.receipt_ref then
    final.defect_publication_receipt_ref = state.defect_terminal.receipt_ref
    final.defect_publication_receipt_sha256 = state.digests[state.defect_terminal.receipt_ref]
  end
  state.finalization_request = copy(final)
  return gate_checkpoint(state, "cleanup", "passed", cleanup.cleanup_receipt_ref.ref,
    state.counts, "publication-pending", {
      action("test-publication.qa_finalize_request", final),
    }, ports)
end

function M.handle_cleanup_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: cleanup result has no durable run") end
  environment_contract.validate_result(payload)
  exact_identity(state, payload)
  if payload.operation_id ~= request.run_id
    or payload.source_ref.kind ~= request.environment_start.operation_state_ref.kind
    or payload.source_ref.ref ~= request.environment_start.operation_state_ref.ref then
    error("workflow-qa: foreign-cleanup-result: operation or source identity differs")
  end
  if state.phase ~= "cleanup-pending" then return copy(state.pending_actions or {}) end
  if payload.cleanup_status ~= "complete" or payload.cleanup_receipt_ref == nil then
    error("workflow-qa: cleanup-unverified: terminal cleanup receipt is incomplete")
  end
  state.cleanup_result = copy(payload)
  state.digests[payload.cleanup_receipt_ref.ref] = digest(ports, payload.cleanup_receipt_ref.ref)
  return prepare_finalization(state, ports)
end

function M.handle_environment_event(payload, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  local request = resolve_request(payload, nil, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: environment event has no durable run") end
  if state.phase == "cleanup-pending" then return M.handle_cleanup_result(payload, request, ports) end
  return M.handle_environment_result(payload, request, ports)
end

function M.handle_interrupt(payload, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  contract.validate_interrupt(payload)
  local request = resolve_request(payload, nil, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: interruption-unavailable: durable run is missing") end
  if state.phase == "cleanup-pending" or state.phase == "publication-pending" or state.phase == "terminal" then
    return copy(state.pending_actions or {})
  end
  state.interruption_requested = payload.interruption
  if state.phase == "environment-pending" then
    save(ports, state)
    return copy(state.pending_actions or {})
  end
  if state.phase == "structured-execution-pending" or state.phase == "browser-control-pending"
    or state.phase == "artifact-summary-pending"
    or state.phase == "defects-pending" then
    save(ports, state)
    return copy(state.pending_actions or {})
  end
  return begin_cleanup(state, payload.interruption, ports)
end

function M.terminal_request(state, status, receipt)
  return {
    schema = contract.schemas.terminal,
    repository = state.request.repository.slug,
    issue_number = state.request.issue.number,
    run_id = state.request.run_id,
    status = status,
    counts = copy(state.counts),
    artifact_root = state.request.artifact_root,
    aggregate_report_ref = state.request.publication.aggregate_report_ref,
    aggregate_report_sha256 = receipt and receipt.artifact_sha256 or nil,
    aggregate_publication_receipt_ref = receipt and receipt.receipt_ref or nil,
    aggregate_publication_receipt_sha256 = state.aggregate_receipt_sha256,
    cleanup_receipt_ref = state.cleanup_result and state.cleanup_result.cleanup_receipt_ref.ref or nil,
    cleanup_receipt_sha256 = state.cleanup_result and state.cleanup_result.cleanup_receipt_ref
      and state.digests[state.cleanup_result.cleanup_receipt_ref.ref] or nil,
    terminal_policy = "host",
    trace_id = state.request.trace_id,
    dedup_key = state.request.dedup_key,
  }
end

function M.handle_publication_receipt(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: publication receipt has no durable run") end
  exact_identity(state, payload)
  if payload.schema ~= "test-publication.qa-publication-receipt.v2"
    or payload.run_id ~= request.run_id then
    error("workflow-qa: foreign-publication-receipt: publication binding differs")
  end
  if state.phase == "checkpoint-pending" then
    local released = checkpoints.release(state, payload, ports)
    if released == nil then
      error("workflow-qa: foreign-publication-receipt: no matching checkpoint lease exists")
    end
    save(ports, state)
    return copy(released)
  end
  if state.phase ~= "publication-pending" then return copy(state.pending_actions or {}) end
  if payload.stage ~= "aggregate-report" then
    error("workflow-qa: foreign-publication-receipt: no matching checkpoint lease exists")
  end
  if type(state.finalization_request) ~= "table"
    or state.finalization_request.aggregate_report_ref ~= request.publication.aggregate_report_ref then
    error("workflow-qa: aggregate-finalization-unavailable: pending finalization binding is missing")
  end
  local aggregate_sha256 = digest(ports, request.publication.aggregate_report_ref)
  local expected = checkpoints.aggregate_expectation(state, aggregate_sha256)
  state.aggregate_receipt_sha256 = checkpoints.validate_receipt(state, payload, expected, ports)
  state.digests[request.publication.aggregate_report_ref] = aggregate_sha256
  state.aggregate_receipt = copy(payload)
  set_pending(state, "terminal", {
    action("workflow_qa_terminal_request",
      M.terminal_request(state, state.terminal_status or "passed", payload)),
  })
  save(ports, state)
  return copy(state.pending_actions or {})
end

function M.redrive(payload, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  local limit = type(payload) == "table" and payload.limit or 32
  if type(limit) ~= "number" or limit < 1 or limit > 64 or limit ~= math.floor(limit) then
    error("workflow-qa: malformed-redrive: limit must be from 1 to 64")
  end
  local run_id = type(payload) == "table" and payload.run_id or nil
  local runs
  if run_id ~= nil then
    if type(run_id) ~= "string" or run_id == "" or #run_id > 180
      or run_id:match("^[A-Za-z0-9._-]+$") == nil then
      error("workflow-qa: malformed-redrive: run_id is invalid")
    end
    local request = ports.load_run_by_id(run_id)
    runs = request == nil and {} or { request }
  else
    runs = ports.list_pending_runs(limit)
  end
  if type(runs) ~= "table" then error("workflow-qa: redrive-unavailable: pending run list is invalid") end
  local actions = {}
  for index, request in ipairs(runs) do
    if index > limit then break end
    request = contract.validate_request(request)
    local state = load_for(request, ports)
    if state == nil then
      for _, pending in ipairs(M.start(request, ports)) do table.insert(actions, copy(pending)) end
    else
      local authorization = validate_authorization_chain(request, ports)
      if not contract.same_request(state.authorization, authorization) then
        error("workflow-qa: authorization-binding-changed: durable authorization identity differs")
      end
      for _, pending in ipairs(state.pending_actions or {}) do table.insert(actions, copy(pending)) end
    end
  end
  return actions
end

function M.saga_conformance_errors()
  return {}
end

return M
