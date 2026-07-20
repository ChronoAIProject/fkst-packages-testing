local department = require("departments.acknowledge_qa_publication.main")
local testing = require("testkit.testing")
local t = fkst.test

return {
  test_host_comment_receipt_emits_durable_qa_publication_receipt = function()
    local ledger = {
      schema = "test-publication.qa-run-ledger.v1", version = 1,
      repository = { slug = "owner/repo", commit_sha = string.rep("1", 40) },
      run_id = "qa-run-ack", issue_number = 107, artifact_root = ".testing/runs/qa-run-ack",
      ledger_ref = ".testing/runs/qa-run-ack/run-ledger.json", trace_id = "trace-ack", dedup_key = "dedup-ack",
      latest_stage_rank = 10,
      checkpoints = {
        ["intake/1"] = {
          stage = "intake", attempt = 1, status = "passed", artifact_sha256 = string.rep("a", 64),
          publication = { remote_url = "https://github.com/owner/repo/blob/" .. string.rep("1", 40) .. "/qa/intake.json" },
          comment_request = { dedup_key = "dedup-ack/checkpoint/intake/1/" .. string.rep("a", 64) },
        },
      },
    }
    local trace = testing.run_fake(department, {
      queue = "github_comment_written",
      test_ports = {
        load_ledger = function() return ledger end,
        save_ledger = function(_, value) ledger = value return true end,
        write_artifact = function() return true end,
      },
      payload = {
        schema = "github-proxy.comment-written.v1", repo = "owner/repo", target = "issue",
        issue_number = 107, comment_id = "501",
        request_dedup_key = ledger.checkpoints["intake/1"].comment_request.dedup_key,
        dedup_key = "written-501",
        handoff = {
          kind = "test-publication.qa-checkpoint", ledger_ref = ledger.ledger_ref,
          run_id = ledger.run_id, stage = "intake", attempt = 1,
        },
      },
    })

    t.eq(trace.raises[1].queue, "qa_publication_receipt")
    t.eq(trace.raises[1].payload.status, "published")
    t.eq(trace.raises[1].payload.comment_id, "501")
  end,
}
