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
  test_summary_from_testing_result = function()
    local summary = core.from_testing_result({
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "passed",
      artifact_root = ".testing/runs/module-a",
      source_ref = { kind = "module", ref = "module-a" },
      trace_id = "trace-module-a",
      dedup_key = "dedup-module-a",
      adapter = { name = "fkst-native", mode = "module-no-browser" },
      native_summary = {
        schema = "testing-runner.module-no-browser-summary.v1",
        module = "module-a",
        status = "passed",
        mode = "argv",
      },
      exit_code = 0,
      stderr_excerpt = "",
    })
    t.eq(summary.schema, "test-artifacts.summary.v1")
    t.eq(summary.job, "module-test-loop")
    t.eq(summary.status, "passed")
    t.eq(summary.artifact_root, ".testing/runs/module-a")
    t.eq(summary.metadata_path, ".testing/runs/module-a/metadata.json")
    t.eq(summary.report_path, ".testing/runs/module-a/dry-run-report.md")
    t.eq(summary.issue_draft_path, ".testing/runs/module-a/issue-draft.md")
    t.eq(summary.source_ref.ref, "module-a")
    t.eq(summary.trace_id, "trace-module-a")
    t.eq(summary.dedup_key, "dedup-module-a")
    t.eq(summary.adapter.name, "fkst-native")
    t.eq(summary.adapter.mode, "module-no-browser")
    t.eq(summary.native_summary.schema, "testing-runner.module-no-browser-summary.v1")
    t.eq(summary.native_summary.module, "module-a")
    t.eq(summary.exit_code, 0)
  end,

  test_failed_native_no_browser_summary_is_golden = function()
    local summary = core.from_testing_result({
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
    })
    assert_payload(summary, {
      schema = "test-artifacts.summary.v1",
      job = "module-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/module-a-failed",
      metadata_path = ".testing/runs/module-a-failed/metadata.json",
      report_path = ".testing/runs/module-a-failed/dry-run-report.md",
      issue_draft_path = ".testing/runs/module-a-failed/issue-draft.md",
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
    })
  end,

  test_browser_driver_readiness_summary_is_bounded_golden = function()
    local summary = core.from_testing_result({
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "blocked",
      artifact_root = ".testing/runs/module-a-browser",
      source_ref = { kind = "host", ref = "module-a-browser" },
      trace_id = "trace-module-a-browser",
      dedup_key = "dedup-module-a-browser",
      adapter = { name = "fkst-native", mode = "browser-driver-envelope" },
      native_summary = {
        schema = "testing-runner.browser-driver-summary.v1",
        module = "module-a",
        driver = "multi_session_browser_harness",
        status = "blocked",
        mode = "readiness-gated-envelope",
        readiness = {
          status = "ready",
          sessions = {
            { role = "base_url", status = "ready" },
            { role = "admin", status = "ready" },
          },
        },
      },
    })
    assert_payload(summary.native_summary, {
      schema = "testing-runner.browser-driver-summary.v1",
      module = "module-a",
      driver = "multi_session_browser_harness",
      status = "blocked",
      mode = "readiness-gated-envelope",
      readiness = {
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready" },
          { role = "admin", status = "ready" },
        },
      },
    })
    t.eq(summary.trace_id, "trace-module-a-browser")
    t.eq(summary.dedup_key, "dedup-module-a-browser")
  end,

  test_missing_trace_and_dedup_are_derived_deterministically = function()
    local result = {
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/module-a-derived",
      source_ref = { kind = "host", ref = "module-a" },
    }
    local first = core.from_testing_result(result)
    local second = core.from_testing_result(result)
    t.eq(first.trace_id, second.trace_id)
    t.eq(first.dedup_key, second.dedup_key)
    t.is_true(first.trace_id:find("trace-", 1, true) == 1)
    t.is_true(first.dedup_key:find("artifact-summary-module-test-loop-host-module-a", 1, true) == 1)
  end,

  test_unknown_result_status_fails_closed_to_blocked = function()
    local summary = core.from_testing_result({
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "unexpected",
      artifact_root = ".testing/runs/module-a",
    })
    t.eq(summary.status, "blocked")
  end,

  test_dry_run_report_lists_qa_handoff_sections_and_pointers = function()
    local summary = core.from_testing_result({
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/module-a-failed",
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a",
      dedup_key = "dedup-module-a-failed",
      native_summary = {
        schema = "testing-runner.module-no-browser-summary.v1",
        module = "module-a",
        status = "failed",
        mode = "argv",
      },
      stderr_excerpt = "check failed",
    })
    local report = core.dry_run_report(summary)
    t.is_true(report:find("# Testing Dry-Run Report", 1, true) ~= nil)
    t.is_true(report:find("## Discovered Modules", 1, true) ~= nil)
    t.is_true(report:find("## Coverage Status", 1, true) ~= nil)
    t.is_true(report:find("## Executed Cases", 1, true) ~= nil)
    t.is_true(report:find("## Skipped Cases", 1, true) ~= nil)
    t.is_true(report:find("## Classifications", 1, true) ~= nil)
    t.is_true(report:find("## Evidence Pointers", 1, true) ~= nil)
    t.is_true(report:find("module-a: failed", 1, true) ~= nil)
    t.is_true(report:find(".testing/runs/module-a-failed/metadata.json", 1, true) ~= nil)
    t.is_true(report:find(".testing/runs/module-a-failed/issue-draft.md", 1, true) ~= nil)
    t.eq(report:find("internal", 1, true), nil)
  end,

  test_issue_draft_is_pointer_only_recommendation = function()
    local summary = core.from_testing_result({
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "failed",
      artifact_root = ".testing/runs/module-a-failed",
      source_ref = { kind = "host", ref = "module-a" },
    })
    local draft = core.issue_draft(summary)
    t.is_true(draft:find("# Dry-Run Issue Recommendation", 1, true) ~= nil)
    t.is_true(draft:find("Evidence pointers:", 1, true) ~= nil)
    t.is_true(draft:find(".testing/runs/module-a-failed/dry-run-report.md", 1, true) ~= nil)
    t.is_true(draft:find(".testing/runs/module-a-failed/metadata.json", 1, true) ~= nil)
  end,

  test_write_dry_run_artifacts_uses_local_writer_only = function()
    local summary = core.from_testing_result({
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "blocked",
      artifact_root = ".testing/runs/module-a-blocked",
      source_ref = { kind = "host", ref = "module-a" },
    })
    local writes = {}
    local ok = core.write_dry_run_artifacts(summary, function(path, body)
      table.insert(writes, { path = path, body = body })
      return true
    end)
    t.eq(ok, true)
    t.eq(#writes, 2)
    t.eq(writes[1].path, ".testing/runs/module-a-blocked/dry-run-report.md")
    t.eq(writes[2].path, ".testing/runs/module-a-blocked/issue-draft.md")
    t.is_true(writes[1].body:find("External publication: skipped", 1, true) ~= nil)
    t.eq(summary.github_issue_url, nil)
    t.eq(summary.comment_url, nil)
  end,

  test_summary_requires_artifact_pointer = function()
    t.raises(function()
      core.validate_summary({ schema = "test-artifacts.summary.v1", status = "passed" })
    end)
  end,

  test_summary_rejects_unsafe_artifact_pointer = function()
    t.raises(function()
      core.validate_summary({
        schema = "test-artifacts.summary.v1",
        status = "passed",
        artifact_root = "../outside",
      })
    end)
    t.raises(function()
      core.validate_summary({
        schema = "test-artifacts.summary.v1",
        status = "passed",
        artifact_root = ".testing/runs/module-a",
        metadata_path = ".testing/runs/other/metadata.json",
      })
    end)
    t.raises(function()
      core.validate_summary({
        schema = "test-artifacts.summary.v1",
        status = "passed",
        artifact_root = ".testing/runs/module-a",
        report_path = ".testing/runs/other/dry-run-report.md",
      })
    end)
  end,

  test_result_with_unbounded_native_summary_is_rejected = function()
    t.raises(function()
      core.from_testing_result({
        schema = "testing-runner.result.v1",
        job = "module-test-loop",
        status = "passed",
        artifact_root = ".testing/runs/module-a",
        native_summary = { nested = { unsafe = true } },
      })
    end)
  end,

  test_browser_driver_readiness_checks_are_rejected = function()
    t.raises(function()
      core.from_testing_result({
        schema = "testing-runner.result.v1",
        job = "module-test-loop",
        status = "blocked",
        artifact_root = ".testing/runs/module-a",
        native_summary = {
          schema = "testing-runner.browser-driver-summary.v1",
          module = "module-a",
          driver = "multi_session_browser_harness",
          status = "blocked",
          mode = "readiness-gated-envelope",
          readiness = {
            status = "ready",
            sessions = {
              { role = "admin", status = "ready", checks = { { name = "local_http", status = "ready" } } },
            },
          },
        },
      })
    end)
  end,
}
