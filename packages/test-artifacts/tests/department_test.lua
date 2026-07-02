local testing = require("testkit.testing")
local dept = require("departments.summarize.main")
local t = fkst.test

return {
  test_summarize_department_raises_artifact_summary_golden = function()
    local writes = {}
    local trace = testing.run_fake(dept, {
      queue = "testing_result",
      payload = {
        schema = "testing-runner.result.v1",
        job = "module-test-loop",
        status = "failed",
        artifact_root = ".testing/runs/module-a-failed",
        source_ref = { kind = "host", ref = "module-a" },
        trace_id = "trace-module-a",
        dedup_key = "dedup-module-a-failed",
        adapter = { name = "fkst-native", mode = "module-no-browser" },
        native_summary = {
          schema = "testing-runner.module-no-browser-summary.v1",
          module = "module-a",
          status = "failed",
          mode = "argv",
        },
        exit_code = 3,
        stderr_excerpt = "check failed",
        artifact_writer = function(path, body)
          table.insert(writes, { path = path, body = body })
          return true
        end,
      },
    })
    t.eq(#writes, 2)
    t.eq(writes[1].path, ".testing/runs/module-a-failed/dry-run-report.md")
    t.eq(writes[2].path, ".testing/runs/module-a-failed/issue-draft.md")
    t.is_true(writes[1].body:find("Testing Dry-Run Report", 1, true) ~= nil)
    t.is_true(writes[2].body:find("Dry-Run Issue Recommendation", 1, true) ~= nil)
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "artifact_summary")
    local summary = trace.raises[1].payload
    t.eq(summary.schema, "test-artifacts.summary.v1")
    t.eq(summary.status, "failed")
    t.eq(summary.artifact_root, ".testing/runs/module-a-failed")
    t.eq(summary.metadata_path, ".testing/runs/module-a-failed/metadata.json")
    t.eq(summary.report_path, ".testing/runs/module-a-failed/dry-run-report.md")
    t.eq(summary.issue_draft_path, ".testing/runs/module-a-failed/issue-draft.md")
    t.eq(summary.source_ref.ref, "module-a")
    t.eq(summary.trace_id, "trace-module-a")
    t.eq(summary.dedup_key, "dedup-module-a-failed")
    t.eq(summary.native_summary.mode, "argv")
    t.eq(summary.exit_code, 3)
    t.eq(summary.stderr_excerpt, "check failed")
  end,
}
