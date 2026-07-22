local qa_publication = require("qa_publication")
local t = fkst.test

local commit_sha = string.rep("1", 40)
local artifact_sha = string.rep("a", 64)

local function request()
  return {
    schema = "test-publication.qa-checkpoint.request.v1",
    repository = { slug = "owner/repo", commit_sha = commit_sha },
    run_id = "qa-run-107",
    issue_number = 107,
    stage = "environment-ready",
    attempt = 1,
    status = "passed",
    artifact_root = ".testing/runs/qa-run-107",
    artifact_ref = ".testing/runs/qa-run-107/environment-receipt-ready.json",
    artifact_sha256 = artifact_sha,
    ledger_ref = ".testing/runs/qa-run-107/run-ledger.json",
    trace_id = "trace-qa-run-107",
    dedup_key = "dedup-qa-run-107",
  }
end

local function ports()
  local state
  local writes = {}
  return {
    load_ledger = function() return state end,
    save_ledger = function(_, value, expected_version)
      if state ~= nil and state.version ~= expected_version then return false end
      if state == nil and expected_version ~= 0 then return false end
      state = value
      return true
    end,
    publish_artifact = function(value)
      return {
        status = "published",
        remote_url = "https://github.com/owner/repo/blob/" .. commit_sha .. "/qa/environment-receipt-ready.json",
        digest = value.digest,
        source_commit = commit_sha,
        receipt_ref = ".testing/runs/qa-run-107/publication/environment-ready-1.json",
      }
    end,
    write_artifact = function(path, value) writes[path] = value return true end,
    state = function() return state end,
    writes = writes,
  }
end

return {
  test_checkpoint_publishes_immutable_artifact_and_builds_canonical_comment = function()
    local runtime = ports()
    local prepared = qa_publication.prepare_checkpoint(request(), runtime)

    t.eq(prepared.status, "pending")
    t.eq(prepared.comment_request.schema, "github-proxy.v1")
    t.eq(prepared.comment_request.repo, "owner/repo")
    t.eq(prepared.comment_request.issue_number, 107)
    t.eq(prepared.comment_request.replace_marker, "<!-- fkst:qa-run-summary:qa-run-107 -->")
    t.is_true(prepared.comment_request.body:find("environment-ready", 1, true) ~= nil)
    t.is_true(prepared.comment_request.body:find("https://github.com/owner/repo/blob/", 1, true) ~= nil)
    t.eq(prepared.comment_request.body:find("environment", 1, true) ~= nil, true)
    t.eq(runtime.state().version, 1)

    local replay = qa_publication.prepare_checkpoint(request(), runtime)
    t.eq(replay.replayed, true)
    t.eq(replay.comment_request.dedup_key, prepared.comment_request.dedup_key)
  end,

  test_comment_acknowledgement_writes_durable_checkpoint_receipt = function()
    local runtime = ports()
    local prepared = qa_publication.prepare_checkpoint(request(), runtime)
    local receipt = qa_publication.acknowledge_comment({
      schema = "github-proxy.comment-written.v1",
      repo = "owner/repo",
      target = "issue",
      issue_number = 107,
      comment_id = "501",
      request_dedup_key = prepared.comment_request.dedup_key,
      dedup_key = prepared.comment_request.dedup_key .. "/written/501",
      handoff = prepared.comment_request.handoff,
      source_ref = prepared.comment_request.source_ref,
    }, runtime)

    t.eq(receipt.schema, "test-publication.qa-publication-receipt.v2")
    t.eq(receipt.status, "published")
    t.eq(receipt.comment_id, "501")
    t.eq(receipt.stage, "environment-ready")
    t.eq(receipt.dedup_key, request().dedup_key)
    t.eq(receipt.request_dedup_key, prepared.comment_request.dedup_key)
    t.eq(runtime.state().version, 2)
    t.is_true(type(runtime.writes[receipt.receipt_ref]) == "table")
  end,
}
