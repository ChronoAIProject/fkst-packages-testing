local department = require("departments.record_qa_checkpoint.main")
local testing = require("testkit.testing")
local t = fkst.test

return {
  test_checkpoint_department_raises_namespaced_github_comment_request = function()
    local state
    local trace = testing.run_fake(department, {
      queue = "qa_checkpoint_request",
      test_ports = {
        load_ledger = function() return state end,
        save_ledger = function(_, value) state = value return true end,
        publish_artifact = function(value)
          return {
            status = "published",
            remote_url = "https://github.com/owner/repo/blob/" .. string.rep("1", 40) .. "/qa/intake.json",
            digest = value.digest,
            source_commit = string.rep("1", 40),
            receipt_ref = ".testing/runs/qa-run-107/publication/intake-1.json",
          }
        end,
        write_artifact = function() return true end,
        load_artifact = function() return nil end,
      },
      payload = {
        schema = "test-publication.qa-checkpoint.request.v1",
        repository = { slug = "owner/repo", commit_sha = string.rep("1", 40) },
        run_id = "qa-run-107", issue_number = 107, stage = "intake", attempt = 1, status = "passed",
        artifact_root = ".testing/runs/qa-run-107",
        artifact_ref = ".testing/runs/qa-run-107/intake.json",
        artifact_sha256 = string.rep("a", 64),
        ledger_ref = ".testing/runs/qa-run-107/run-ledger.json",
        trace_id = "trace-qa-run-107", dedup_key = "dedup-qa-run-107",
      },
    })

    t.eq(trace.raises[1].queue, "github_issue_comment_request")
    t.eq(trace.raises[1].payload.schema, "github-proxy.v1")
    t.eq(trace.raises[1].payload.handoff.kind, "test-publication.qa-checkpoint")
  end,

  test_filesystem_checkpoint_department_emits_receipt_without_github_request = function()
    local state
    local writes, artifacts = {}, {}
    local root = ".testing/runs/qa-run-filesystem"
    local trace = testing.run_fake(department, {
      queue = "qa_checkpoint_request",
      ["test_" .. "ports"] = {
        load_ledger = function() return state end,
        save_ledger = function(_, value) state = value return true end,
        publish_artifact = function(value)
          local receipt_ref = root .. "/materializations/intake-1.json"
          local receipt_sha256 = string.rep("b", 64)
          artifacts[receipt_ref] = { digest = receipt_sha256, value = {
            schema = "test-publication.qa-materialization-receipt.v1",
            status = "materialized", channel = "filesystem-dry-run-v1",
            run_id = value.run_id, stage = value.stage, attempt = value.attempt,
            artifact_ref = value.artifact_ref, digest = value.digest,
            source_commit = string.rep("1", 40), receipt_ref = receipt_ref,
            trace_id = value.trace_id, dedup_key = value.dedup_key,
          } }
          return {
            status = "materialized", artifact_ref = value.artifact_ref,
            digest = value.digest, source_commit = string.rep("1", 40),
            receipt_ref = receipt_ref, receipt_sha256 = receipt_sha256,
          }
        end,
        load_artifact = function(path) return artifacts[path] end,
        write_artifact = function(path, value) writes[path] = value return true end,
      },
      payload = {
        schema = "test-publication.qa-checkpoint.request.v1",
        channel = "filesystem-dry-run-v1",
        repository = { slug = "owner/repo", commit_sha = string.rep("1", 40) },
        run_id = "qa-run-filesystem", issue_number = 107, stage = "intake", attempt = 1, status = "passed",
        artifact_root = root, artifact_ref = root .. "/intake.json",
        artifact_sha256 = string.rep("a", 64), ledger_ref = root .. "/run-ledger.json",
        trace_id = "trace-qa-run-filesystem", dedup_key = "dedup-qa-run-filesystem",
      },
    })

    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "qa_publication_receipt")
    t.eq(trace.raises[1].payload.channel, "filesystem-dry-run-v1")
    t.eq(trace.raises[1].payload.github_publication_occurred, false)
    t.is_true(type(writes[trace.raises[1].payload.receipt_ref]) == "table")
  end,
}
