local core = require("core")
local t = fkst.test

return {
  test_publication_request_uses_artifact_pointer = function()
    local request = core.publication_request({
      schema = "test-artifacts.summary.v1",
      job = "platform-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/platform",
      metadata_path = ".testing/runs/platform/metadata.json",
      source_ref = { kind = "artifact", ref = "run/platform" },
    })
    t.eq(request.schema, "test-publication.publication-request.v1")
    t.eq(request.publication_kind, "testing-summary")
    t.eq(request.channel, "testing")
    t.eq(request.severity, "failure")
    t.eq(request.subject, "Testing failed: platform-test-loop")
    t.eq(request.status, "failed")
    t.eq(request.artifact_root, ".testing/runs/platform")
    t.eq(request.metadata_path, ".testing/runs/platform/metadata.json")
    t.eq(request.source_ref.ref, "run/platform")
    t.eq(request.dedup_key, "artifact-run-platform")
  end,

  test_publication_maps_summary_status_to_severity = function()
    t.eq(core.severity("passed"), "success")
    t.eq(core.severity("failed"), "failure")
    t.eq(core.severity("blocked"), "warning")
    t.eq(core.severity("mixed"), "warning")
    t.eq(core.severity("planned"), "info")
  end,

  test_publication_rejects_unknown_summary_schema = function()
    t.raises(function()
      core.publication_request({ schema = "other", artifact_root = ".testing/runs/x" })
    end)
  end,

  test_publication_rejects_unsafe_artifact_pointer = function()
    t.raises(function()
      core.publication_request({
        schema = "test-artifacts.summary.v1",
        status = "passed",
        artifact_root = "../outside",
      })
    end)
    t.raises(function()
      core.publication_request({
        schema = "test-artifacts.summary.v1",
        status = "passed",
        artifact_root = ".testing/runs/x",
        metadata_path = ".testing/runs/y/metadata.json",
      })
    end)
  end,

  test_publication_rejects_unknown_status = function()
    t.raises(function()
      core.publication_request({
        schema = "test-artifacts.summary.v1",
        status = "surprise",
        artifact_root = ".testing/runs/x",
      })
    end)
  end,
}
