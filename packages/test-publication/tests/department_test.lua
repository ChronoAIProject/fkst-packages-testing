local testing = require("testkit.testing")
local dept = require("departments.prepare_publication.main")
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
}
