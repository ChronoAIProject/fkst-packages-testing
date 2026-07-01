local core = require("core")
local t = fkst.test

local function assert_payload(actual, expected)
  t.eq(type(actual), "table")
  for key, expected_value in pairs(expected) do
    if type(expected_value) == "table" then
      assert_payload(actual[key], expected_value)
    else
      t.eq(actual[key], expected_value)
    end
  end
  for key, _ in pairs(actual) do
    t.is_true(expected[key] ~= nil)
  end
end

return {
  test_publication_request_uses_artifact_pointer = function()
    local request = core.publication_request({
      schema = "test-artifacts.summary.v1",
      job = "platform-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/platform",
      metadata_path = ".testing/runs/platform/metadata.json",
      source_ref = { kind = "artifact", ref = "run/platform" },
      trace_id = "trace-platform",
      dedup_key = "dedup-platform",
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
    t.eq(request.trace_id, "trace-platform")
    t.eq(request.dedup_key, "dedup-platform")
  end,

  test_failed_publication_request_is_golden_and_pointer_only = function()
    local request = core.publication_request({
      schema = "test-artifacts.summary.v1",
      job = "module-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/module-a-failed",
      metadata_path = ".testing/runs/module-a-failed/metadata.json",
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
      stderr_excerpt = "check failed",
    })
    assert_payload(request, {
      schema = "test-publication.publication-request.v1",
      publication_kind = "testing-summary",
      channel = "testing",
      severity = "failure",
      subject = "Testing failed: module-test-loop",
      trace_id = "trace-module-a",
      dedup_key = "dedup-module-a-failed",
      status = "failed",
      job = "module-test-loop",
      artifact_root = ".testing/runs/module-a-failed",
      metadata_path = ".testing/runs/module-a-failed/metadata.json",
      source_ref = { kind = "host", ref = "module-a" },
    })
  end,

  test_blocked_publication_request_is_golden = function()
    local request = core.publication_request({
      schema = "test-artifacts.summary.v1",
      job = "online-regression",
      status = "blocked",
      artifact_root = ".testing/runs/preflight-blocked",
      metadata_path = ".testing/runs/preflight-blocked/metadata.json",
      source_ref = { kind = "host", ref = "preflight-blocked" },
      trace_id = "trace-preflight-blocked",
      dedup_key = "dedup-preflight-blocked",
    })
    assert_payload(request, {
      schema = "test-publication.publication-request.v1",
      publication_kind = "testing-summary",
      channel = "testing",
      severity = "warning",
      subject = "Testing blocked: online-regression",
      trace_id = "trace-preflight-blocked",
      dedup_key = "dedup-preflight-blocked",
      status = "blocked",
      job = "online-regression",
      artifact_root = ".testing/runs/preflight-blocked",
      metadata_path = ".testing/runs/preflight-blocked/metadata.json",
      source_ref = { kind = "host", ref = "preflight-blocked" },
    })
  end,

  test_publication_derives_ids_deterministically_when_missing = function()
    local summary = {
      schema = "test-artifacts.summary.v1",
      job = "module-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/module-a-derived",
      metadata_path = ".testing/runs/module-a-derived/metadata.json",
      source_ref = { kind = "host", ref = "module-a" },
    }
    local first = core.publication_request(summary)
    local second = core.publication_request(summary)
    t.eq(first.trace_id, second.trace_id)
    t.eq(first.dedup_key, second.dedup_key)
    t.is_true(first.trace_id:find("trace-", 1, true) == 1)
    t.is_true(first.dedup_key:find("testing-summary-testing-module-test-loop-host-module-a", 1, true) == 1)
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
