local M = {}

local stages = {
  intake = 10,
  ["sandbox-ready"] = 20,
  ["environment-ready"] = 30,
  ["design-round"] = 40,
  ["design-closure"] = 50,
  ["execution-batch"] = 60,
  ["defect-publication"] = 70,
  cleanup = 80,
  ["aggregate-report"] = 90,
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

local function equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, value in pairs(left) do
    if not equal(value, right[key]) then return false end
  end
  for key, _ in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
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
      or existing.status ~= request.status or not equal(existing.counts, request.counts) then
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
  cleanup_receipt_ref = true, cleanup_receipt_sha256 = true, aggregate_report_ref = true,
  defect_publication_receipt_ref = true, defect_publication_receipt_sha256 = true,
  trace_id = true, dedup_key = true,
}

local function validate_finalize_request(request)
  only_fields(request, finalize_fields, "finalize request")
  if request.schema ~= "test-publication.qa-finalize.request.v1" then
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
  for _, field in ipairs({ "test_plan_ref", "case_results_ref", "environment_receipt_ref", "cleanup_receipt_ref", "aggregate_report_ref" }) do
    if not safe_pointer(request[field]) or request[field]:sub(1, #request.artifact_root + 1) ~= request.artifact_root .. "/" then
      error("test-publication: qa: unsafe finalize pointer " .. field)
    end
  end
  for _, field in ipairs({ "test_plan_sha256", "case_results_sha256", "environment_receipt_sha256", "cleanup_receipt_sha256" }) do
    if not digest(request[field]) then error("test-publication: qa: invalid finalize digest " .. field) end
  end
  local optional_ref = request.defect_publication_receipt_ref
  local optional_sha = request.defect_publication_receipt_sha256
  if (optional_ref == nil) ~= (optional_sha == nil) or (optional_ref ~= nil and (not safe_pointer(optional_ref) or not digest(optional_sha))) then
    error("test-publication: qa: malformed defect publication receipt pointer")
  end
  return request
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

local terminal_case_statuses = { passed = true, failed = true, skipped = true, error = true }
local case_classifications = {
  passed = { passed = true },
  failed = { ["product-defect"] = true },
  skipped = { ["data-fixture-gap"] = true, ["not-executed-risk"] = true },
  error = { ["environment-session-issue"] = true, ["harness-tooling-issue"] = true },
}

local function reconcile(plan, results, request)
  if plan.schema ~= "testing-structured-plan.v1" or results.schema ~= "testing-structured-case-results.v1"
    or not dense_list(plan.cases) or not dense_list(results.cases) then
    error("test-publication: qa: malformed plan or case results")
  end
  if results.plan_sha256 ~= request.test_plan_sha256 then
    error("test-publication: qa: case results do not belong to the immutable plan")
  end
  local planned = {}
  for _, case in ipairs(plan.cases) do
    if not bounded(case.case_id, 180) or planned[case.case_id] then error("test-publication: qa: duplicate planned case") end
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
  validate_finalize_request(request)
  local replay = replayed_final_report(request, ports)
  if replay ~= nil then return replay end
  local plan = load_bound(ports, request.test_plan_ref, request.test_plan_sha256, "test plan")
  local results = load_bound(ports, request.case_results_ref, request.case_results_sha256, "case results")
  local environment = load_bound(ports, request.environment_receipt_ref, request.environment_receipt_sha256, "environment receipt")
  local cleanup = load_bound(ports, request.cleanup_receipt_ref, request.cleanup_receipt_sha256, "cleanup receipt")
  if environment.schema ~= "environment-factory.environment-result.v1" or environment.status ~= "ready" then
    error("test-publication: qa: environment readiness is not verified")
  end
  if cleanup.schema ~= "environment-factory.result.v1" or cleanup.status ~= "finalized" then
    error("test-publication: qa: cleanup is not verified")
  end
  local counts, classifications, evidence_refs = reconcile(plan, results, request)
  local links = {
    test_plan = publish_source(request, ports, request.test_plan_ref, request.test_plan_sha256, "aggregate-source-plan").remote_url,
    case_results = publish_source(request, ports, request.case_results_ref, request.case_results_sha256, "aggregate-source-results").remote_url,
    environment = publish_source(request, ports, request.environment_receipt_ref, request.environment_receipt_sha256, "aggregate-source-environment").remote_url,
    cleanup = publish_source(request, ports, request.cleanup_receipt_ref, request.cleanup_receipt_sha256, "aggregate-source-cleanup").remote_url,
  }
  local status = counts.failed > 0 and "failed"
    or (counts.error > 0 and "blocked")
    or (counts.skipped > 0 and "degraded")
    or "passed"
  local report = {
    schema = "test-publication.qa-aggregate-report.v1",
    status = status,
    repository = copy(request.repository),
    run_id = request.run_id,
    tested_modules = { "structured-api-cli" },
    counts = counts,
    classifications = classifications,
    defect_issue_links = defect_links(request, ports),
    evidence_refs = evidence_refs,
    artifact_links = links,
    residual_risks = counts.skipped + counts.error + counts.blocked,
    environment_receipt_ref = request.environment_receipt_ref,
    cleanup_receipt_ref = request.cleanup_receipt_ref,
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
    or not bounded(written.comment_id, 180) then
    error("test-publication: qa: malformed comment acknowledgement")
  end
  local handoff = written.handoff
  local state = copy(ports.load_ledger(handoff.ledger_ref))
  if type(state) ~= "table" or state.run_id ~= handoff.run_id then error("test-publication: qa: checkpoint ledger unavailable") end
  local key = checkpoint_key(handoff.stage, handoff.attempt)
  local checkpoint = state.checkpoints[key]
  if type(checkpoint) ~= "table" or checkpoint.comment_request.dedup_key ~= written.request_dedup_key then
    error("test-publication: qa: comment acknowledgement does not match checkpoint")
  end
  if checkpoint.receipt ~= nil then return copy(checkpoint.receipt) end
  local receipt_ref = state.artifact_root .. "/publication-receipts/" .. handoff.stage .. "-" .. tostring(handoff.attempt) .. ".json"
  local receipt = {
    schema = "test-publication.qa-publication-receipt.v1",
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
    dedup_key = written.request_dedup_key,
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

return M
