local canonical_results = require("canonical_results")
local structured_contract = require("contract.structured_execution")
local results_contract = require("contract.testing_results")
local results_compat = require("contract.testing_results_compat")
local local_runtime = require("testing_runtime.qa_publication")

local M = {}

local function bounded(value, maximum)
  if type(value) ~= "string" or value == "" or #value > maximum then return false end
  return value:find("[%z\1-\31]") == nil
end

local function digest(value)
  if not bounded(value, 64) or #value ~= 64 then return false end
  return value:match("^[0-9a-f]+$") ~= nil
end

local function safe_pointer(value)
  if not bounded(value, 4096) or value:sub(1, 14) ~= ".testing/runs/" then return false end
  return value:find("..", 1, true) == nil
end

local function under_root(value, root)
  return safe_pointer(value) and value:sub(1, #root + 1) == root .. "/"
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local cloned = {}
  for field, item in pairs(value) do cloned[field] = copy(item) end
  return cloned
end

local function equal(left, right)
  if left == right then return true end
  if type(left) ~= "table" or type(right) ~= "table" then return false end
  local left_count, right_count = 0, 0
  for key, value in pairs(left) do
    left_count = left_count + 1
    if not equal(value, right[key]) then return false end
  end
  for _, _ in pairs(right) do right_count = right_count + 1 end
  return left_count == right_count
end

local function dense_list(value, maximum)
  if type(value) ~= "table" then return false end
  local entries, last_index = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    entries = entries + 1
    last_index = math.max(last_index, key)
  end
  return entries == last_index and last_index <= maximum
end

local function only_fields(value, allowed, label)
  if type(value) ~= "table" then error("test-publication: defect: " .. label .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then error("test-publication: defect: unsupported " .. label .. " field " .. tostring(key)) end
  end
end

local request_fields = {
  schema = true, publication = true, repository = true, plan_sha256 = true,
  case_results_ref = true, case_results_sha256 = true, issue_drafts_ref = true,
  issue_drafts_sha256 = true, ledger_ref = true, receipt_ref = true,
  case_result_set_ref = true, case_result_set_artifact_sha256 = true,
  evidence_manifest_ref = true, evidence_manifest_artifact_sha256 = true,
  trace_id = true, dedup_key = true,
}

local publication_fields = {
  schema = true, publication_kind = true, channel = true, severity = true, subject = true,
  trace_id = true, dedup_key = true, status = true, job = true, artifact_root = true,
  metadata_path = true, source_ref = true, test_plan_path = true, execution_path = true,
  case_results_path = true, stage_report_path = true, issue_drafts_path = true,
  case_result_set_path = true, case_result_set_artifact_sha256 = true,
  evidence_manifest_path = true, evidence_manifest_artifact_sha256 = true,
  publication_dry_run = true,
}

local canonical_quartet_fields = {
  "case_result_set_ref", "case_result_set_artifact_sha256",
  "evidence_manifest_ref", "evidence_manifest_artifact_sha256",
}

local function validate_publication_canonical_paths(publication)
  local fields = {
    publication.case_result_set_path, publication.case_result_set_artifact_sha256,
    publication.evidence_manifest_path, publication.evidence_manifest_artifact_sha256,
  }
  local present = 0
  for index = 1, 4 do if fields[index] ~= nil then present = present + 1 end end
  if present ~= 0 and present ~= 4 then
    error("test-publication: defect: canonical publication paths and digests must be complete")
  end
  if present == 4 and (publication.job ~= "structured-execution"
    or publication.case_result_set_path ~= publication.artifact_root .. "/case-result-set.json"
    or not digest(publication.case_result_set_artifact_sha256)
    or publication.evidence_manifest_path ~= publication.artifact_root .. "/evidence-manifest.json"
    or not digest(publication.evidence_manifest_artifact_sha256)) then
    error("test-publication: defect: malformed canonical publication artifact group")
  end
end

local function validate_canonical_quartet(request, root)
  local count = 0
  for _, field in ipairs(canonical_quartet_fields) do
    if request[field] ~= nil then count = count + 1 end
  end
  if count ~= 0 and count ~= #canonical_quartet_fields then
    error("test-publication: defect: canonical result quartet must be complete")
  end
  if count ~= 0 and (request.case_result_set_ref ~= root .. "/case-result-set.json"
    or request.evidence_manifest_ref ~= root .. "/evidence-manifest.json"
    or not digest(request.case_result_set_artifact_sha256)
    or not digest(request.evidence_manifest_artifact_sha256)) then
    error("test-publication: defect: malformed canonical result quartet")
  end
  return count ~= 0
end

local function validate_canonical_binding(request, publication)
  local has_canonical = validate_canonical_quartet(request, publication.artifact_root)
  local has_paths = publication.case_result_set_path ~= nil
  if has_canonical ~= has_paths or (has_canonical
    and (request.case_result_set_ref ~= publication.case_result_set_path
      or request.case_result_set_artifact_sha256 ~= publication.case_result_set_artifact_sha256
      or request.evidence_manifest_ref ~= publication.evidence_manifest_path
      or request.evidence_manifest_artifact_sha256 ~= publication.evidence_manifest_artifact_sha256)) then
    error("test-publication: defect: canonical request and publication pointers differ")
  end
  return has_canonical
end

function M.validate_request(request)
  only_fields(request, request_fields, "request")
  if request.schema ~= "test-publication.defect-publication.request.v1" then
    error("test-publication: defect: unknown request schema")
  end
  only_fields(request.repository, { slug = true, commit_sha = true }, "repository")
  if not bounded(request.repository.slug, 180) or request.repository.slug:match("^[%w_.%-]+/[%w_.%-]+$") == nil
    or type(request.repository.commit_sha) ~= "string" or #request.repository.commit_sha ~= 40
    or request.repository.commit_sha:match("^[0-9a-f]+$") == nil then
    error("test-publication: defect: immutable repository identity is required")
  end
  local publication = request.publication
  only_fields(publication, publication_fields, "publication")
  only_fields(publication.source_ref, { kind = true, ref = true }, "publication source_ref")
  validate_publication_canonical_paths(publication)
  local execution_path = publication.job == "structured-execution" and "/execution.json"
    or publication.job == "ai-browser-control" and "/browser-agent-execution.json" or nil
  if publication.schema ~= "test-publication.publication-request.v1"
    or publication.publication_kind ~= "testing-summary" or publication.channel ~= "testing"
    or execution_path == nil or publication.status ~= "failed"
    or not bounded(publication.severity, 40) or not bounded(publication.subject, 240)
    or not safe_pointer(publication.artifact_root)
    or publication.metadata_path ~= publication.artifact_root .. "/metadata.json"
    or publication.test_plan_path ~= publication.artifact_root .. "/test-plan.json"
    or publication.execution_path ~= publication.artifact_root .. execution_path
    or publication.case_results_path ~= publication.artifact_root .. "/case-results.json"
    or not bounded(publication.trace_id, 180) or not bounded(publication.dedup_key, 180)
    or not bounded(publication.source_ref.kind, 80) or not bounded(publication.source_ref.ref, 200)
    or (publication.stage_report_path ~= nil and not under_root(publication.stage_report_path, publication.artifact_root))
    or (publication.issue_drafts_path ~= nil and not under_root(publication.issue_drafts_path, publication.artifact_root))
    or (publication.publication_dry_run ~= nil and publication.publication_dry_run ~= true) then
    error("test-publication: defect: malformed structured publication request")
  end
  if request.case_results_ref ~= publication.case_results_path
    or not under_root(request.issue_drafts_ref, publication.artifact_root)
    or not under_root(request.ledger_ref, publication.artifact_root)
    or not under_root(request.receipt_ref, publication.artifact_root)
    or (publication.issue_drafts_path ~= nil and request.issue_drafts_ref ~= publication.issue_drafts_path)
    or not digest(request.plan_sha256) or not digest(request.case_results_sha256)
    or not digest(request.issue_drafts_sha256) or request.trace_id ~= publication.trace_id
    or not bounded(request.dedup_key, 180) then
    error("test-publication: defect: request binding is invalid")
  end
  validate_canonical_binding(request, publication)
  return request
end

local function load_bound(ports, ref, expected_digest, label)
  local artifact = ports.load_artifact(ref)
  if type(artifact) ~= "table" or artifact.digest ~= expected_digest or type(artifact.value) ~= "table" then
    error("test-publication: defect: " .. label .. " digest mismatch")
  end
  return artifact.value
end

local function validate_issue_drafts(request, ports)
  local root = request.publication.artifact_root
  local drafts = load_bound(ports, request.issue_drafts_ref, request.issue_drafts_sha256, "issue drafts")
  if drafts.schema ~= "test-publication.defect-issue-drafts.v1" or drafts.plan_sha256 ~= request.plan_sha256
    or not dense_list(drafts.cases, 1000) then
    error("test-publication: defect: malformed issue drafts")
  end
  local indexed_drafts = {}
  for _, draft in ipairs(drafts.cases) do
    only_fields(draft, {
      case_id = true, title = true, expected_summary = true, actual_summary = true, evidence_ref = true,
    }, "issue draft")
    if not bounded(draft.case_id, 180) or draft.case_id:match("^[%w._%-]+$") == nil
      or indexed_drafts[draft.case_id] ~= nil or not bounded(draft.title, 180)
      or not bounded(draft.expected_summary, 1000) or not bounded(draft.actual_summary, 1000)
      or not under_root(draft.evidence_ref, root) then
      error("test-publication: defect: unsafe issue draft")
    end
    indexed_drafts[draft.case_id] = draft
  end
  return indexed_drafts
end

local preparation_fields = {
  schema = true, publication = true, repository = true, run_id = true,
  plan_ref = true, plan_sha256 = true, case_results_ref = true,
  case_results_sha256 = true, issue_drafts_ref = true, ledger_ref = true,
  receipt_ref = true, trace_id = true, dedup_key = true,
  case_result_set_ref = true, case_result_set_artifact_sha256 = true,
  evidence_manifest_ref = true, evidence_manifest_artifact_sha256 = true,
}

local function validate_preparation_request(request)
  only_fields(request, preparation_fields, "preparation request")
  if request.schema ~= "test-publication.defect-preparation.request.v1" then
    error("test-publication: defect: unknown preparation schema")
  end
  only_fields(request.repository, { slug = true, commit_sha = true }, "repository")
  if not bounded(request.repository.slug, 180)
    or request.repository.slug:match("^[%w_.%-]+/[%w_.%-]+$") == nil
    or type(request.repository.commit_sha) ~= "string" or #request.repository.commit_sha ~= 40
    or request.repository.commit_sha:match("^[0-9a-f]+$") == nil
    or not bounded(request.run_id, 180) or not digest(request.plan_sha256)
    or not digest(request.case_results_sha256) or not bounded(request.trace_id, 180)
    or not bounded(request.dedup_key, 180) then
    error("test-publication: defect: malformed preparation identity")
  end
  local publication = request.publication
  only_fields(publication, publication_fields, "publication")
  only_fields(publication.source_ref, { kind = true, ref = true }, "publication source_ref")
  validate_publication_canonical_paths(publication)
  local execution_path = publication.job == "structured-execution" and "/execution.json"
    or publication.job == "ai-browser-control" and "/browser-agent-execution.json" or nil
  if publication.schema ~= "test-publication.publication-request.v1"
    or publication.publication_kind ~= "testing-summary" or publication.channel ~= "testing"
    or execution_path == nil or publication.status ~= "failed"
    or not bounded(publication.severity, 40) or not bounded(publication.subject, 240)
    or not safe_pointer(publication.artifact_root)
    or publication.metadata_path ~= publication.artifact_root .. "/metadata.json"
    or publication.test_plan_path ~= request.plan_ref
    or publication.case_results_path ~= request.case_results_ref
    or publication.execution_path ~= publication.artifact_root .. execution_path
    or publication.issue_drafts_path ~= nil
    or publication.trace_id ~= request.trace_id or publication.dedup_key ~= request.dedup_key
    or publication.source_ref.kind ~= "workflow-qa" or publication.source_ref.ref ~= request.run_id
    or publication.publication_dry_run ~= true
    or not under_root(request.plan_ref, publication.artifact_root)
    or not under_root(request.case_results_ref, publication.artifact_root)
    or not under_root(request.issue_drafts_ref, publication.artifact_root)
    or not under_root(request.ledger_ref, publication.artifact_root)
    or not under_root(request.receipt_ref, publication.artifact_root) then
    error("test-publication: defect: malformed preparation binding")
  end
  validate_canonical_binding(request, publication)
  return request
end

M.validate_preparation_request = validate_preparation_request

local function repository_matches_slug(repository, requested)
  local base = "https://github.com/" .. requested.slug
  return type(repository) == "table" and repository.commit_sha == requested.commit_sha
    and (repository.url == base or repository.url == base .. ".git")
end

local function load_verified_plan(request, ports)
  local plan_ref = request.plan_ref or request.publication.test_plan_path
  local plan = load_bound(ports, plan_ref, request.plan_sha256, "test plan")
  local plan_ok = pcall(structured_contract.validate_plan, plan)
  if not plan_ok or not repository_matches_slug(plan.repository, request.repository)
    or plan.trace_id ~= request.trace_id or plan.dedup_key ~= request.dedup_key then
    error("test-publication: defect: verified plan does not belong to the run")
  end
  return plan, plan_ref
end

local function canonical_repository(request, plan, hash)
  return {
    id = request.repository.commit_sha,
    source_ref = {
      kind = results_contract.repository_source_kinds.git,
      ref = plan.repository.url .. "@" .. request.repository.commit_sha,
    },
    source_sha256 = hash(plan.repository.url .. "\n" .. request.repository.commit_sha),
  }
end

local function validated_result_view(request, ports, plan, plan_ref)
  local root = request.publication.artifact_root
  local v1_context = { artifact_root = root, plan_sha256 = request.plan_sha256, plan = plan }
  if request.case_result_set_ref == nil then
    local legacy = load_bound(ports, request.case_results_ref, request.case_results_sha256, "case results")
    results_compat.validate_v1(legacy, v1_context)
    return { canonical=false, cases=legacy.cases }
  end
  if type(ports.sha256_bytes) ~= "function" then
    error("test-publication: defect: canonical results require sha256_bytes")
  end
  local result_set = load_bound(ports, request.case_result_set_ref,
    request.case_result_set_artifact_sha256, "case result set")
  local manifest = load_bound(ports, request.evidence_manifest_ref,
    request.evidence_manifest_artifact_sha256, "evidence manifest")
  if type(result_set.evidence_manifest_ref) ~= "table"
    or result_set.evidence_manifest_ref.kind ~= "artifact"
    or result_set.evidence_manifest_ref.ref ~= request.evidence_manifest_ref then
    error("test-publication: defect: result set manifest reference differs")
  end
  local hash = function(bytes) return ports.sha256_bytes(bytes, root) end
  local run_id = request.run_id or request.publication.source_ref.ref
  local repository = canonical_repository(request, plan, hash)
  local canonical_plan_ref = { kind = "artifact", ref = plan_ref }
  local direct = canonical_results.validate(result_set, manifest, {
    artifact_root=root, run_id=run_id, plan=plan, plan_ref=canonical_plan_ref,
    plan_sha256=request.plan_sha256, repository=repository,
    trace_id=request.trace_id, dedup_key=request.dedup_key,
    evidence_manifest_ref=request.evidence_manifest_ref,
    evidence_manifest_artifact_sha256=request.evidence_manifest_artifact_sha256,
    sha256_bytes=hash,
  })
  local projected = results_compat.project_v1(result_set, manifest, {
    artifact_root = root,
    plan_sha256 = request.plan_sha256,
    plan = plan,
    repository = repository,
    run_id = run_id,
    plan_ref = canonical_plan_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    sha256_bytes = hash,
  })
  local legacy = load_bound(ports, request.case_results_ref, request.case_results_sha256, "case results")
  results_compat.validate_v1(legacy, v1_context)
  if not equal(projected, legacy) then
    error("test-publication: defect: canonical and legacy case results differ")
  end
  return direct
end

local function assertion_names(assertions, failed_only, view)
  local names = {}
  for _, assertion in ipairs(assertions or {}) do
    if not failed_only or canonical_results.assertion_failed(view, assertion) then
      table.insert(names, assertion.type)
    end
  end
  if #names == 0 then return "verified assertions" end
  return table.concat(names, ", ")
end

local function materialize_drafts(request, plan, results)
  local indexed = {}
  for _, result in ipairs(results.cases) do indexed[result.case_id] = result end
  local drafts = {
    schema = "test-publication.defect-issue-drafts.v1",
    plan_sha256 = request.plan_sha256,
    cases = {},
  }
  for _, case in ipairs(plan.cases) do
    local result = indexed[case.case_id]
    if canonical_results.is_product_defect(results, result) then
      local actual_summary = "Observed failed product-defect result; failed assertions: " .. assertion_names(result.assertions, true, results)
      table.insert(drafts.cases, {
        case_id = result.case_id,
        title = (result.case_id:sub(1, 130) .. ": verified " .. result.kind .. " behavior differs"),
        expected_summary = "Expected configured assertions to pass: " .. assertion_names(case.assertions, false),
        actual_summary = actual_summary,
        evidence_ref = result.evidence_ref,
      })
    end
    indexed[case.case_id] = nil
  end
  if next(indexed) ~= nil then error("test-publication: defect: case results contain foreign cases") end
  return drafts
end

function M.prepare_defects(request, ports)
  validate_preparation_request(request)
  local plan, plan_ref = load_verified_plan(request, ports)
  local results = validated_result_view(request, ports, plan, plan_ref)
  local drafts = materialize_drafts(request, plan, results)
  local existing = ports.load_artifact(request.issue_drafts_ref)
  local replayed = existing ~= nil
  if existing == nil then
    if ports.write_artifact(request.issue_drafts_ref, drafts) ~= true then
      error("test-publication: defect: issue draft write failed")
    end
    existing = ports.load_artifact(request.issue_drafts_ref)
  end
  if type(existing) ~= "table" or not digest(existing.digest)
    or type(existing.value) ~= "table" or not equal(existing.value, drafts) then
    error("test-publication: defect: persisted issue drafts differ from deterministic materialization")
  end
  local publication = copy(request.publication)
  publication.issue_drafts_path = request.issue_drafts_ref
  local defect_request = {
    schema = "test-publication.defect-publication.request.v1",
    publication = publication,
    repository = copy(request.repository),
    plan_sha256 = request.plan_sha256,
    case_results_ref = request.case_results_ref,
    case_results_sha256 = request.case_results_sha256,
    issue_drafts_ref = request.issue_drafts_ref,
    issue_drafts_sha256 = existing.digest,
    ledger_ref = request.ledger_ref,
    receipt_ref = request.receipt_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  for _, field in ipairs(canonical_quartet_fields) do
    if request[field] ~= nil then defect_request[field] = request[field] end
  end
  M.validate_request(defect_request)
  return {
    replayed = replayed,
    issue_drafts_ref = request.issue_drafts_ref,
    issue_drafts_sha256 = existing.digest,
    defect_request = defect_request,
  }
end

local function issue_dedup_key(request, case_id)
  local value = table.concat({
    "qa-product-defect", request.repository.slug, request.repository.commit_sha,
    request.plan_sha256, case_id,
  }, "/")
  if not bounded(value, 512) then error("test-publication: defect: issue dedup identity is too large") end
  return value
end

local function issue_body(request, result, draft)
  return table.concat({
    "## Verified QA product defect",
    "",
    "- Source commit: `" .. request.repository.commit_sha .. "`",
    "- Test-plan digest: `" .. request.plan_sha256 .. "`",
    "- Case ID: `" .. result.case_id .. "`",
    "- Classification: `product-defect`",
    "- Expected: " .. draft.expected_summary,
    "- Actual: " .. draft.actual_summary,
    "- Evidence: `" .. draft.evidence_ref .. "`",
    "",
    '<!-- fkst:qa-product-defect:v1 case="' .. result.case_id .. '" -->',
  }, "\n")
end

local function issue_request(request, result, draft)
  local dedup_key = issue_dedup_key(request, result.case_id)
  return {
    schema = "github-proxy.issue-create.v1",
    repo = request.repository.slug,
    title = "[QA] " .. draft.title,
    body = issue_body(request, result, draft),
    labels = { "fkst-dev:enabled", "bug" },
    dedup_key = dedup_key,
    source_ref = {
      kind = "external",
      ref = "qa-defect/" .. result.case_id,
    },
    handoff = {
      kind = "test-publication.product-defect",
      ledger_ref = request.ledger_ref,
      case_id = result.case_id,
      request_dedup_key = dedup_key,
    },
  }
end

local function validate_artifacts(request, ports)
  local plan, plan_ref = load_verified_plan(request, ports)
  local results = validated_result_view(request, ports, plan, plan_ref)
  return results, validate_issue_drafts(request, ports)
end

local function same_identity(state, request)
  local same = type(state) == "table"
    and state.schema == "test-publication.defect-publication-ledger.v1"
    and type(state.repository) == "table"
    and type(state.case_order) == "table" and type(state.cases) == "table"
    and state.repository.slug == request.repository.slug
    and state.repository.commit_sha == request.repository.commit_sha
    and state.plan_sha256 == request.plan_sha256
    and state.case_results_sha256 == request.case_results_sha256
    and state.issue_drafts_sha256 == request.issue_drafts_sha256
    and state.trace_id == request.trace_id and state.dedup_key == request.dedup_key
    and state.ledger_ref == request.ledger_ref and state.receipt_ref == request.receipt_ref
  if not same then return false end
  for _, field in ipairs(canonical_quartet_fields) do
    if state[field] ~= request[field] then return false end
  end
  return true
end

local function save(ports, state, expected_version)
  state.version = expected_version + 1
  if ports.save_ledger(state.ledger_ref, copy(state), expected_version) ~= true then
    error("test-publication: defect: ledger compare-and-swap failed")
  end
end

local function pending_requests(state)
  local requests = {}
  for _, case_id in ipairs(state.case_order) do
    local item = state.cases[case_id]
    if item.status == "pending" then table.insert(requests, copy(item.issue_request)) end
  end
  return requests
end

local function complete(state)
  for _, case_id in ipairs(state.case_order) do
    if state.cases[case_id].status == "pending" then return false end
  end
  return true
end

local function build_receipt(state)
  local cases = {}
  local blocked = false
  for _, case_id in ipairs(state.case_order) do
    local item = state.cases[case_id]
    if item.status == "blocked" then blocked = true end
    table.insert(cases, {
      case_id = case_id, classification = item.classification, status = item.status,
      issue_number = item.issue_number, issue_url = item.issue_url, evidence_ref = item.evidence_ref,
    })
  end
  return {
    schema = "test-publication.defect-publication-receipt.v1",
    status = blocked and "blocked" or "published",
    repository = copy(state.repository), source_commit = state.repository.commit_sha,
    plan_sha256 = state.plan_sha256, run_dedup_key = state.dedup_key,
    cases = cases, receipt_ref = state.receipt_ref, trace_id = state.trace_id,
  }
end

local function persist_receipt(state, ports)
  if state.receipt ~= nil then return copy(state.receipt) end
  local receipt = build_receipt(state)
  if ports.write_artifact(state.receipt_ref, receipt) ~= true then
    error("test-publication: defect: receipt write failed")
  end
  state.receipt = copy(receipt)
  return receipt
end

function M.terminal(receipt)
  return {
    schema = "test-publication.defect-publication-terminal.v1",
    status = receipt.status,
    receipt_ref = receipt.receipt_ref,
    trace_id = receipt.trace_id,
    dedup_key = receipt.run_dedup_key,
  }
end

function M.prepare(request, ports)
  M.validate_request(request)
  local loaded = ports.load_ledger(request.ledger_ref)
  if loaded ~= nil then
    local state = copy(loaded)
    if not same_identity(state, request) then error("test-publication: defect: foreign publication ledger") end
    return { replayed = true, issue_requests = pending_requests(state), receipt = copy(state.receipt) }
  end
  local results, drafts = validate_artifacts(request, ports)
  local state = {
    schema = "test-publication.defect-publication-ledger.v1", version = 0,
    repository = copy(request.repository), plan_sha256 = request.plan_sha256,
    case_results_sha256 = request.case_results_sha256, issue_drafts_sha256 = request.issue_drafts_sha256,
    ledger_ref = request.ledger_ref, receipt_ref = request.receipt_ref,
    trace_id = request.trace_id, dedup_key = request.dedup_key, case_order = {}, cases = {},
  }
  for _, field in ipairs(canonical_quartet_fields) do
    if request[field] ~= nil then state[field] = request[field] end
  end
  for _, result in ipairs(results.cases) do
    table.insert(state.case_order, result.case_id)
    local is_defect = canonical_results.is_product_defect(results, result)
    local item = {
      classification = is_defect and "product-defect" or result.classification,
      evidence_ref = result.evidence_ref,
      status = "summary-only",
    }
    if is_defect then
      local draft = drafts[result.case_id]
      if draft == nil or draft.evidence_ref ~= result.evidence_ref then
        item.status = "blocked"
      else
        item.status = "pending"
        item.issue_request = issue_request(request, result, draft)
      end
    end
    state.cases[result.case_id] = item
  end
  local receipt = complete(state) and persist_receipt(state, ports) or nil
  save(ports, state, 0)
  return { replayed = false, issue_requests = pending_requests(state), receipt = receipt }
end

local function issue_url(repo, number)
  return "https://github.com/" .. repo .. "/issues/" .. tostring(number)
end

function M.acknowledge_issue(written, ports)
  only_fields(written, {
    schema = true, status = true, issue_number = true, issue_url = true,
    request_dedup_key = true, handoff = true,
  }, "issue acknowledgement")
  only_fields(written.handoff, {
    kind = true, ledger_ref = true, case_id = true, request_dedup_key = true,
  }, "issue acknowledgement handoff")
  if written.schema ~= "github-proxy.issue-written.v1"
    or (written.status ~= "created" and written.status ~= "deduplicated")
    or type(written.issue_number) ~= "number" or written.issue_number < 1
    or written.issue_number ~= math.floor(written.issue_number)
    or not bounded(written.issue_url, 4096) or not bounded(written.request_dedup_key, 512)
    or written.handoff.kind ~= "test-publication.product-defect"
    or not safe_pointer(written.handoff.ledger_ref)
    or not bounded(written.handoff.case_id, 180)
    or written.handoff.case_id:match("^[%w._%-]+$") == nil
    or not bounded(written.handoff.request_dedup_key, 512) then
    error("test-publication: defect: malformed issue acknowledgement")
  end
  local state = copy(ports.load_ledger(written.handoff.ledger_ref))
  if type(state) ~= "table" or state.schema ~= "test-publication.defect-publication-ledger.v1" then
    error("test-publication: defect: publication ledger unavailable")
  end
  local item = state.cases[written.handoff.case_id]
  if type(item) ~= "table" or type(item.issue_request) ~= "table"
    or written.handoff.ledger_ref ~= state.ledger_ref
    or item.classification ~= "product-defect"
    or item.issue_request.handoff.case_id ~= written.handoff.case_id
    or item.issue_request.handoff.ledger_ref ~= written.handoff.ledger_ref
    or item.issue_request.dedup_key ~= written.request_dedup_key
    or written.handoff.request_dedup_key ~= written.request_dedup_key then
    error("test-publication: defect: issue acknowledgement does not match pending case")
  end
  local expected_url = issue_url(state.repository.slug, written.issue_number)
  if written.issue_url ~= expected_url then error("test-publication: defect: issue acknowledgement URL mismatch") end
  if item.status == "created" or item.status == "deduplicated" then
    if item.status ~= written.status or item.issue_number ~= written.issue_number then
      error("test-publication: defect: immutable issue acknowledgement changed")
    end
    return { replayed = true, receipt = copy(state.receipt) }
  end
  if item.status ~= "pending" then error("test-publication: defect: case is not awaiting issue publication") end
  item.status = written.status
  item.issue_number = written.issue_number
  item.issue_url = written.issue_url
  local receipt = complete(state) and persist_receipt(state, ports) or nil
  save(ports, state, state.version)
  return { replayed = false, receipt = receipt }
end

function M.production_ports()
  local ports = _G.defect_publication_runtime
  if ports == nil and local_runtime.configured() then ports = local_runtime.production() end
  for _, name in ipairs({ "load_ledger", "save_ledger", "load_artifact", "write_artifact" }) do
    if type(ports) ~= "table" or type(ports[name]) ~= "function" then
      error("test-publication: defect: missing runtime port " .. name)
    end
  end
  return ports
end

return M
