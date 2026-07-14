local testing = require("testkit.testing")
local dept = require("departments.prepare_publication.main")
local dry_run = require("departments.dry_run.main")
local t = fkst.test

return {
  test_prepare_publication_department_raises_publication_request_golden = function()
    local trace = testing.run_fake(dept, {
      queue = "artifact_summary",
      payload = {
        schema = "test-artifacts.summary.v1",
        job = "module-test-loop",
        status = "blocked",
        artifact_root = ".testing/runs/module-a-blocked",
        metadata_path = ".testing/runs/module-a-blocked/metadata.json",
        source_ref = { kind = "host", ref = "module-a" },
        trace_id = "trace-module-a",
        dedup_key = "dedup-module-a-blocked",
        adapter = { name = "fkst-native", mode = "legacy-cli-blocked" },
        stderr_excerpt = "blocked before execution",
      },
    })
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "publication_request")
    local request = trace.raises[1].payload
    t.eq(request.schema, "test-publication.publication-request.v1")
    t.eq(request.publication_kind, "testing-summary")
    t.eq(request.channel, "testing")
    t.eq(request.severity, "warning")
    t.eq(request.subject, "Testing blocked: module-test-loop")
    t.eq(request.trace_id, "trace-module-a")
    t.eq(request.dedup_key, "dedup-module-a-blocked")
    t.eq(request.status, "blocked")
    t.eq(request.artifact_root, ".testing/runs/module-a-blocked")
    t.eq(request.metadata_path, ".testing/runs/module-a-blocked/metadata.json")
    t.eq(request.adapter, nil)
    t.eq(request.stderr_excerpt, nil)
  end,

  test_dry_run_department_persists_receipt_without_external_operation = function()
    local root = ".testing/runs/test-publication-dry-run-department"
    local removed = os.execute("rm -rf '" .. root .. "'")
    assert(removed == true or removed == 0)
    local trace = testing.run_fake(dry_run, {
      queue = "publication_request",
      payload = {
        schema = "test-publication.publication-request.v1",
        publication_kind = "testing-summary",
        channel = "testing",
        severity = "success",
        subject = "Testing passed: platform-test-loop",
        trace_id = "trace-platform-final",
        dedup_key = "platform-final-run",
        status = "passed",
        job = "platform-test-loop",
        artifact_root = root,
        source_ref = { kind = "platform", ref = "platform-final" },
        final_report_path = root .. "/final-report.md",
        publication_mode = "artifact-only",
        publication_dry_run = true,
      },
    })
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "dry_run_receipt")
    t.eq(trace.raises[1].payload.external_operation, false)
  end,

  test_dry_run_department_ignores_normal_publication_requests = function()
    local trace = testing.run_fake(dry_run, {
      queue = "publication_request",
      payload = { schema = "test-publication.publication-request.v1" },
    })
    t.eq(#trace.raises, 0)
  end,
}
