local core = require("core")
local t = fkst.test

return {
  test_publication_request_uses_artifact_pointer = function()
    local request = core.publication_request({
      schema = "test-artifacts.summary.v1",
      job = "platform-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/platform",
      source_ref = { kind = "artifact", ref = "run/platform" },
    })
    t.eq(request.schema, "test-publication.publication-request.v1")
    t.eq(request.status, "failed")
    t.eq(request.artifact_root, ".testing/runs/platform")
    t.eq(request.source_ref.ref, "run/platform")
  end,

  test_publication_rejects_unknown_summary_schema = function()
    t.raises(function()
      core.publication_request({ schema = "other", artifact_root = ".testing/runs/x" })
    end)
  end,
}
