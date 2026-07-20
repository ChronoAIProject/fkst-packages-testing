local contract = require("contract.workflow_qa")
local environment_contract = require("contract.environment_factory")
local design_contract = require("contract.testing_design")
local ports_module = require("ports")
local design_loop = require("testing_ai.module_ai_design_loop")

local M = {}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out, keys = {}, {}
  for key, _ in pairs(value) do table.insert(keys, key) end
  for _, key in ipairs(keys) do out[copy(key)] = copy(value[key]) end
  return out
end

local function action(queue, payload)
  return { queue = queue, payload = payload }
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

local function seed_reference(request, document)
  return {
    artifact_pointer = request.artifact_root .. "/design/seed-cases.json",
    artifact_digest = design_loop.document_digest(document),
  }
end

local function digest(ports, pointer)
  local value = ports.artifact_digest(pointer)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    error("workflow-qa: artifact-digest-unavailable: " .. tostring(pointer))
  end
  return value
end

local function save(ports, state)
  local expected = state.version
  state.version = expected + 1
  if ports.save_state(state.state_ref, copy(state), expected) ~= true then
    error("workflow-qa: state-save-conflict: durable compare-and-swap failed")
  end
end

local function checkpoint(state, stage, status, artifact_ref, counts)
  return {
    schema = "test-publication.qa-checkpoint.request.v1",
    repository = { slug = state.request.repository.slug, commit_sha = state.request.repository.commit_sha },
    run_id = state.request.run_id,
    issue_number = state.request.issue.number,
    stage = stage,
    attempt = 1,
    status = status,
    artifact_root = state.request.artifact_root,
    artifact_ref = artifact_ref,
    artifact_sha256 = state.digests[artifact_ref],
    ledger_ref = state.request.publication.ledger_ref,
    trace_id = state.request.trace_id,
    dedup_key = state.request.dedup_key,
    counts = counts,
  }
end

local function set_pending(state, phase, actions)
  state.phase = phase
  state.pending_actions = actions
end

local function terminal_summary(state, ports, status)
  local ref = state.request.artifact_root .. "/terminal-summary.json"
  if ports.write_artifact(ref, {
    schema = "workflow-qa.terminal-summary.v1", status = status,
    repository = copy(state.request.repository), run_id = state.request.run_id,
    counts = copy(state.counts or { planned = 0, executed = 0, passed = 0, failed = 0, skipped = 0, error = 0, blocked = 1 }),
    environment_receipt_ref = state.environment_result and state.environment_result.environment_receipt_ref.ref or nil,
    cleanup_receipt_ref = state.cleanup_result and state.cleanup_result.cleanup_receipt_ref.ref
      or (state.environment_result and state.environment_result.cleanup_receipt_ref and state.environment_result.cleanup_receipt_ref.ref),
    trace_id = state.request.trace_id, dedup_key = state.request.dedup_key,
  }) ~= true then
    error("workflow-qa: terminal-summary-write-failed: bounded terminal summary was not persisted")
  end
  state.digests[ref] = digest(ports, ref)
  state.artifacts.terminal_summary_ref = ref
  state.terminal_status = status
  return ref
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

local function validate_identity(state, payload)
  if payload.trace_id ~= state.request.trace_id or payload.dedup_key ~= state.request.dedup_key then
    error("workflow-qa: foreign-result: trace or dedup identity differs")
  end
end

local function resolve_request(payload, request, ports)
  if request ~= nil then return contract.validate_request(request) end
  local recovered = ports.load_run(payload.trace_id, payload.dedup_key)
  if type(recovered) ~= "table" then error("workflow-qa: run-identity-unavailable: durable run lookup failed") end
  return contract.validate_request(recovered)
end

function M.start(request, supplied_ports)
  request = contract.validate_request(request)
  local ports = ports_module.resolve(supplied_ports)
  local existing = load_for(request, ports)
  if existing ~= nil then return copy(existing.pending_actions or {}) end

  local intake_ref = request.artifact_root .. "/intake.json"
  local seed = seed_document(request)
  local seed_ref = seed_reference(request, seed)
  if ports.write_artifact(intake_ref, {
    schema = "workflow-qa.intake.v1", repository = copy(request.repository), run_id = request.run_id,
    issue_number = request.issue.number, seed_case_count = #request.proposed_cases,
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }) ~= true or ports.write_artifact(seed_ref.artifact_pointer, seed) ~= true then
    error("workflow-qa: intake-artifact-write-failed: intake or seed artifact was not persisted")
  end
  local state = {
    schema = contract.schemas.state, version = 0, state_ref = request.state_ref,
    request = copy(request), phase = "intake", pending_actions = {}, digests = {}, artifacts = {},
  }
  state.digests[intake_ref] = digest(ports, intake_ref)
  state.digests[seed_ref.artifact_pointer] = digest(ports, seed_ref.artifact_pointer)
  state.artifacts.intake_ref = intake_ref
  state.artifacts.seed_cases_ref = seed_ref
  set_pending(state, "environment-pending", {
    action("test-publication.qa_checkpoint_request", checkpoint(state, "intake", "planned", intake_ref)),
    action("environment-factory.environment_start", copy(request.environment_start)),
  })
  save(ports, state)
  return copy(state.pending_actions)
end

function M.handle_environment_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: environment result has no durable run") end
  environment_contract.validate_result(payload)
  validate_identity(state, payload)
  if payload.operation_id ~= request.run_id then error("workflow-qa: foreign-environment-result: operation ID differs") end

  if state.phase == "environment-pending" then
    state.environment_result = copy(payload)
    state.digests[payload.environment_receipt_ref.ref] = digest(ports, payload.environment_receipt_ref.ref)
    if payload.status == "ready" then
      set_pending(state, "analysis-pending", {
        action("test-publication.qa_checkpoint_request", checkpoint(state, "environment-ready", "passed", payload.environment_receipt_ref.ref)),
        action("testing-design.analysis_request", copy(request.analysis_request)),
      })
    else
      if payload.cleanup_status ~= "complete" then error("workflow-qa: cleanup-unverified: blocked environment cleanup is incomplete") end
      state.cleanup_result = copy(payload)
      state.counts = { planned = 0, executed = 0, passed = 0, failed = 0, skipped = 0, error = 0, blocked = 1 }
      state.digests[payload.cleanup_receipt_ref.ref] = digest(ports, payload.cleanup_receipt_ref.ref)
      local summary_ref = terminal_summary(state, ports, "blocked")
      set_pending(state, "early-publication-pending", {
        action("test-publication.qa_checkpoint_request", checkpoint(state, "aggregate-report", "blocked", summary_ref, state.counts)),
      })
    end
    save(ports, state)
  end
  return copy(state.pending_actions or {})
end

function M.handle_analysis_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: analysis result has no durable run") end
  design_contract.validate_result(payload)
  validate_identity(state, payload)
  if state.phase == "analysis-pending" then
    state.analysis_result = copy(payload)
    state.digests[payload.context.traceability_seed.artifact_pointer] = payload.context.traceability_seed.artifact_digest
    local module_start = copy(request.design_module_start)
    module_start.cdp_execution.ai_design_loop_request.seed_cases_ref = copy(state.artifacts.seed_cases_ref)
    module_start.config = module_start.config or {}
    module_start.config.workflow_qa_repository_analysis_ref = payload.context.repository_analysis.artifact_pointer
    module_start.config.workflow_qa_requirements_index_ref = payload.context.requirements_index.artifact_pointer
    module_start.config.workflow_qa_traceability_seed_ref = payload.context.traceability_seed.artifact_pointer
    module_start.config.workflow_qa_analysis_key = payload.analysis_key
    set_pending(state, "design-pending", {
      action("test-publication.qa_checkpoint_request", checkpoint(state, "design-round",
        payload.status == "complete" and "passed" or payload.status, payload.context.traceability_seed.artifact_pointer)),
      action("testing-pipeline.module_start", module_start),
    })
    save(ports, state)
  end
  return copy(state.pending_actions or {})
end

local function is_design_result(state, payload)
  return type(payload) == "table" and payload.schema == "testing-runner.result.v1"
    and payload.job ~= "structured-execution" and type(payload.source_ref) == "table"
    and payload.source_ref.kind == "workflow-qa" and payload.source_ref.ref == state.request.run_id
end

function M.handle_design_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: design result has no durable run") end
  validate_identity(state, payload)
  if not is_design_result(state, payload) then error("workflow-qa: foreign-design-result: source binding differs") end
  if state.phase == "design-pending" then
    if payload.status == "blocked" or type(payload.native_summary) ~= "table"
      or type(payload.native_summary.test_plan_path) ~= "string" then
      return M.begin_cleanup(state, "blocked", ports)
    end
    local plan_ref = payload.native_summary.test_plan_path
    state.artifacts.test_plan_ref = plan_ref
    state.digests[plan_ref] = digest(ports, plan_ref)
    local execution = {
      schema = "testing-runner.structured-execution.request.v1",
      repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
      environment_receipt_ref = state.environment_result.environment_receipt_ref.ref,
      environment_receipt_sha256 = state.digests[state.environment_result.environment_receipt_ref.ref],
      test_plan_ref = plan_ref,
      test_plan_sha256 = state.digests[plan_ref],
      execution_approval_ref = request.structured_execution.execution_approval_ref,
      execution_approval_sha256 = request.structured_execution.execution_approval_sha256,
      artifact_root = request.structured_execution.artifact_root,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
      source_ref = { kind = "workflow-qa", ref = request.run_id },
    }
    set_pending(state, "execution-pending", {
      action("test-publication.qa_checkpoint_request", checkpoint(state, "design-closure", "passed", plan_ref)),
      action("testing-runner.structured_execution_request", execution),
    })
    save(ports, state)
  end
  return copy(state.pending_actions or {})
end

function M.handle_execution_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: execution result has no durable run") end
  validate_identity(state, payload)
  if type(payload) ~= "table" or payload.schema ~= "testing-runner.result.v1"
    or payload.job ~= "structured-execution" or type(payload.native_summary) ~= "table" then
    error("workflow-qa: foreign-execution-result: structured execution binding differs")
  end
  if state.phase == "execution-pending" then
    local summary = payload.native_summary
    state.execution_result = copy(payload)
    state.artifacts.case_results_ref = summary.case_results_path
    state.digests[summary.case_results_path] = digest(ports, summary.case_results_path)
    local counts = {
      planned = summary.case_count or 0, executed = summary.case_count or 0,
      passed = summary.passed_count or 0, failed = summary.failed_count or 0,
      skipped = summary.skipped_count or 0, error = summary.error_count or 0, blocked = 0,
    }
    if counts.failed == 0 then
      state.defect_terminal = { status = "published" }
      state.counts = counts
      local execution_checkpoint = action("test-publication.qa_checkpoint_request",
        checkpoint(state, "execution-batch", payload.status, summary.case_results_path, counts))
      return M.begin_cleanup(state, payload.status, ports, counts, { execution_checkpoint })
    end
    local drafts = ports.materialize_issue_drafts({
      artifact_root = payload.artifact_root, case_results_ref = summary.case_results_path,
      plan_sha256 = state.digests[state.artifacts.test_plan_ref],
      issue_drafts_ref = request.publication.issue_drafts_ref,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    })
    if type(drafts) ~= "table" or drafts.ref ~= request.publication.issue_drafts_ref then
      error("workflow-qa: issue-drafts-unavailable: bounded product-defect drafts were not materialized")
    end
    state.digests[drafts.ref] = digest(ports, drafts.ref)
    local publication = {
      schema = "test-publication.publication-request.v1", publication_kind = "testing-summary",
      channel = "testing", severity = "error", subject = "Structured QA failures for " .. request.repository.slug,
      trace_id = request.trace_id, dedup_key = request.dedup_key, status = "failed", job = "structured-execution",
      artifact_root = payload.artifact_root, metadata_path = payload.artifact_root .. "/metadata.json",
      source_ref = { kind = "workflow-qa", ref = request.run_id },
      test_plan_path = summary.test_plan_path, execution_path = summary.execution_path,
      case_results_path = summary.case_results_path, issue_drafts_path = drafts.ref,
      publication_dry_run = true,
    }
    local defect = {
      schema = "test-publication.defect-publication.request.v1", publication = publication,
      repository = { slug = request.repository.slug, commit_sha = request.repository.commit_sha },
      plan_sha256 = state.digests[state.artifacts.test_plan_ref],
      case_results_ref = summary.case_results_path, case_results_sha256 = state.digests[summary.case_results_path],
      issue_drafts_ref = drafts.ref, issue_drafts_sha256 = state.digests[drafts.ref],
      ledger_ref = request.publication.defect_ledger_ref, receipt_ref = request.publication.defect_receipt_ref,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }
    set_pending(state, "defects-pending", {
      action("test-publication.qa_checkpoint_request", checkpoint(state, "execution-batch", payload.status, summary.case_results_path, counts)),
      action("test-publication.defect_publication_request", defect),
    })
    state.counts = counts
    save(ports, state)
  end
  return copy(state.pending_actions or {})
end

function M.begin_cleanup(state, status, ports, counts, prefix_actions)
  state.counts = counts or state.counts or { planned = 0, executed = 0, passed = 0, failed = 0, skipped = 0, error = 0, blocked = 1 }
  local ready = state.environment_result
  local finalize = {
    schema = (status == "cancelled" or status == "interrupted")
      and environment_contract.schemas.interrupt or environment_contract.schemas.finalize,
    operation_id = state.request.run_id,
    cleanup_ref = copy(ready.cleanup_ref), operation_state_ref = copy(state.request.environment_start.operation_state_ref),
    trace_id = state.request.trace_id, dedup_key = state.request.dedup_key,
  }
  if status == "cancelled" or status == "interrupted" then finalize.interruption = status end
  state.terminal_status = status
  local actions = copy(prefix_actions or {})
  table.insert(actions, action((status == "cancelled" or status == "interrupted")
    and "environment-factory.environment_interrupt" or "environment-factory.environment_finalize", finalize))
  set_pending(state, "cleanup-pending", actions)
  save(ports, state)
  return copy(state.pending_actions)
end

function M.handle_interrupt(payload, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  if type(payload) ~= "table" or payload.schema ~= "workflow-qa.interrupt.v1"
    or (payload.interruption ~= "cancelled" and payload.interruption ~= "interrupted" and payload.interruption ~= "timed-out") then
    error("workflow-qa: malformed-interruption: interruption must be cancelled, interrupted, or timed-out")
  end
  local request = resolve_request(payload, nil, ports)
  local state = load_for(request, ports)
  if state == nil or state.environment_result == nil or state.environment_result.status ~= "ready" then
    error("workflow-qa: interruption-unavailable: no owned ready environment exists")
  end
  if state.phase == "cleanup-pending" or state.phase == "publication-pending" or state.phase == "terminal" then
    return copy(state.pending_actions or {})
  end
  return M.begin_cleanup(state, payload.interruption, ports)
end

function M.handle_defect_terminal(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: defect terminal has no durable run") end
  validate_identity(state, payload)
  if payload.schema ~= "test-publication.defect-publication-terminal.v1"
    or (payload.status ~= "published" and payload.status ~= "blocked") then
    error("workflow-qa: foreign-defect-terminal: publication receipt binding differs")
  end
  if state.phase == "defects-pending" then
    state.defect_terminal = copy(payload)
    state.digests[payload.receipt_ref] = digest(ports, payload.receipt_ref)
    return M.begin_cleanup(state, payload.status == "published" and state.execution_result.status or "blocked", ports)
  end
  return copy(state.pending_actions or {})
end

function M.handle_cleanup_result(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: cleanup result has no durable run") end
  environment_contract.validate_result(payload)
  validate_identity(state, payload)
  if state.phase == "cleanup-pending" then
    if payload.cleanup_status ~= "complete" or payload.cleanup_receipt_ref == nil then
      error("workflow-qa: cleanup-unverified: terminal cleanup receipt is incomplete")
    end
    state.cleanup_result = copy(payload)
    state.digests[payload.cleanup_receipt_ref.ref] = digest(ports, payload.cleanup_receipt_ref.ref)
    if state.artifacts.test_plan_ref == nil or state.artifacts.case_results_ref == nil then
      local summary_ref = terminal_summary(state, ports, state.terminal_status or "blocked")
      set_pending(state, "early-publication-pending", {
        action("test-publication.qa_checkpoint_request", checkpoint(state, "aggregate-report",
          state.terminal_status or "blocked", summary_ref, state.counts)),
      })
      save(ports, state)
      return copy(state.pending_actions)
    end
    local final = {
      schema = "test-publication.qa-finalize.request.v1",
      repository = { slug = request.repository.slug, commit_sha = request.repository.commit_sha },
      run_id = request.run_id, issue_number = request.issue.number, artifact_root = request.artifact_root,
      ledger_ref = request.publication.ledger_ref,
      test_plan_ref = state.artifacts.test_plan_ref, test_plan_sha256 = state.digests[state.artifacts.test_plan_ref],
      case_results_ref = state.artifacts.case_results_ref, case_results_sha256 = state.digests[state.artifacts.case_results_ref],
      environment_receipt_ref = state.environment_result.environment_receipt_ref.ref,
      environment_receipt_sha256 = state.digests[state.environment_result.environment_receipt_ref.ref],
      cleanup_receipt_ref = payload.cleanup_receipt_ref.ref,
      cleanup_receipt_sha256 = state.digests[payload.cleanup_receipt_ref.ref],
      aggregate_report_ref = request.publication.aggregate_report_ref,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }
    if state.defect_terminal and state.defect_terminal.receipt_ref then
      final.defect_publication_receipt_ref = state.defect_terminal.receipt_ref
      final.defect_publication_receipt_sha256 = state.digests[state.defect_terminal.receipt_ref]
    end
    set_pending(state, "publication-pending", {
      action("test-publication.qa_checkpoint_request", checkpoint(state, "cleanup", "passed", payload.cleanup_receipt_ref.ref, state.counts)),
      action("test-publication.qa_finalize_request", final),
    })
    save(ports, state)
  end
  return copy(state.pending_actions or {})
end

function M.handle_environment_event(payload, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  local request = resolve_request(payload, nil, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: environment event has no durable run") end
  if state.phase == "cleanup-pending" then return M.handle_cleanup_result(payload, request, ports) end
  return M.handle_environment_result(payload, request, ports)
end

function M.terminal_request(state, status, receipt)
  return {
    schema = contract.schemas.terminal,
    repository = state.request.repository.slug, issue_number = state.request.issue.number,
    run_id = state.request.run_id, status = status, counts = copy(state.counts),
    artifact_root = state.request.artifact_root,
    aggregate_publication_receipt_ref = receipt and receipt.receipt_ref or nil,
    cleanup_receipt_ref = state.cleanup_result and state.cleanup_result.cleanup_receipt_ref.ref
      or (state.environment_result and state.environment_result.cleanup_receipt_ref and state.environment_result.cleanup_receipt_ref.ref),
    terminal_policy = state.request.terminal_policy.mode,
    trace_id = state.request.trace_id, dedup_key = state.request.dedup_key,
  }
end

function M.handle_publication_receipt(payload, request, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  request = resolve_request(payload, request, ports)
  local state = load_for(request, ports)
  if state == nil then error("workflow-qa: state-unavailable: publication receipt has no durable run") end
  validate_identity(state, payload)
  if payload.schema ~= "test-publication.qa-publication-receipt.v1" or payload.run_id ~= request.run_id then
    error("workflow-qa: foreign-publication-receipt: aggregate publication binding differs")
  end
  if state.phase == "publication-pending" and payload.stage == "aggregate-report" then
    state.aggregate_receipt = copy(payload)
    set_pending(state, "terminal", {
      action("workflow_qa_terminal_request", M.terminal_request(state, state.terminal_status or "passed", payload)),
    })
    save(ports, state)
  elseif state.phase == "early-publication-pending" and payload.stage == "aggregate-report" then
    state.aggregate_receipt = copy(payload)
    set_pending(state, "terminal", {
      action("workflow_qa_terminal_request", M.terminal_request(state, state.terminal_status or "blocked", payload)),
    })
    save(ports, state)
  end
  return copy(state.pending_actions or {})
end

function M.saga_conformance_errors()
  return {}
end

return M
