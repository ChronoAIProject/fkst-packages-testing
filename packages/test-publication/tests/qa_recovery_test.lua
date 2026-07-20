local qa_publication = require("qa_publication")
local t = fkst.test

local commit_sha = string.rep("1", 40)
local artifact_sha = string.rep("a", 64)

local function request(stage)
  return {
    schema = "test-publication.qa-checkpoint.request.v1",
    repository = { slug = "owner/repo", commit_sha = commit_sha },
    run_id = "qa-recovery", issue_number = 107, stage = stage or "environment-ready",
    attempt = 1, status = "passed", artifact_root = ".testing/runs/qa-recovery",
    artifact_ref = ".testing/runs/qa-recovery/" .. (stage or "environment-ready") .. ".json",
    artifact_sha256 = artifact_sha, ledger_ref = ".testing/runs/qa-recovery/run-ledger.json",
    trace_id = "trace-recovery", dedup_key = "dedup-recovery",
  }
end

local function runtime(options)
  options = options or {}
  local state
  local saves, writes, publishes = 0, 0, 0
  return {
    load_ledger = function() return state end,
    save_ledger = function(_, value, expected)
      saves = saves + 1
      if options.cas_failure then return false end
      if state ~= nil and state.version ~= expected then return false end
      if state == nil and expected ~= 0 then return false end
      state = value return true
    end,
    publish_artifact = function(value)
      publishes = publishes + 1
      if options.publish_failure then return { status = "blocked" } end
      return {
        status = "published", digest = value.digest, source_commit = commit_sha,
        remote_url = "https://github.com/owner/repo/blob/" .. commit_sha .. "/qa/" .. value.stage .. ".json",
        receipt_ref = ".testing/runs/qa-recovery/publication/" .. value.stage .. "-1.json",
      }
    end,
    write_artifact = function()
      writes = writes + 1
      return options.write_failure ~= true
    end,
    state = function() return state end,
    counts = function() return saves, writes, publishes end,
  }
end

return {
  test_checkpoint_validation_rejects_malformed_identity_binding_and_counts = function()
    local mutations = {
      function(value) value.schema = "unknown" end,
      function(value) value.repository.slug = "bad" end,
      function(value) value.stage = "unknown" end,
      function(value) value.artifact_ref = ".testing/runs/foreign/value.json" end,
      function(value) value.counts = { planned = -1 } end,
    }
    for _, mutate in ipairs(mutations) do
      local value = request()
      mutate(value)
      t.raises(function() qa_publication.validate_checkpoint_request(value) end)
    end
  end,

  test_partial_publication_and_cas_failure_leave_no_effective_checkpoint = function()
    local publish_failure = runtime({ publish_failure = true })
    t.raises(function() qa_publication.prepare_checkpoint(request(), publish_failure) end)
    local saves = publish_failure.counts()
    t.eq(saves, 0)

    local cas_failure = runtime({ cas_failure = true })
    t.raises(function() qa_publication.prepare_checkpoint(request(), cas_failure) end)
  end,

  test_stale_transition_and_changed_replay_fail_closed = function()
    local ports = runtime()
    qa_publication.prepare_checkpoint(request("environment-ready"), ports)
    t.raises(function() qa_publication.prepare_checkpoint(request("intake"), ports) end)

    local changed = request("environment-ready")
    changed.artifact_sha256 = string.rep("b", 64)
    t.raises(function() qa_publication.prepare_checkpoint(changed, ports) end)

    local moved = request("environment-ready")
    moved.artifact_ref = moved.artifact_root .. "/other.json"
    t.raises(function() qa_publication.prepare_checkpoint(moved, ports) end)

    local changed_counts = request("environment-ready")
    changed_counts.counts = { planned = 1 }
    t.raises(function() qa_publication.prepare_checkpoint(changed_counts, ports) end)
  end,

  test_checkpoint_replay_compares_all_count_fields = function()
    local ports = runtime()
    local value = request("execution-batch")
    value.counts = { planned = 2, executed = 2, passed = 1, failed = 1 }
    qa_publication.prepare_checkpoint(value, ports)

    local replay = request("execution-batch")
    replay.counts = { planned = 2, executed = 2, passed = 1, failed = 1 }
    t.eq(qa_publication.prepare_checkpoint(replay, ports).replayed, true)

    replay.counts.blocked = 0
    t.raises(function() qa_publication.prepare_checkpoint(replay, ports) end)
  end,

  test_comment_ack_replay_does_not_write_second_receipt = function()
    local ports = runtime()
    local prepared = qa_publication.prepare_checkpoint(request(), ports)
    local written = {
      schema = "github-proxy.comment-written.v1", comment_id = "501",
      request_dedup_key = prepared.comment_request.dedup_key,
      handoff = prepared.comment_request.handoff,
    }
    local first = qa_publication.acknowledge_comment(written, ports)
    local second = qa_publication.acknowledge_comment(written, ports)
    t.eq(second.receipt_ref, first.receipt_ref)
    local _, writes = ports.counts()
    t.eq(writes, 1)
  end,

  test_receipt_write_failure_does_not_mark_checkpoint_published = function()
    local ports = runtime({ write_failure = true })
    local prepared = qa_publication.prepare_checkpoint(request(), ports)
    t.raises(function()
      qa_publication.acknowledge_comment({
        schema = "github-proxy.comment-written.v1", comment_id = "501",
        request_dedup_key = prepared.comment_request.dedup_key,
        handoff = prepared.comment_request.handoff,
      }, ports)
    end)
    t.eq(ports.state().checkpoints["environment-ready/1"].receipt, nil)
  end,

  test_malformed_and_mismatched_comment_acknowledgements_fail_closed = function()
    local ports = runtime()
    local prepared = qa_publication.prepare_checkpoint(request(), ports)
    t.raises(function() qa_publication.acknowledge_comment({}, ports) end)
    t.raises(function()
      qa_publication.acknowledge_comment({
        schema = "github-proxy.comment-written.v1", comment_id = "501",
        request_dedup_key = "foreign",
        handoff = prepared.comment_request.handoff,
      }, ports)
    end)
  end,

  test_production_ports_fail_closed_and_accept_complete_runtime = function()
    _G.qa_publication_runtime = nil
    t.raises(function() qa_publication.production_ports() end)
    local ports = {}
    for _, name in ipairs({ "load_ledger", "save_ledger", "publish_artifact", "write_artifact", "write_report", "load_artifact" }) do
      ports[name] = function() return true end
    end
    _G.qa_publication_runtime = ports
    t.eq(qa_publication.production_ports(), ports)
    _G.qa_publication_runtime = nil
  end,
}
