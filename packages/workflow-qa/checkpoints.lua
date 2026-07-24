local C = {}

local function copy(value)
  if value == nil or type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do
    local copied_key = copy(key)
    out[copied_key] = copy(item)
  end
  return out
end

local function equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, item in pairs(left) do if not equal(item, right[key]) then return false end end
  for key, _ in pairs(right) do if left[key] == nil then return false end end
  return true
end

local function digest(value)
  if type(value) ~= "string" or #value ~= 64 then return false end
  return value:match("^[0-9a-f]+$") ~= nil
end

local function action(queue, payload)
  return { queue = queue, payload = payload }
end

local function checkpoint_request(state, stage, attempt, status, artifact_ref, counts)
  local request = {
    schema = "test-publication.qa-checkpoint.request.v1",
    repository = {
      slug = state.request.repository.slug,
      commit_sha = state.request.repository.commit_sha,
    },
    run_id = state.request.run_id,
    issue_number = state.request.issue.number,
    stage = stage,
    attempt = attempt,
    status = status,
    artifact_root = state.request.artifact_root,
    artifact_ref = artifact_ref,
    artifact_sha256 = state.digests[artifact_ref],
    ledger_ref = state.request.publication.ledger_ref,
    trace_id = state.request.trace_id,
    dedup_key = state.request.dedup_key,
    counts = copy(counts),
  }
  if state.request.publication.channel ~= nil then
    request.channel = state.request.publication.channel
  end
  return request
end

local function receipt_ref(state, stage, attempt)
  return state.request.artifact_root .. "/publication-receipts/" .. stage .. "-" .. tostring(attempt) .. ".json"
end

local function request_dedup_key(state, stage, attempt, artifact_sha256)
  return table.concat({
    state.request.dedup_key, "checkpoint", stage, tostring(attempt), artifact_sha256,
  }, "/")
end

function C.gate(state, stage, status, artifact_ref, counts, next_phase, next_actions)
  if type(state.active_checkpoint) == "table" then
    error("workflow-qa: checkpoint-already-pending: only one checkpoint lease may be active")
  end
  state.checkpoint_attempts = state.checkpoint_attempts or {}
  local attempt = (state.checkpoint_attempts[stage] or 0) + 1
  state.checkpoint_attempts[stage] = attempt
  local request = checkpoint_request(state, stage, attempt, status, artifact_ref, counts)
  state.active_checkpoint = {
    stage = stage,
    attempt = attempt,
    artifact_ref = artifact_ref,
    artifact_sha256 = request.artifact_sha256,
    receipt_ref = receipt_ref(state, stage, attempt),
    request_dedup_key = request_dedup_key(state, stage, attempt, request.artifact_sha256),
    next_phase = next_phase,
    next_actions = copy(next_actions or {}),
  }
  state.phase = "checkpoint-pending"
  state.pending_actions = { action("test-publication.qa_checkpoint_request", request) }
  return copy(state.pending_actions)
end

function C.validate_receipt(state, receipt, expected, ports)
  if type(receipt) ~= "table" or receipt.schema ~= "test-publication.qa-publication-receipt.v2"
    or receipt.status ~= "published" or type(expected) ~= "table"
    or not digest(receipt.artifact_sha256)
    or receipt.run_id ~= state.request.run_id
    or receipt.stage ~= expected.stage or receipt.attempt ~= expected.attempt
    or receipt.artifact_sha256 ~= expected.artifact_sha256
    or receipt.source_commit ~= state.request.repository.commit_sha
    or receipt.receipt_ref ~= expected.receipt_ref
    or receipt.trace_id ~= state.request.trace_id
    or receipt.dedup_key ~= state.request.dedup_key
    or receipt.request_dedup_key ~= expected.request_dedup_key
    or type(receipt.repository) ~= "table"
    or receipt.repository.slug ~= state.request.repository.slug
    or receipt.repository.commit_sha ~= state.request.repository.commit_sha then
    error("workflow-qa: foreign-checkpoint-receipt: checkpoint identity differs")
  end
  local persisted = ports.load_artifact(receipt.receipt_ref)
  if type(persisted) ~= "table" or type(persisted.value) ~= "table"
    or not digest(persisted.digest) or not equal(persisted.value, receipt) then
    error("workflow-qa: checkpoint-receipt-unavailable: persisted receipt binding differs")
  end
  return persisted.digest
end

function C.release(state, receipt, ports)
  local pending = state.active_checkpoint
  if state.phase ~= "checkpoint-pending" or type(pending) ~= "table" then
    return nil
  end
  C.validate_receipt(state, receipt, pending, ports)
  local actions = copy(pending.next_actions)
  state.active_checkpoint = nil
  state.phase = pending.next_phase
  state.pending_actions = actions
  return actions
end

function C.aggregate_expectation(state, artifact_sha256)
  local stage, attempt = "aggregate-report", 1
  return {
    stage = stage,
    attempt = attempt,
    artifact_ref = state.request.publication.aggregate_report_ref,
    artifact_sha256 = artifact_sha256,
    receipt_ref = receipt_ref(state, stage, attempt),
    request_dedup_key = request_dedup_key(state, stage, attempt, artifact_sha256),
  }
end

return C
