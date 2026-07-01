local core = require("core")
local t = fkst.test

return {
  test_summary_from_testing_result = function()
    local summary = core.from_testing_result({
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "passed",
      artifact_root = ".testing/runs/module-a",
      source_ref = { kind = "module", ref = "module-a" },
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
    t.eq(summary.source_ref.ref, "module-a")
    t.eq(summary.adapter.name, "fkst-native")
    t.eq(summary.adapter.mode, "module-no-browser")
    t.eq(summary.native_summary.schema, "testing-runner.module-no-browser-summary.v1")
    t.eq(summary.native_summary.module, "module-a")
    t.eq(summary.exit_code, 0)
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
}
