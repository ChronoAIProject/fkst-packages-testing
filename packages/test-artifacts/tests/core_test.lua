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

local function expected_evidence_bundle(root)
  return {
    schema = "testing-runner.native-evidence-pointers.v1",
    actions_path = root .. "/evidence/actions.json",
    bundle_path = root .. "/evidence/bundle.json",
    console_path = root .. "/evidence/console.json",
    discovery_path = root .. "/evidence/discovery.json",
    dom_state_path = root .. "/evidence/dom_state.json",
    execution_path = root .. "/evidence/execution.json",
    failures_path = root .. "/evidence/failures.json",
    network_path = root .. "/evidence/network.json",
    observations_path = root .. "/evidence/observations.json",
    planning_path = root .. "/evidence/planning.json",
    screenshots_path = root .. "/evidence/screenshots.json",
    skipped_path = root .. "/evidence/skipped.json",
    trace_path = root .. "/evidence/trace.json",
    urls_path = root .. "/evidence/urls.json",
  }
end

return {
  test_summary_from_testing_result = function()
    local summary = core.from_testing_result({
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "passed",
      artifact_root = ".testing/runs/module-a",
      evidence_bundle = expected_evidence_bundle(".testing/runs/module-a"),
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
    t.eq(summary.evidence_bundle.bundle_path, ".testing/runs/module-a/evidence/bundle.json")
    t.eq(summary.evidence_bundle.actions_path, ".testing/runs/module-a/evidence/actions.json")
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
      evidence_bundle = expected_evidence_bundle(".testing/runs/module-a-failed"),
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
      evidence_bundle = expected_evidence_bundle(".testing/runs/module-a-failed"),
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
  end,

  test_result_rejects_mismatched_evidence_bundle_pointer = function()
    local bundle = expected_evidence_bundle(".testing/runs/module-a")
    bundle.bundle_path = ".testing/runs/other/evidence/bundle.json"
    t.raises(function()
      core.from_testing_result({
        schema = "testing-runner.result.v1",
        job = "module-test-loop",
        status = "passed",
        artifact_root = ".testing/runs/module-a",
        evidence_bundle = bundle,
      })
    end)
  end,

  test_summary_rejects_evidence_bundle_extra_fields = function()
    local bundle = expected_evidence_bundle(".testing/runs/module-a")
    bundle.console_body = "inline console"
    t.raises(function()
      core.validate_summary({
        schema = "test-artifacts.summary.v1",
        job = "module-test-loop",
        status = "passed",
        artifact_root = ".testing/runs/module-a",
        evidence_bundle = bundle,
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
