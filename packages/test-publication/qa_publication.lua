local browser_readiness_contract = require("contract.browser_readiness")
local environment_contract = require("contract.environment_factory")
local structured_contract = require("contract.structured_execution")

local M = {}

local stages = {
  intake = 10,
  ["sandbox-ready"] = 20,
  ["environment-ready"] = 30,
  ["design-round"] = 40,
  ["browser-readiness"] = 50,
  ["design-closure"] = 60,
  ["execution-batch"] = 70,
  ["defect-publication"] = 80,
  cleanup = 90,
  ["aggregate-report"] = 100,
}

local statuses = {
  planned = true, passed = true, failed = true, blocked = true,
  degraded = true, skipped = true, error = true, completed = true,
}

local function bounded(value, maximum)
  return type(value) == "string" and value ~= "" and #value <= maximum
    and value:find("[%z\1-\31]") == nil
end

local function digest(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function safe_pointer(value)
  return bounded(value, 4096) and value:sub(1, 14) == ".testing/runs/"
    and value:find("..", 1, true) == nil
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function only_fields(value, allowed, label)
  if type(value) ~= "table" then error("test-publication: qa: " .. label .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then error("test-publication: qa: unsupported " .. label .. " field " .. tostring(key)) end
  end
end

local request_fields = {
  schema = true, repository = true, run_id = true, issue_number = true, stage = true,
  attempt = true, status = true, artifact_root = true, artifact_ref = true,
  artifact_sha256 = true, ledger_ref = true, trace_id = true, dedup_key = true, counts = true,
}

function M.validate_checkpoint_request(request)
  only_fields(request, request_fields, "checkpoint request")
  if request.schema ~= "test-publication.qa-checkpoint.request.v1" then
    error("test-publication: qa: unknown checkpoint schema")
  end
  only_fields(request.repository, { slug = true, commit_sha = true }, "repository")
  if not bounded(request.repository.slug, 180) or request.repository.slug:match("^[%w_.%-]+/[%w_.%-]+$") == nil
    or type(request.repository.commit_sha) ~= "string" or #request.repository.commit_sha ~= 40
    or request.repository.commit_sha:match("^[0-9a-f]+$") == nil then
    error("test-publication: qa: immutable repository identity is required")
  end
  if not bounded(request.run_id, 180) or type(request.issue_number) ~= "number"
    or request.issue_number < 1 or request.issue_number ~= math.floor(request.issue_number)
    or stages[request.stage] == nil or not statuses[request.status]
    or type(request.attempt) ~= "number" or request.attempt < 1 or request.attempt > 1000
    or request.attempt ~= math.floor(request.attempt) then
    error("test-publication: qa: malformed checkpoint identity")
  end
  for _, field in ipairs({ "artifact_root", "artifact_ref", "ledger_ref" }) do
    if not safe_pointer(request[field]) then error("test-publication: qa: unsafe pointer " .. field) end
  end
  if request.artifact_ref:sub(1, #request.artifact_root + 1) ~= request.artifact_root .. "/"
    or request.ledger_ref ~= request.artifact_root .. "/run-ledger.json"
    or not digest(request.artifact_sha256) or not bounded(request.trace_id, 180)
    or not bounded(request.dedup_key, 180) then
    error("test-publication: qa: checkpoint binding is invalid")
  end
  if request.counts ~= nil then
    only_fields(request.counts, {
      planned = true, executed = true, passed = true, failed = true,
      skipped = true, error = true, blocked = true,
    }, "checkpoint counts")
    for _, count in pairs(request.counts) do
      if type(count) ~= "number" or count < 0 or count > 100000 or count ~= math.floor(count) then
        error("test-publication: qa: invalid checkpoint count")
      end
    end
  end
  return request
end

local function same_identity(state, request)
  return state.repository.slug == request.repository.slug
    and state.repository.commit_sha == request.repository.commit_sha
    and state.run_id == request.run_id
    and state.issue_number == request.issue_number
    and state.artifact_root == request.artifact_root
    and state.trace_id == request.trace_id
    and state.dedup_key == request.dedup_key
end

local function initial_state(request)
  return {
    schema = "test-publication.qa-run-ledger.v1",
    version = 0,
    repository = copy(request.repository),
    run_id = request.run_id,
    issue_number = request.issue_number,
    artifact_root = request.artifact_root,
    ledger_ref = request.ledger_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    latest_stage_rank = 0,
    checkpoints = {},
  }
end

local function checkpoint_key(stage, attempt)
  return stage .. "/" .. tostring(attempt)
end

local function validate_publication(publication, request)
  if type(publication) ~= "table" or publication.status ~= "published"
    or not bounded(publication.remote_url, 2048) or publication.remote_url:match("^https://github%.com/") == nil
    or publication.digest ~= request.artifact_sha256
    or publication.source_commit ~= request.repository.commit_sha
    or not safe_pointer(publication.receipt_ref) then
    error("test-publication: qa: immutable artifact publication failed")
  end
  return publication
end

local function summary_marker(run_id)
  return "<!-- fkst:qa-run-summary:" .. run_id .. " -->"
end

local function checkpoint_body(request, publication)
  local lines = {
    "## FKST QA Run",
    "",
    "- Run: `" .. request.run_id .. "`",
    "- Source commit: `" .. request.repository.commit_sha .. "`",
    "- Stage: `" .. request.stage .. "` (attempt " .. tostring(request.attempt) .. ")",
    "- Status: `" .. request.status .. "`",
    "- Artifact: " .. publication.remote_url,
    "- Digest: `" .. publication.digest .. "`",
  }
  if request.counts ~= nil then
    table.insert(lines, "- Counts: planned=" .. tostring(request.counts.planned or 0)
      .. " executed=" .. tostring(request.counts.executed or 0)
      .. " passed=" .. tostring(request.counts.passed or 0)
      .. " failed=" .. tostring(request.counts.failed or 0)
      .. " skipped=" .. tostring(request.counts.skipped or 0)
      .. " error=" .. tostring(request.counts.error or 0)
      .. " blocked=" .. tostring(request.counts.blocked or 0))
  end
  table.insert(lines, "")
  table.insert(lines, summary_marker(request.run_id))
  table.insert(lines, '<!-- fkst:qa-checkpoint:v1 run="' .. request.run_id .. '" stage="' .. request.stage
    .. '" attempt="' .. tostring(request.attempt) .. '" digest="' .. publication.digest .. '" -->')
  return table.concat(lines, "\n")
end

local function comment_request(request, publication)
  local dedup_key = table.concat({ request.dedup_key, "checkpoint", request.stage, tostring(request.attempt), publication.digest }, "/")
  return {
    schema = "github-proxy.v1",
    repo = request.repository.slug,
    issue_number = request.issue_number,
    body = checkpoint_body(request, publication),
    dedup_key = dedup_key,
    replace_marker = summary_marker(request.run_id),
    source_ref = { kind = "external", ref = request.repository.slug .. "#issue/" .. tostring(request.issue_number) },
    handoff = {
      kind = "test-publication.qa-checkpoint",
      ledger_ref = request.ledger_ref,
      run_id = request.run_id,
      stage = request.stage,
      attempt = request.attempt,
      request_dedup_key = dedup_key,
    },
  }
end

local function save(ports, state, expected_version)
  state.version = expected_version + 1
  if ports.save_ledger(state.ledger_ref, copy(state), expected_version) ~= true then
    error("test-publication: qa: ledger compare-and-swap failed")
  end
end

function M.prepare_checkpoint(request, ports)
  M.validate_checkpoint_request(request)
  local loaded = ports.load_ledger(request.ledger_ref)
  local state = loaded and copy(loaded) or initial_state(request)
  if not same_identity(state, request) then error("test-publication: qa: foreign run ledger") end
  local key = checkpoint_key(request.stage, request.attempt)
  local existing = state.checkpoints[key]
  if existing ~= nil then
    if existing.artifact_ref ~= request.artifact_ref or existing.artifact_sha256 ~= request.artifact_sha256
      or existing.status ~= request.status or not structured_contract.equal(existing.counts, request.counts) then
      error("test-publication: qa: immutable checkpoint changed on replay")
    end
    local outbound = existing.receipt and nil or copy(existing.comment_request)
    if existing.receipt then outbound = nil end
    return {
      status = existing.receipt and "published" or "pending",
      replayed = true,
      comment_request = outbound,
    }
  end
  local rank = stages[request.stage]
  if rank < state.latest_stage_rank then error("test-publication: qa: stale checkpoint transition") end
  local publication = validate_publication(ports.publish_artifact({
    repository = copy(request.repository),
    artifact_ref = request.artifact_ref,
    digest = request.artifact_sha256,
    run_id = request.run_id,
    stage = request.stage,
    attempt = request.attempt,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }), request)
  local outbound = comment_request(request, publication)
  state.checkpoints[key] = {
    stage = request.stage,
    attempt = request.attempt,
    status = request.status,
    artifact_ref = request.artifact_ref,
    artifact_sha256 = request.artifact_sha256,
    counts = copy(request.counts),
    publication = copy(publication),
    comment_request = copy(outbound),
  }
  if rank > state.latest_stage_rank then state.latest_stage_rank = rank end
  save(ports, state, state.version)
  return { status = "pending", replayed = false, comment_request = outbound }
end

local finalize_fields = {
  schema = true, repository = true, run_id = true, issue_number = true, artifact_root = true,
  ledger_ref = true, test_plan_ref = true, test_plan_sha256 = true, case_results_ref = true,
  case_results_sha256 = true, environment_receipt_ref = true, environment_receipt_sha256 = true,
  browser_readiness_ref = true, browser_readiness_sha256 = true,
  cleanup_receipt_ref = true, cleanup_receipt_sha256 = true, aggregate_report_ref = true,
  terminal_summary_ref = true, terminal_summary_sha256 = true,
  defect_publication_receipt_ref = true, defect_publication_receipt_sha256 = true,
  trace_id = true, dedup_key = true,
}

local function validate_finalize_request(request)
  only_fields(request, finalize_fields, "finalize request")
  if request.schema ~= "test-publication.qa-finalize.request.v2" then
    error("test-publication: qa: unknown finalize schema")
  end
  local checkpoint = {
    schema = "test-publication.qa-checkpoint.request.v1",
    repository = request.repository,
    run_id = request.run_id,
    issue_number = request.issue_number,
    stage = "aggregate-report",
    attempt = 1,
    status = "planned",
    artifact_root = request.artifact_root,
    artifact_ref = request.aggregate_report_ref,
    artifact_sha256 = string.rep("0", 64),
    ledger_ref = request.ledger_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  M.validate_checkpoint_request(checkpoint)
  for _, field in ipairs({ "terminal_summary_ref", "environment_receipt_ref", "cleanup_receipt_ref", "aggregate_report_ref" }) do
    if not safe_pointer(request[field]) or request[field]:sub(1, #request.artifact_root + 1) ~= request.artifact_root .. "/" then
      error("test-publication: qa: unsafe finalize pointer " .. field)
    end
  end
  for _, field in ipairs({ "terminal_summary_sha256", "environment_receipt_sha256", "cleanup_receipt_sha256" }) do
    if not digest(request[field]) then error("test-publication: qa: invalid finalize digest " .. field) end
  end
  local has_readiness = request.browser_readiness_ref ~= nil or request.browser_readiness_sha256 ~= nil
  if has_readiness ~= (request.browser_readiness_ref ~= nil and request.browser_readiness_sha256 ~= nil) then
    error("test-publication: qa: browser readiness pointer and digest must be paired")
  end
  if has_readiness and (not safe_pointer(request.browser_readiness_ref)
    or request.browser_readiness_ref:sub(1, #request.artifact_root + 1) ~= request.artifact_root .. "/"
    or not digest(request.browser_readiness_sha256)) then
    error("test-publication: qa: malformed browser readiness pointer")
  end
  local full = request.test_plan_ref ~= nil or request.test_plan_sha256 ~= nil
    or request.case_results_ref ~= nil or request.case_results_sha256 ~= nil
  if full ~= (request.test_plan_ref ~= nil and request.test_plan_sha256 ~= nil
    and request.case_results_ref ~= nil and request.case_results_sha256 ~= nil) then
    error("test-publication: qa: full finalization requires bound plan and case results")
  end
  if full then
    for _, field in ipairs({ "test_plan_ref", "case_results_ref" }) do
      if not safe_pointer(request[field]) or request[field]:sub(1, #request.artifact_root + 1) ~= request.artifact_root .. "/" then
        error("test-publication: qa: unsafe finalize pointer " .. field)
      end
    end
    for _, field in ipairs({ "test_plan_sha256", "case_results_sha256" }) do
      if not digest(request[field]) then error("test-publication: qa: invalid finalize digest " .. field) end
    end
  end
  if full and not has_readiness then
    error("test-publication: qa: full finalization requires post-design browser readiness")
  end
  local optional_ref = request.defect_publication_receipt_ref
  local optional_sha = request.defect_publication_receipt_sha256
  if (optional_ref == nil) ~= (optional_sha == nil)
    or (optional_ref ~= nil and (not safe_pointer(optional_ref) or not digest(optional_sha))) then
    error("test-publication: qa: malformed defect publication receipt pointer")
  end
  return request, full
end

local function load_bound(ports, ref, expected_digest, label)
  local artifact = ports.load_artifact(ref)
  if type(artifact) ~= "table" or artifact.digest ~= expected_digest or type(artifact.value) ~= "table" then
    error("test-publication: qa: " .. label .. " digest mismatch")
  end
  return artifact.value
end

local function dense_list(value)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    if key > highest then highest = key end
  end
  return count == highest and count <= 100000
end

local function same_repository(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.url == right.url and left.commit_sha == right.commit_sha
end

local function validate_counts(value)
  only_fields(value, {
    planned = true, executed = true, passed = true, failed = true,
    skipped = true, error = true, blocked = true,
  }, "terminal summary counts")
  local counts = {}
  for _, field in ipairs({ "planned", "executed", "passed", "failed", "skipped", "error", "blocked" }) do
    local count = value[field]
    if type(count) ~= "number" or count < 0 or count > 100000 or count ~= math.floor(count) then
      error("test-publication: qa: invalid terminal summary count")
    end
    counts[field] = count
  end
  return counts
end

local function validate_terminal_summary(summary, request, full)
  only_fields(summary, {
    schema = true, status = true, repository = true, run_id = true, phase = true,
    counts = true, environment_receipt_ref = true, cleanup_receipt_ref = true,
    browser_readiness_ref = true, browser_readiness_sha256 = true,
    module_plan_ref = true, structured_plan_ref = true, case_results_ref = true,
    interruption = true, trace_id = true, dedup_key = true,
  }, "terminal summary")
  only_fields(summary.repository, { slug = true, url = true, commit_sha = true }, "terminal summary repository")
  local terminal_statuses = {
    passed = true, failed = true, blocked = true, degraded = true, error = true,
    cancelled = true, interrupted = true, ["timed-out"] = true,
  }
  if (summary.browser_readiness_ref == nil) ~= (summary.browser_readiness_sha256 == nil)
    or (summary.browser_readiness_ref ~= nil and (not safe_pointer(summary.browser_readiness_ref)
      or not digest(summary.browser_readiness_sha256))) then
    error("test-publication: qa: unsafe terminal browser readiness binding")
  end
  if summary.schema ~= "workflow-qa.terminal-summary.v2" or not terminal_statuses[summary.status]
    or summary.repository.slug ~= request.repository.slug
    or summary.repository.commit_sha ~= request.repository.commit_sha
    or not bounded(summary.repository.url, 2048) or summary.repository.url:match("^https://") == nil
    or summary.run_id ~= request.run_id or not bounded(summary.phase, 180)
    or summary.environment_receipt_ref ~= request.environment_receipt_ref
    or summary.cleanup_receipt_ref ~= request.cleanup_receipt_ref
    or summary.browser_readiness_ref ~= request.browser_readiness_ref
    or summary.browser_readiness_sha256 ~= request.browser_readiness_sha256
    or summary.trace_id ~= request.trace_id or summary.dedup_key ~= request.dedup_key then
    error("test-publication: qa: terminal summary binding is invalid")
  end
  for _, field in ipairs({ "module_plan_ref", "structured_plan_ref", "case_results_ref" }) do
    if summary[field] ~= nil and (not safe_pointer(summary[field])
      or summary[field]:sub(1, #request.artifact_root + 1) ~= request.artifact_root .. "/") then
      error("test-publication: qa: unsafe terminal summary pointer " .. field)
    end
  end
  if full and (summary.structured_plan_ref ~= request.test_plan_ref
    or summary.case_results_ref ~= request.case_results_ref) then
    error("test-publication: qa: terminal summary differs from full finalization inputs")
  end
  if summary.interruption ~= nil and summary.interruption ~= "cancelled"
    and summary.interruption ~= "interrupted" and summary.interruption ~= "timed-out" then
    error("test-publication: qa: invalid terminal interruption")
  end
  return validate_counts(summary.counts), summary.repository
end

local function validate_environment_receipts(environment, cleanup, request, repository, full)
  local environment_ok = pcall(environment_contract.validate_receipt, environment)
  local cleanup_ok = pcall(environment_contract.validate_cleanup_receipt, cleanup)
  if not environment_ok or not cleanup_ok then
    error("test-publication: qa: environment or cleanup receipt is malformed")
  end
  if environment.operation_id ~= request.run_id or not same_repository(environment.repository, repository)
    or environment.trace_id ~= request.trace_id or environment.dedup_key ~= request.dedup_key
    or request.environment_receipt_ref:sub(1, #environment.artifact_root + 1) ~= environment.artifact_root .. "/" then
    error("test-publication: qa: environment receipt does not belong to the run")
  end
  if full and environment.status ~= "ready" then
    error("test-publication: qa: full finalization requires a ready browser-verified environment")
  end
  if cleanup.status ~= "complete" or cleanup.operation_id ~= request.run_id
    or cleanup.artifact_root ~= environment.artifact_root
    or cleanup.trace_id ~= request.trace_id or cleanup.dedup_key ~= request.dedup_key
    or request.cleanup_receipt_ref:sub(1, #cleanup.artifact_root + 1) ~= cleanup.artifact_root .. "/" then
    error("test-publication: qa: cleanup is not verified")
  end
  if environment.status ~= "ready" then
    if environment.cleanup_status ~= "complete" or type(environment.cleanup_receipt_ref) ~= "table"
      or environment.cleanup_receipt_ref.ref ~= request.cleanup_receipt_ref then
      error("test-publication: qa: terminal environment receipt is not bound to complete cleanup")
    end
  end
end

local terminal_case_statuses = { passed = true, failed = true, skipped = true, error = true }
local case_classifications = {
  passed = { passed = true },
  failed = { ["product-defect"] = true },
  skipped = { ["data-fixture-gap"] = true, ["not-executed-risk"] = true },
  error = { ["environment-session-issue"] = true, ["harness-tooling-issue"] = true },
}

local function reconcile(plan, results, request, repository)
  local plan_ok = pcall(structured_contract.validate_plan, plan)
  local malformed = not plan_ok or results.schema ~= "testing-structured-case-results.v1" or not dense_list(results.cases)
  if malformed then error("test-publication: qa: malformed plan or case results") end
  if not same_repository(plan.repository, repository)
    or plan.environment_receipt_sha256 ~= request.environment_receipt_sha256
    or plan.browser_readiness_sha256 ~= request.browser_readiness_sha256
    or plan.trace_id ~= request.trace_id or plan.dedup_key ~= request.dedup_key
    or results.plan_sha256 ~= request.test_plan_sha256 then
    error("test-publication: qa: case results do not belong to the immutable plan")
  end
  local planned = {}
  for _, case in ipairs(plan.cases) do
    planned[case.case_id] = case.kind
  end
  local counts = { planned = #plan.cases, executed = 0, passed = 0, failed = 0, skipped = 0, error = 0, blocked = 0 }
  local classifications, evidence_refs = {}, {}
  for _, result in ipairs(results.cases) do
    if not planned[result.case_id] or not terminal_case_statuses[result.status] then
      error("test-publication: qa: foreign or non-terminal case result")
    end
    if result.kind ~= planned[result.case_id] or not case_classifications[result.status][result.classification]
      or not safe_pointer(result.evidence_ref)
      or result.evidence_ref:sub(1, #request.artifact_root + 1) ~= request.artifact_root .. "/" then
      error("test-publication: qa: unsafe or mismatched case result")
    end
    if classifications[result.case_id] ~= nil then error("test-publication: qa: duplicate case result") end
    classifications[result.case_id] = result.classification
    evidence_refs[result.case_id] = result.evidence_ref
    counts.executed = counts.executed + 1
    counts[result.status] = counts[result.status] + 1
  end
  if counts.executed ~= counts.planned then error("test-publication: qa: planned cases lack terminal dispositions") end
  return counts, classifications, evidence_refs
end

local function publish_source(request, ports, ref, source_digest, stage)
  return validate_publication(ports.publish_artifact({
    repository = copy(request.repository), artifact_ref = ref, digest = source_digest,
    run_id = request.run_id, stage = stage, attempt = 1,
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }), { artifact_sha256 = source_digest, repository = request.repository })
end

local function defect_links(request, ports)
  if request.defect_publication_receipt_ref == nil then return {} end
  local receipt = load_bound(ports, request.defect_publication_receipt_ref, request.defect_publication_receipt_sha256, "defect publication receipt")
  if receipt.schema ~= "test-publication.defect-publication-receipt.v1" or not dense_list(receipt.cases or {}) then
    error("test-publication: qa: malformed defect publication receipt")
  end
  local links = {}
  local issue_prefix = "https://github.com/" .. request.repository.slug .. "/issues/"
  for _, item in ipairs(receipt.cases) do
    if (item.status == "created" or item.status == "deduplicated") and bounded(item.issue_url, 2048)
      and item.issue_url:sub(1, #issue_prefix) == issue_prefix
      and item.issue_url:sub(#issue_prefix + 1):match("^%d+$") ~= nil then
      table.insert(links, item.issue_url)
    end
  end
  return links
end

local function replayed_final_report(request, ports)
  local state = ports.load_ledger(request.ledger_ref)
  if state == nil then return nil end
  if type(state) ~= "table" or state.schema ~= "test-publication.qa-run-ledger.v1"
    or not same_identity(state, request) then
    error("test-publication: qa: foreign run ledger")
  end
  local checkpoint = state.checkpoints and state.checkpoints[checkpoint_key("aggregate-report", 1)] or nil
  if checkpoint == nil then return nil end
  if checkpoint.artifact_ref ~= request.aggregate_report_ref then
    error("test-publication: qa: aggregate report pointer changed on replay")
  end
  local report = load_bound(ports, request.aggregate_report_ref, checkpoint.artifact_sha256, "aggregate report")
  if report.schema ~= "test-publication.qa-aggregate-report.v1" or report.run_id ~= request.run_id
    or report.trace_id ~= request.trace_id or report.dedup_key ~= request.dedup_key then
    error("test-publication: qa: aggregate report replay binding is invalid")
  end
  local outbound = checkpoint.receipt and nil or copy(checkpoint.comment_request)
  if checkpoint.receipt then outbound = nil end
  return {
    status = checkpoint.receipt and "published" or "pending",
    replayed = true,
    comment_request = outbound,
    report = report,
  }
end

function M.prepare_final_report(request, ports)
  local _, full = validate_finalize_request(request)
  local replay = replayed_final_report(request, ports)
  if replay ~= nil then return replay end
  local terminal_summary = load_bound(ports, request.terminal_summary_ref, request.terminal_summary_sha256, "terminal summary")
  local environment = load_bound(ports, request.environment_receipt_ref, request.environment_receipt_sha256, "environment receipt")
  local cleanup = load_bound(ports, request.cleanup_receipt_ref, request.cleanup_receipt_sha256, "cleanup receipt")
  local readiness = request.browser_readiness_ref and load_bound(ports, request.browser_readiness_ref,
    request.browser_readiness_sha256, "browser readiness") or nil
  local summary_counts, repository = validate_terminal_summary(terminal_summary, request, full)
  validate_environment_receipts(environment, cleanup, request, repository, full)
  if readiness ~= nil then
    local readiness_ok = pcall(browser_readiness_contract.validate_result, readiness)
    if not readiness_ok or readiness.status ~= "ready"
      or type(readiness.source_ref) ~= "table" or readiness.source_ref.kind ~= "workflow-qa"
      or readiness.source_ref.ref ~= request.run_id
      or type(readiness.correlation) ~= "table"
      or readiness.correlation.trace_id ~= request.trace_id
      or readiness.correlation.dedup_key ~= request.dedup_key then
      error("test-publication: qa: post-design browser readiness does not belong to the run")
    end
  end
  local counts, classifications, evidence_refs = summary_counts, {}, {}
  local execution_mode
  if full then
    local plan = load_bound(ports, request.test_plan_ref, request.test_plan_sha256, "test plan")
    local results = load_bound(ports, request.case_results_ref, request.case_results_sha256, "case results")
    execution_mode = plan.execution_mode
    counts, classifications, evidence_refs = reconcile(plan, results, request, repository)
    if not structured_contract.equal(counts, summary_counts) then
      error("test-publication: qa: terminal summary counts differ from reconciled results")
    end
  end
  local links = {
    terminal_summary = publish_source(request, ports, request.terminal_summary_ref,
      request.terminal_summary_sha256, "aggregate-source-terminal").remote_url,
    environment = publish_source(request, ports, request.environment_receipt_ref,
      request.environment_receipt_sha256, "aggregate-source-environment").remote_url,
    cleanup = publish_source(request, ports, request.cleanup_receipt_ref,
      request.cleanup_receipt_sha256, "aggregate-source-cleanup").remote_url,
  }
  if readiness ~= nil then
    links.browser_readiness = publish_source(request, ports, request.browser_readiness_ref,
      request.browser_readiness_sha256, "aggregate-source-browser-readiness").remote_url
  end
  if full then
    links.test_plan = publish_source(request, ports, request.test_plan_ref,
      request.test_plan_sha256, "aggregate-source-plan").remote_url
    links.case_results = publish_source(request, ports, request.case_results_ref,
      request.case_results_sha256, "aggregate-source-results").remote_url
  end
  local status
  if full then
    status = counts.failed > 0 and "failed"
      or (counts.error > 0 and "blocked")
      or (counts.skipped > 0 and "degraded")
      or "passed"
  else
    status = ({ passed = "passed", failed = "failed", degraded = "degraded" })[terminal_summary.status]
      or "blocked"
  end
  local report = {
    schema = "test-publication.qa-aggregate-report.v1",
    status = status,
    repository = copy(request.repository),
    run_id = request.run_id,
    finalization_kind = full and "full" or "terminal-summary",
    terminal_status = terminal_summary.status,
    tested_modules = full and { execution_mode } or {},
    counts = counts,
    classifications = classifications,
    defect_issue_links = defect_links(request, ports),
    evidence_refs = evidence_refs,
    artifact_links = links,
    residual_risks = counts.skipped + counts.error + counts.blocked,
    environment_receipt_ref = request.environment_receipt_ref,
    browser_readiness_ref = request.browser_readiness_ref,
    cleanup_receipt_ref = request.cleanup_receipt_ref,
    terminal_summary_ref = request.terminal_summary_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  local written = ports.write_report(request.aggregate_report_ref, report)
  if type(written) ~= "table" or written.status ~= "written" or not digest(written.digest) then
    error("test-publication: qa: aggregate report write failed")
  end
  local prepared = M.prepare_checkpoint({
    schema = "test-publication.qa-checkpoint.request.v1",
    repository = request.repository, run_id = request.run_id, issue_number = request.issue_number,
    stage = "aggregate-report", attempt = 1, status = status, artifact_root = request.artifact_root,
    artifact_ref = request.aggregate_report_ref, artifact_sha256 = written.digest, ledger_ref = request.ledger_ref,
    trace_id = request.trace_id, dedup_key = request.dedup_key, counts = counts,
  }, ports)
  prepared.report = report
  return prepared
end

function M.acknowledge_comment(written, ports)
  if type(written) ~= "table" or written.schema ~= "github-proxy.comment-written.v1"
    or type(written.handoff) ~= "table" or written.handoff.kind ~= "test-publication.qa-checkpoint"
    or not bounded(written.comment_id, 180) or not bounded(written.request_dedup_key, 512) then
    error("test-publication: qa: malformed comment acknowledgement")
  end
  local handoff = written.handoff
  local state = copy(ports.load_ledger(handoff.ledger_ref))
  if type(state) ~= "table" or state.run_id ~= handoff.run_id then error("test-publication: qa: checkpoint ledger unavailable") end
  local key = checkpoint_key(handoff.stage, handoff.attempt)
  local checkpoint = state.checkpoints[key]
  if type(checkpoint) ~= "table" or checkpoint.comment_request.dedup_key ~= written.request_dedup_key
    or handoff.request_dedup_key ~= written.request_dedup_key then
    error("test-publication: qa: comment acknowledgement does not match checkpoint")
  end
  if checkpoint.receipt ~= nil then return copy(checkpoint.receipt) end
  local receipt_ref = state.artifact_root .. "/publication-receipts/" .. handoff.stage .. "-" .. tostring(handoff.attempt) .. ".json"
  local receipt = {
    schema = "test-publication.qa-publication-receipt.v2",
    status = "published",
    repository = copy(state.repository),
    run_id = state.run_id,
    stage = handoff.stage,
    attempt = handoff.attempt,
    comment_id = written.comment_id,
    remote_url = checkpoint.publication.remote_url,
    artifact_sha256 = checkpoint.artifact_sha256,
    source_commit = state.repository.commit_sha,
    receipt_ref = receipt_ref,
    trace_id = state.trace_id,
    dedup_key = state.dedup_key,
    request_dedup_key = written.request_dedup_key,
  }
  if ports.write_artifact(receipt_ref, receipt) ~= true then error("test-publication: qa: publication receipt write failed") end
  checkpoint.receipt = copy(receipt)
  save(ports, state, state.version)
  return receipt
end

function M.production_ports()
  local ports = _G.qa_publication_runtime
  for _, name in ipairs({ "load_ledger", "save_ledger", "publish_artifact", "write_artifact", "write_report", "load_artifact" }) do
    if type(ports) ~= "table" or type(ports[name]) ~= "function" then
      error("test-publication: qa: missing runtime port " .. name)
    end
  end
  return ports
end

function M.saga_conformance_errors()
  local state
  local publish_count, receipt_write_count = 0, 0
  local commit_sha = string.rep("1", 40)
  local request = {
    schema = "test-publication.qa-checkpoint.request.v1",
    repository = { slug = "owner/repo", commit_sha = commit_sha },
    run_id = "qa-publication-conformance",
    issue_number = 107,
    stage = "intake",
    attempt = 1,
    status = "passed",
    artifact_root = ".testing/runs/qa-publication-conformance",
    artifact_ref = ".testing/runs/qa-publication-conformance/intake.json",
    artifact_sha256 = string.rep("a", 64),
    ledger_ref = ".testing/runs/qa-publication-conformance/run-ledger.json",
    trace_id = "trace-qa-publication-conformance",
    dedup_key = "dedup-qa-publication-conformance",
  }
  local ports = {
    load_ledger = function() return state end,
    save_ledger = function(_, value, expected_version)
      if state ~= nil and state.version ~= expected_version then return false end
      if state == nil and expected_version ~= 0 then return false end
      state = value
      return true
    end,
    publish_artifact = function(value)
      publish_count = publish_count + 1
      return {
        status = "published",
        remote_url = "https://github.com/owner/repo/blob/" .. commit_sha .. "/qa/intake.json",
        digest = value.digest,
        source_commit = commit_sha,
        receipt_ref = request.artifact_root .. "/publication/intake-1.json",
      }
    end,
    write_artifact = function()
      receipt_write_count = receipt_write_count + 1
      return true
    end,
  }
  local first = M.prepare_checkpoint(request, ports)
  assert(first.status == "pending", "test-publication first checkpoint must progress")
  local replay = M.prepare_checkpoint(request, ports)
  assert(replay.replayed == true, "test-publication checkpoint replay must be detected")
  assert(publish_count == 1, "test-publication checkpoint replay must not republish")
  local written = {
    schema = "github-proxy.comment-written.v1",
    comment_id = "501",
    request_dedup_key = first.comment_request.dedup_key,
    handoff = first.comment_request.handoff,
  }
  local receipt = M.acknowledge_comment(written, ports)
  local replayed_receipt = M.acknowledge_comment(written, ports)
  assert(receipt_write_count == 1, "test-publication acknowledgement replay must not rewrite receipt")
  assert(receipt.receipt_ref == replayed_receipt.receipt_ref, "test-publication acknowledgement replay must reuse receipt")
  return {}
end

return M
