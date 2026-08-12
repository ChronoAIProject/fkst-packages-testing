local strings = require("contract.strings")
local util = require("testing_ai.module_ai_util")

local M = {}

M.schemas = {
  request = "testing-runner.ai-design-loop.request.v1",
  artifact_reference = "testing-runner.ai-design-loop.artifact-reference.v1",
  seed_cases = "testing-runner.ai-seed-cases.v1",
  deterministic_cases = "testing-runner.deterministic-test-cases.v1",
  coverage_scope = "testing-runner.coverage-scope.v1",
  coverage_matrix = "testing-runner.coverage-matrix.v1",
  reviewer_findings = "testing-runner.reviewer-findings.v1",
  patch = "testing-runner.supplementation-patch.v1",
  round_plan = "testing-runner.ai-design-round-plan.v1",
  state = "testing-runner.ai-design-loop-state.v1",
  closure = "testing-runner.ai-design-closure.v1",
  residual_risk = "testing-runner.residual-risk.v1",
}

local max_string = 512
local max_id = 180
local max_cases = 32
local max_actions = 64
local max_subjects = 128
local max_rounds = 8
local max_operations = 32

local subject_kinds = {
  requirement = true,
  ["repository-signal"] = true,
  module = true,
}

local priorities = { P0 = true, P1 = true, P2 = true }
local coverage_statuses = {
  covered = true,
  ["intentionally-excluded"] = true,
  blocked = true,
  duplicate = true,
  ["not-executed-risk"] = true,
  ["missing-evidence"] = true,
}

local operation_kinds = {
  ["add-case"] = true,
  ["revise-case"] = true,
  ["remove-duplicate"] = true,
  ["downgrade-case"] = true,
  ["request-evidence"] = true,
  ["set-coverage"] = true,
}

local function fail(classification, message)
  error("testing-runner: ai-design-loop-" .. classification .. ": " .. message)
end

local function bounded(value, limit)
  return util.bounded_string(value, limit or max_string)
end

local function dense(value, limit)
  return util.dense_list(value, limit)
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function stable(value)
  return util.stable_digest_seed(value)
end

function M.document_digest(value)
  return "design-" .. strings.decimal_checksum(stable(value))
end

local function safe_pointer(value)
  return bounded(value, 4096) and strings.is_path_safe_key(value, 4096) and value:sub(1, 14) == ".testing/runs/"
end

local function validate_reference(value, field)
  if type(value) ~= "table" then fail("malformed-reference", field .. " must be a table") end
  util.validate_fields(value, { artifact_pointer = true, artifact_digest = true }, field)
  if not safe_pointer(value.artifact_pointer) then fail("malformed-reference", field .. ".artifact_pointer must be safe") end
  if not bounded(value.artifact_digest, max_id) then fail("malformed-reference", field .. ".artifact_digest must be bounded") end
  return value
end

function M.validate_artifact_reference(value)
  return validate_reference(value, "artifact_reference")
end

local function validate_document(reference, document, schema, field)
  validate_reference(reference, field .. "_ref")
  if type(document) ~= "table" or document.schema ~= schema then fail("malformed-document", field .. " schema is invalid") end
  if M.document_digest(document) ~= reference.artifact_digest then fail("digest-mismatch", field .. " digest differs") end
  return document
end

local function validate_action(value)
  if type(value) ~= "table" then fail("malformed-case", "action must be a table") end
  util.validate_fields(value, {
    action = true,
    target = true,
    expected = true,
    target_module_id = true,
    evidence_pointer = true,
  }, "ai design action")
  if not bounded(value.action, 80) or not bounded(value.target) or not bounded(value.expected) then
    fail("malformed-case", "action fields are required")
  end
  if value.target_module_id ~= nil and not bounded(value.target_module_id, max_id) then fail("malformed-case", "target_module_id is invalid") end
  if value.evidence_pointer ~= nil and not safe_pointer(value.evidence_pointer) then fail("malformed-case", "action evidence pointer is unsafe") end
end

local function validate_case(value)
  if type(value) ~= "table" then fail("malformed-case", "case must be a table") end
  util.validate_fields(value, {
    id = true,
    module_id = true,
    priority = true,
    title = true,
    objective = true,
    case_kind = true,
    actions = true,
    expected_observable = true,
    coverage_subject_ids = true,
    provenance = true,
    review_status = true,
    reason = true,
    duplicate_of = true,
  }, "ai design case")
  if not bounded(value.id, max_id) or not bounded(value.module_id, max_id) or priorities[value.priority] ~= true
    or not bounded(value.title) or not bounded(value.objective) or not bounded(value.case_kind, 80)
    or not bounded(value.expected_observable) then
    fail("malformed-case", "case identity and observable fields are required")
  end
  if not dense(value.actions, 8) or #value.actions == 0 then fail("malformed-case", "actions must be bounded") end
  for _, action in ipairs(value.actions) do validate_action(action) end
  if not dense(value.coverage_subject_ids, 32) or #value.coverage_subject_ids == 0 then
    fail("malformed-case", "coverage_subject_ids must be bounded")
  end
  for _, subject_id in ipairs(value.coverage_subject_ids) do
    if not bounded(subject_id, max_id) then fail("malformed-case", "coverage subject id is invalid") end
  end
  if type(value.provenance) ~= "table" then fail("malformed-case", "provenance is required") end
  util.validate_fields(value.provenance, { origin = true, source_pointer = true, round = true }, "ai design provenance")
  if not bounded(value.provenance.origin, 80) or not safe_pointer(value.provenance.source_pointer) then
    fail("malformed-case", "provenance must be pointer based")
  end
  if value.review_status ~= nil and value.review_status ~= "executable" and value.review_status ~= "blocked"
    and value.review_status ~= "not-executed-risk" and value.review_status ~= "duplicate" then
    fail("malformed-case", "review_status is invalid")
  end
end

local function validate_case_document(value, schema, field, limit)
  if type(value) ~= "table" or value.schema ~= schema then fail("malformed-document", field .. " schema is invalid") end
  util.validate_fields(value, { schema = true, cases = true }, field)
  if not dense(value.cases, limit or max_cases) then fail("malformed-document", field .. ".cases must be bounded") end
  for _, item in ipairs(value.cases) do validate_case(item) end
  return value
end


function M.validate_seed_cases(value)
  return validate_case_document(value, M.schemas.seed_cases, "seed cases")
end

function M.validate_deterministic_cases(value)
  return validate_case_document(value, M.schemas.deterministic_cases, "deterministic cases")
end

local function validate_scope(value)
  if type(value) ~= "table" or value.schema ~= M.schemas.coverage_scope then fail("malformed-scope", "coverage scope schema is invalid") end
  util.validate_fields(value, { schema = true, subjects = true }, "coverage scope")
  if not dense(value.subjects, max_subjects) or #value.subjects == 0 then fail("malformed-scope", "subjects must be bounded") end
  local seen = {}
  for _, subject in ipairs(value.subjects) do
    if type(subject) ~= "table" then fail("malformed-scope", "subject must be a table") end
    util.validate_fields(subject, { id = true, kind = true, priority = true, evidence_pointer = true }, "coverage subject")
    if not bounded(subject.id, max_id) or seen[subject.id] or subject_kinds[subject.kind] ~= true
      or priorities[subject.priority] ~= true or not safe_pointer(subject.evidence_pointer) then
      fail("malformed-scope", "subject identity is invalid")
    end
    seen[subject.id] = true
  end
  return value
end

function M.validate_coverage_scope(value)
  return validate_scope(value)
end

function M.validate_request(value)
  if type(value) ~= "table" then fail("malformed-request", "request must be a table") end
  util.validate_fields(value, {
    schema = true,
    artifact_root = true,
    seed_cases_ref = true,
    coverage_scope_ref = true,
    deterministic_cases_ref = true,
    max_rounds = true,
    case_budget = true,
    action_budget = true,
    trace_id = true,
    dedup_key = true,
  }, "ai design request")
  if value.schema ~= M.schemas.request then fail("malformed-request", "request schema is invalid") end
  if not strings.is_artifact_root(value.artifact_root, 4096) then fail("malformed-request", "artifact_root must be safe") end
  validate_reference(value.seed_cases_ref, "seed_cases_ref")
  validate_reference(value.coverage_scope_ref, "coverage_scope_ref")
  validate_reference(value.deterministic_cases_ref, "deterministic_cases_ref")
  if type(value.max_rounds) ~= "number" or value.max_rounds < 1 or value.max_rounds > max_rounds or math.floor(value.max_rounds) ~= value.max_rounds then
    fail("malformed-request", "max_rounds must be an integer from 1 to 8")
  end
  if type(value.case_budget) ~= "number" or value.case_budget < 1 or value.case_budget > max_cases or math.floor(value.case_budget) ~= value.case_budget then
    fail("malformed-request", "case_budget is invalid")
  end
  if type(value.action_budget) ~= "number" or value.action_budget < 1 or value.action_budget > max_actions or math.floor(value.action_budget) ~= value.action_budget then
    fail("malformed-request", "action_budget is invalid")
  end
  if not bounded(value.trace_id, max_id) or not bounded(value.dedup_key, max_id) then fail("malformed-request", "trace and dedup identity are required") end
  return value
end

function M.validate_authority_fields(value)
  if type(value) ~= "table" then fail("malformed-transport", "transport must be a table") end
  local cdp = type(value.cdp_execution) == "table" and value.cdp_execution or nil
  if cdp ~= nil and (cdp.ai_design_loop_request ~= nil or cdp.ai_design_loop_state_ref ~= nil) then
    fail("malformed-transport", "reviewed design fields must be top-level")
  end
  if value.ai_design_loop_request ~= nil and value.ai_design_loop_state_ref ~= nil then
    fail("ambiguous-transport", "design request and state reference cannot coexist")
  end
  if value.ai_design_loop_request ~= nil then M.validate_request(value.ai_design_loop_request) end
  if value.ai_design_loop_state_ref ~= nil then M.validate_artifact_reference(value.ai_design_loop_state_ref) end
  return value
end

function M.copy_artifact_reference(value)
  if value == nil then return nil end
  M.validate_artifact_reference(value)
  return {
    artifact_pointer = value.artifact_pointer,
    artifact_digest = value.artifact_digest,
  }
end

function M.paths(root)
  if not strings.is_artifact_root(root, 4096) then fail("malformed-request", "artifact root is unsafe") end
  return {
    coverage_matrix = root .. "/coverage-matrix.json",
    reviewer_findings = root .. "/reviewer-findings.json",
    supplementation_patch = root .. "/supplementation-patch.json",
    round_plan = root .. "/ai-design-round-plan.json",
    state = root .. "/ai-design-loop-state.json",
    closure = root .. "/ai-design-closure.json",
    residual_risk = root .. "/residual-risk.json",
  }
end

local function merge_cases(deterministic, seeds, budget)
  local cases, index, action_count = {}, {}, 0
  local function add(item)
    validate_case(item)
    local existing = index[item.id]
    if existing ~= nil then
      if M.document_digest(existing) ~= M.document_digest(item) then fail("case-conflict", "case id has conflicting definitions") end
      return
    end
    if #cases >= budget then fail("budget-exceeded", "case budget exceeded") end
    action_count = action_count + #item.actions
    cases[#cases + 1] = copy(item)
    index[item.id] = cases[#cases]
  end
  for _, item in ipairs(deterministic.cases) do add(item) end
  for _, item in ipairs(seeds.cases) do add(item) end
  return cases, index, action_count
end

local function coverage_matrix(state)
  local entries = {}
  local case_ids_by_subject = {}
  local blocked_by_subject = {}
  local risk_by_subject = {}
  for _, item in ipairs(state.cases) do
    if item.review_status == "blocked" or item.review_status == "not-executed-risk" then
      local target = item.review_status == "blocked" and blocked_by_subject or risk_by_subject
      for _, subject_id in ipairs(item.coverage_subject_ids) do target[subject_id] = true end
    elseif item.review_status ~= "duplicate" then
      for _, subject_id in ipairs(item.coverage_subject_ids) do
        case_ids_by_subject[subject_id] = case_ids_by_subject[subject_id] or {}
        table.insert(case_ids_by_subject[subject_id], item.id)
      end
    end
  end
  for _, subject in ipairs(state.subjects) do
    local override = state.coverage_overrides[subject.id]
    local case_ids = case_ids_by_subject[subject.id] or {}
    local status = #case_ids > 0 and "covered" or "missing-evidence"
    local rationale = #case_ids > 0 and "Evidence-backed case coverage exists." or "No evidence-backed case covers this subject."
    if #case_ids == 0 and blocked_by_subject[subject.id] then
      status = "blocked"
      rationale = "All evidence-backed cases for this subject are blocked."
    elseif #case_ids == 0 and risk_by_subject[subject.id] then
      status = "not-executed-risk"
      rationale = "All evidence-backed cases for this subject are not executed due to risk."
    end
    if override ~= nil then
      status = override.status
      rationale = override.rationale
    end
    entries[#entries + 1] = {
      subject_id = subject.id,
      subject_kind = subject.kind,
      priority = subject.priority,
      status = status,
      rationale = rationale,
      case_ids = copy(case_ids),
      evidence_pointer = subject.evidence_pointer,
    }
  end
  return {
    schema = M.schemas.coverage_matrix,
    round = state.round,
    entries = entries,
    entry_count = #entries,
  }
end

local function closure_for(state, matrix, forced)
  local unresolved, high_priority = {}, 0
  for _, entry in ipairs(matrix.entries) do
    if entry.status ~= "covered" and entry.status ~= "intentionally-excluded" and entry.status ~= "duplicate" then
      unresolved[#unresolved + 1] = entry
      if entry.priority == "P0" or entry.priority == "P1" then high_priority = high_priority + 1 end
    end
  end
  local status
  if #unresolved == 0 then status = "reviewed-complete"
  elseif forced == "accept-residual-risk" then status = "residual-risk"
  elseif forced == "blocked" then status = "blocked"
  elseif state.round >= state.max_rounds then status = "round-limit"
  else return nil, nil end
  local closure = {
    schema = M.schemas.closure,
    status = status,
    round_count = state.round,
    final_round_digest = state.current_round_digest,
    coverage_matrix_pointer = state.paths.coverage_matrix,
    coverage_matrix_digest = M.document_digest(matrix),
    unresolved_count = #unresolved,
    high_priority_unresolved_count = high_priority,
    trace_id = state.trace_id,
    dedup_key = state.dedup_key,
  }
  local residual = nil
  if #unresolved > 0 then
    residual = {
      schema = M.schemas.residual_risk,
      status = status,
      round = state.round,
      unresolved = copy(unresolved),
      unresolved_count = #unresolved,
      high_priority_unresolved_count = high_priority,
      coverage_matrix_pointer = state.paths.coverage_matrix,
      coverage_matrix_digest = closure.coverage_matrix_digest,
    }
    closure.residual_risk_pointer = state.paths.residual_risk
    closure.residual_risk_digest = M.document_digest(residual)
  end
  return closure, residual
end

local function artifacts_for(state, patch, findings, forced)
  local matrix = coverage_matrix(state)
  local round_plan = {
    schema = M.schemas.round_plan,
    round = state.round,
    case_ids = {},
    case_count = #state.cases,
    action_count = state.action_count,
    coverage_matrix_pointer = state.paths.coverage_matrix,
    coverage_matrix_digest = M.document_digest(matrix),
    previous_round_digest = state.previous_round_digest,
  }
  for _, item in ipairs(state.cases) do round_plan.case_ids[#round_plan.case_ids + 1] = item.id end
  round_plan.round_digest = M.document_digest(round_plan)
  state.current_round_digest = round_plan.round_digest
  local closure, residual = closure_for(state, matrix, forced)
  return {
    coverage_matrix = matrix,
    reviewer_findings = findings,
    supplementation_patch = patch,
    round_plan = round_plan,
    closure = closure,
    residual_risk = residual,
    references = {
      coverage_matrix = { artifact_pointer = state.paths.coverage_matrix, artifact_digest = M.document_digest(matrix) },
      round_plan = { artifact_pointer = state.paths.round_plan, artifact_digest = M.document_digest(round_plan) },
      closure = closure and { artifact_pointer = state.paths.closure, artifact_digest = M.document_digest(closure) } or nil,
      residual_risk = residual and { artifact_pointer = state.paths.residual_risk, artifact_digest = M.document_digest(residual) } or nil,
    },
  }
end

function M.start(request, documents)
  M.validate_request(request)
  documents = documents or {}
  local seeds = validate_document(request.seed_cases_ref, documents.seed_cases, M.schemas.seed_cases, "seed_cases")
  local deterministic = validate_document(request.deterministic_cases_ref, documents.deterministic_cases, M.schemas.deterministic_cases, "deterministic_cases")
  local scope = validate_document(request.coverage_scope_ref, documents.coverage_scope, M.schemas.coverage_scope, "coverage_scope")
  validate_case_document(seeds, M.schemas.seed_cases, "seed cases")
  validate_case_document(deterministic, M.schemas.deterministic_cases, "deterministic cases")
  validate_scope(scope)
  local cases, _, action_count = merge_cases(deterministic, seeds, request.case_budget)
  if action_count > request.action_budget then fail("budget-exceeded", "action budget exceeded") end
  local state = {
    schema = M.schemas.state,
    artifact_root = request.artifact_root,
    paths = M.paths(request.artifact_root),
    round = 1,
    max_rounds = request.max_rounds,
    case_budget = request.case_budget,
    action_budget = request.action_budget,
    action_count = action_count,
    cases = cases,
    subjects = copy(scope.subjects),
    coverage_overrides = {},
    applied_patch_digests = {},
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    source_references = {
      seed_cases = copy(request.seed_cases_ref),
      coverage_scope = copy(request.coverage_scope_ref),
      deterministic_cases = copy(request.deterministic_cases_ref),
    },
  }
  local artifacts = artifacts_for(state)
  state.current_artifacts = copy(artifacts)
  return state, artifacts
end

local function find_case(state, case_id)
  for _, item in ipairs(state.cases) do if item.id == case_id then return item end end
  return nil
end

local function validate_patch(value)
  if type(value) ~= "table" or value.schema ~= M.schemas.patch then fail("malformed-patch", "patch schema is invalid") end
  util.validate_fields(value, {
    schema = true,
    round = true,
    base_round_digest = true,
    operations = true,
    findings = true,
    finalize = true,
  }, "supplementation patch")
  if type(value.round) ~= "number" or math.floor(value.round) ~= value.round or not bounded(value.base_round_digest, max_id) then
    fail("malformed-patch", "round identity is invalid")
  end
  if not dense(value.operations, max_operations) then fail("malformed-patch", "operations must be bounded") end
  if value.finalize ~= nil and value.finalize ~= "accept-residual-risk" and value.finalize ~= "blocked" then fail("malformed-patch", "finalize is invalid") end
  for _, operation in ipairs(value.operations) do
    if type(operation) ~= "table" or operation_kinds[operation.operation] ~= true then fail("malformed-patch", "operation kind is invalid") end
    util.validate_fields(operation, {
      operation = true,
      case = true,
      case_id = true,
      objective = true,
      expected_observable = true,
      actions = true,
      duplicate_of = true,
      reason = true,
      status = true,
      subject_id = true,
      rationale = true,
    }, "supplementation operation")
    if operation.operation == "add-case" then
      validate_case(operation.case)
    elseif operation.operation == "revise-case" then
      if not bounded(operation.case_id, max_id) or (operation.objective == nil and operation.expected_observable == nil and operation.actions == nil) then
        fail("malformed-patch", "revision target and change are required")
      end
      if operation.objective ~= nil and not bounded(operation.objective) then fail("malformed-patch", "objective is invalid") end
      if operation.expected_observable ~= nil and not bounded(operation.expected_observable) then fail("malformed-patch", "expected observable is invalid") end
      if operation.actions ~= nil then
        if not dense(operation.actions, 8) or #operation.actions == 0 then fail("malformed-patch", "revised actions are invalid") end
        for _, action in ipairs(operation.actions) do validate_action(action) end
      end
    elseif operation.operation == "remove-duplicate" then
      if not bounded(operation.case_id, max_id) or not bounded(operation.duplicate_of, max_id) then fail("malformed-patch", "duplicate identities are required") end
    elseif operation.operation == "downgrade-case" then
      if not bounded(operation.case_id, max_id) or (operation.status ~= "blocked" and operation.status ~= "not-executed-risk")
        or not bounded(operation.reason) then fail("malformed-patch", "downgrade decision is invalid") end
    else
      local status = operation.operation == "request-evidence" and "missing-evidence" or operation.status
      if not bounded(operation.subject_id, max_id) or coverage_statuses[status] ~= true
        or not bounded(operation.rationale or operation.reason) then fail("malformed-patch", "coverage decision is invalid") end
    end
  end
  if value.findings ~= nil then M.validate_reviewer_findings(value.findings) end
  return value
end


function M.validate_patch(value)
  return validate_patch(value)
end

local function validate_findings(value)
  if type(value) ~= "table" or value.schema ~= M.schemas.reviewer_findings then fail("malformed-findings", "reviewer findings schema is invalid") end
  util.validate_fields(value, { schema = true, findings = true }, "reviewer findings")
  if not dense(value.findings, max_subjects) then fail("malformed-findings", "findings must be bounded") end
  local decisions = {}
  for _, finding in ipairs(value.findings) do
    if type(finding) ~= "table" then fail("malformed-findings", "finding must be a table") end
    util.validate_fields(finding, { subject_id = true, status = true, rationale = true, evidence_pointer = true }, "reviewer finding")
    if not bounded(finding.subject_id, max_id) or coverage_statuses[finding.status] ~= true or not bounded(finding.rationale) then
      fail("malformed-findings", "finding fields are invalid")
    end
    if finding.evidence_pointer ~= nil and not safe_pointer(finding.evidence_pointer) then fail("malformed-findings", "finding evidence pointer is unsafe") end
    if decisions[finding.subject_id] ~= nil and decisions[finding.subject_id] ~= finding.status then
      fail("conflicting-findings", "reviewers returned conflicting coverage states")
    end
    decisions[finding.subject_id] = finding.status
  end
  return value
end

function M.validate_reviewer_findings(value)
  return validate_findings(value)
end

local function apply_findings(state, value)
  if value == nil then return end
  validate_findings(value)
  for _, finding in ipairs(value.findings) do
    state.coverage_overrides[finding.subject_id] = { status = finding.status, rationale = finding.rationale }
  end
end

local function apply_operation(state, operation)
  if type(operation) ~= "table" or operation_kinds[operation.operation] ~= true then fail("malformed-patch", "operation kind is invalid") end
  if operation.operation == "add-case" then
    validate_case(operation.case)
    if find_case(state, operation.case.id) ~= nil then fail("case-conflict", "added case id already exists") end
    if #state.cases >= state.case_budget then fail("budget-exceeded", "case budget exceeded") end
    state.action_count = state.action_count + #operation.case.actions
    if state.action_count > state.action_budget then fail("budget-exceeded", "action budget exceeded") end
    state.cases[#state.cases + 1] = copy(operation.case)
    return
  end
  if not bounded(operation.case_id or operation.subject_id, max_id) then fail("malformed-patch", "operation target is required") end
  if operation.operation == "set-coverage" or operation.operation == "request-evidence" then
    local status = operation.operation == "request-evidence" and "missing-evidence" or operation.status
    if coverage_statuses[status] ~= true or not bounded(operation.rationale or operation.reason) then fail("malformed-patch", "coverage decision is invalid") end
    state.coverage_overrides[operation.subject_id] = { status = status, rationale = operation.rationale or operation.reason }
    return
  end
  local item = find_case(state, operation.case_id)
  if item == nil then fail("malformed-patch", "case target does not exist") end
  if operation.operation == "revise-case" then
    if operation.objective ~= nil then
      if not bounded(operation.objective) then fail("malformed-patch", "objective is invalid") end
      item.objective = operation.objective
    end
    if operation.expected_observable ~= nil then
      if not bounded(operation.expected_observable) then fail("malformed-patch", "expected observable is invalid") end
      item.expected_observable = operation.expected_observable
    end
    if operation.actions ~= nil then
      if not dense(operation.actions, 8) or #operation.actions == 0 then fail("malformed-patch", "revised actions are invalid") end
      for _, action in ipairs(operation.actions) do validate_action(action) end
      state.action_count = state.action_count - #item.actions + #operation.actions
      if state.action_count > state.action_budget then fail("budget-exceeded", "action budget exceeded") end
      item.actions = copy(operation.actions)
    end
  elseif operation.operation == "remove-duplicate" then
    if not bounded(operation.duplicate_of, max_id) or find_case(state, operation.duplicate_of) == nil then fail("malformed-patch", "duplicate target is invalid") end
    item.review_status = "duplicate"
    item.duplicate_of = operation.duplicate_of
    item.reason = bounded(operation.reason) and operation.reason or "Semantic duplicate removed by reviewer patch."
  elseif operation.operation == "downgrade-case" then
    if operation.status ~= "blocked" and operation.status ~= "not-executed-risk" then fail("malformed-patch", "downgrade status is invalid") end
    if not bounded(operation.reason) then fail("malformed-patch", "downgrade reason is required") end
    item.review_status = operation.status
    item.reason = operation.reason
  end
end

function M.apply_round(state, patch)
  M.validate_state(state)
  validate_patch(patch)
  local patch_digest = M.document_digest(patch)
  if state.applied_patch_digests[patch_digest] == true then return copy(state), copy(state.current_artifacts), true end
  if state.current_artifacts and state.current_artifacts.closure ~= nil then fail("finalized", "final closure is immutable") end
  if patch.round ~= state.round or patch.base_round_digest ~= state.current_round_digest then fail("stale-patch", "patch is not bound to the current round") end
  local next_state = copy(state)
  apply_findings(next_state, patch.findings)
  for _, operation in ipairs(patch.operations) do apply_operation(next_state, operation) end
  next_state.applied_patch_digests[patch_digest] = true
  next_state.previous_round_digest = state.current_round_digest
  next_state.round = state.round + 1
  if next_state.round > next_state.max_rounds then next_state.round = next_state.max_rounds end
  local findings = patch.findings
  local artifacts = artifacts_for(next_state, copy(patch), copy(findings), patch.finalize)
  next_state.current_artifacts = copy(artifacts)
  return next_state, artifacts, false
end

function M.validate_coverage_matrix(value)
  if type(value) ~= "table" or value.schema ~= M.schemas.coverage_matrix then fail("malformed-coverage", "coverage matrix schema is invalid") end
  util.validate_fields(value, { schema = true, round = true, entries = true, entry_count = true }, "coverage matrix")
  if type(value.round) ~= "number" or math.floor(value.round) ~= value.round or not dense(value.entries, max_subjects)
    or value.entry_count ~= #value.entries then fail("malformed-coverage", "coverage matrix identity is invalid") end
  for _, entry in ipairs(value.entries) do
    if type(entry) ~= "table" then fail("malformed-coverage", "coverage entry must be a table") end
    util.validate_fields(entry, { subject_id = true, subject_kind = true, priority = true, status = true, rationale = true, case_ids = true, evidence_pointer = true }, "coverage entry")
    if not bounded(entry.subject_id, max_id) or subject_kinds[entry.subject_kind] ~= true or priorities[entry.priority] ~= true
      or coverage_statuses[entry.status] ~= true or not bounded(entry.rationale) or not dense(entry.case_ids, max_cases)
      or not safe_pointer(entry.evidence_pointer) then fail("malformed-coverage", "coverage entry is invalid") end
  end
  return value
end

function M.validate_round_plan(value)
  if type(value) ~= "table" or value.schema ~= M.schemas.round_plan then fail("malformed-round-plan", "round plan schema is invalid") end
  util.validate_fields(value, { schema = true, round = true, case_ids = true, case_count = true, action_count = true, coverage_matrix_pointer = true, coverage_matrix_digest = true, previous_round_digest = true, round_digest = true }, "round plan")
  if type(value.round) ~= "number" or math.floor(value.round) ~= value.round or not dense(value.case_ids, max_cases)
    or value.case_count ~= #value.case_ids or type(value.action_count) ~= "number" or not safe_pointer(value.coverage_matrix_pointer)
    or not bounded(value.coverage_matrix_digest, max_id) or not bounded(value.round_digest, max_id) then fail("malformed-round-plan", "round plan is invalid") end
  return value
end

function M.validate_closure(value)
  if type(value) ~= "table" or value.schema ~= M.schemas.closure then fail("malformed-closure", "closure schema is invalid") end
  util.validate_fields(value, { schema = true, status = true, round_count = true, final_round_digest = true, coverage_matrix_pointer = true, coverage_matrix_digest = true, unresolved_count = true, high_priority_unresolved_count = true, trace_id = true, dedup_key = true, residual_risk_pointer = true, residual_risk_digest = true }, "design closure")
  local statuses = { ["reviewed-complete"] = true, ["residual-risk"] = true, blocked = true, ["round-limit"] = true }
  if statuses[value.status] ~= true or type(value.round_count) ~= "number" or not bounded(value.final_round_digest, max_id)
    or not safe_pointer(value.coverage_matrix_pointer) or not bounded(value.coverage_matrix_digest, max_id)
    or type(value.unresolved_count) ~= "number" or type(value.high_priority_unresolved_count) ~= "number"
    or not bounded(value.trace_id, max_id) or not bounded(value.dedup_key, max_id) then fail("malformed-closure", "closure is invalid") end
  if value.status ~= "reviewed-complete" and (not safe_pointer(value.residual_risk_pointer) or not bounded(value.residual_risk_digest, max_id)) then
    fail("malformed-closure", "non-complete closure requires residual risk")
  end
  return value
end

function M.validate_residual_risk(value)
  if type(value) ~= "table" or value.schema ~= M.schemas.residual_risk then fail("malformed-residual-risk", "residual risk schema is invalid") end
  util.validate_fields(value, { schema = true, status = true, round = true, unresolved = true, unresolved_count = true, high_priority_unresolved_count = true, coverage_matrix_pointer = true, coverage_matrix_digest = true }, "residual risk")
  if not dense(value.unresolved, max_subjects) or value.unresolved_count ~= #value.unresolved or value.unresolved_count == 0
    or not safe_pointer(value.coverage_matrix_pointer) or not bounded(value.coverage_matrix_digest, max_id) then fail("malformed-residual-risk", "residual risk is invalid") end
  return value
end

function M.validate_state(value)
  if type(value) ~= "table" or value.schema ~= M.schemas.state then fail("malformed-state", "state schema is invalid") end
  if not strings.is_artifact_root(value.artifact_root, 4096) or type(value.paths) ~= "table"
    or type(value.round) ~= "number" or type(value.max_rounds) ~= "number" or value.round < 1 or value.round > value.max_rounds
    or not dense(value.cases, max_cases) or not dense(value.subjects, max_subjects)
    or type(value.applied_patch_digests) ~= "table" or not bounded(value.trace_id, max_id) or not bounded(value.dedup_key, max_id) then
    fail("malformed-state", "state fields are invalid")
  end
  for _, item in ipairs(value.cases) do validate_case(item) end
  validate_scope({ schema = M.schemas.coverage_scope, subjects = value.subjects })
  if type(value.current_artifacts) == "table" then
    M.validate_coverage_matrix(value.current_artifacts.coverage_matrix)
    M.validate_round_plan(value.current_artifacts.round_plan)
    if value.current_artifacts.closure ~= nil then M.validate_closure(value.current_artifacts.closure) end
    if value.current_artifacts.residual_risk ~= nil then M.validate_residual_risk(value.current_artifacts.residual_risk) end
  end
  return value
end

function M.merge_into_plan(plan_modules, state)
  if type(plan_modules) ~= "table" or type(state) ~= "table" or state.schema ~= M.schemas.state
    or type(state.current_artifacts) ~= "table" or state.current_artifacts.closure == nil then
    fail("malformed-state", "plan modules and design state are required")
  end
  local module_index, seen = {}, {}
  for _, module in ipairs(plan_modules) do
    module_index[module.id] = module
    module.cases = module.cases or {}
    for _, item in ipairs(module.cases) do seen[item.id] = true end
  end
  local merged = 0
  for _, item in ipairs(state.cases) do
    if item.review_status ~= "duplicate" and item.review_status ~= "blocked" and item.review_status ~= "not-executed-risk"
      and not seen[item.id] and module_index[item.module_id] ~= nil then
      local target = module_index[item.module_id]
      target.cases[#target.cases + 1] = {
        id = item.id,
        module_id = item.module_id,
        priority = item.priority,
        title = item.title,
        objective = item.objective,
        case_kind = item.case_kind,
        actions = copy(item.actions),
        expected_observable = item.expected_observable,
        evidence_pointer = item.provenance.source_pointer,
        evidence_pointers = { item.provenance.source_pointer },
        case_origin = item.provenance.origin,
        review_status = "executable",
      }
      seen[item.id] = true
      merged = merged + 1
    end
  end
  return merged
end

return M
