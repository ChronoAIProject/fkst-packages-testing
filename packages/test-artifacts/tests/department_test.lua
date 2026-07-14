local testing = require("testkit.testing")
local dept = require("departments.summarize.main")
local t = fkst.test

return {
  test_summarize_department_raises_artifact_summary_golden = function()
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
      },
    })
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "artifact_summary")
    local summary = trace.raises[1].payload
    t.eq(summary.schema, "test-artifacts.summary.v1")
    t.eq(summary.status, "failed")
    t.eq(summary.artifact_root, ".testing/runs/module-a-failed")
    t.eq(summary.metadata_path, ".testing/runs/module-a-failed/metadata.json")
    t.eq(summary.source_ref.ref, "module-a")
    t.eq(summary.trace_id, "trace-module-a")
    t.eq(summary.dedup_key, "dedup-module-a-failed")
    t.eq(summary.native_summary.mode, "argv")
    t.eq(summary.exit_code, 3)
    t.eq(summary.stderr_excerpt, "check failed")
  end,

  test_summarize_department_persists_final_report = function()
    local root = ".testing/runs/test-artifacts-final-department"
    local removed = os.execute("rm -rf '" .. root .. "'")
    assert(removed == true or removed == 0)
    local created = os.execute("mkdir -p '" .. root .. "/.rendered'")
    assert(created == true or created == 0)
    local handle = assert(io.open(root .. "/.rendered/final-aggregate-report.md", "w"))
    assert(handle:write("# Final report\n"))
    handle:close()

    local trace = testing.run_fake(dept, {
      queue = "testing_result",
      payload = {
        schema = "testing-runner.final-aggregate-report.v1",
        job = "platform-test-loop",
        status = "passed",
        artifact_root = root,
        metadata_path = root .. "/metadata.json",
        rendered_report_path = root .. "/.rendered/final-aggregate-report.md",
        final_report_path = root .. "/final-report.md",
        source_ref = { kind = "platform", ref = "platform-final" },
        trace_id = "trace-platform-final",
        dedup_key = "platform-final-run",
        publication_mode = "artifact-only",
        publication_dry_run = true,
      },
    })
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].payload.final_report_path, root .. "/final-report.md")
    local final = assert(io.open(root .. "/final-report.md", "r"))
    t.eq(final:read("*a"), "# Final report\n")
    final:close()
  end,
}
