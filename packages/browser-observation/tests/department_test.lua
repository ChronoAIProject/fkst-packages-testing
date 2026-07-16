local core = require("core")
local dept = require("departments.observe.main")
local testing = require("testkit.testing")
local t = fkst.test

local function with_result_reader(reader, fn)
  local original = core.result
  core.result = function(payload)
    return original(payload, reader)
  end
  local ok, result = pcall(fn)
  core.result = original
  if not ok then error(result, 0) end
  return result
end

return {
  test_observe_department_declares_and_raises_browser_observation_contract = function()
    t.eq(#dept.spec.consumes, 1)
    t.eq(dept.spec.consumes[1], "browser_observation_observe")
    t.eq(#dept.spec.produces, 1)
    t.eq(dept.spec.produces[1], "browser_observation_result")

    local trace = with_result_reader(function(path)
      t.eq(path, ".testing/runs/observation/observer/observations.json")
      return '{"schema":"browser-observation.observations.v1","observation_count":2,"observations":[]}'
    end, function()
      return testing.run_fake(dept, {
        queue = "browser_observation_observe",
        payload = {
          schema = "browser-observation.observe.v1",
          base_url = "http://127.0.0.1:4312",
          artifact_root = ".testing/runs/observation",
          source_ref = { kind = "host-observation", ref = "observation-request" },
          trace_id = "trace-observation",
          dedup_key = "dedup-observation",
        },
      })
    end)

    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "browser_observation_result")
    local result = trace.raises[1].payload
    t.eq(result.schema, "browser-observation.result.v1")
    t.eq(result.status, "passed")
    t.eq(result.observation_count, 2)
    t.eq(result.artifact_root, ".testing/runs/observation")
    t.eq(result.observation_path, ".testing/runs/observation/observer/observations.json")
    t.eq(result.source_ref.kind, "host-observation")
    t.eq(result.source_ref.ref, "observation-request")
    t.eq(result.trace_id, "trace-observation")
    t.eq(result.dedup_key, "dedup-observation")
    core.validate_result(result)
  end,

  test_observe_department_rejects_malformed_input_without_raising_success = function()
    local trace = testing.run_fake_expecting_failure(dept, {
      queue = "browser_observation_observe",
      payload = {},
    })
    t.eq(#trace.raises, 0)
    t.is_true(tostring(trace.failure.error):find("unknown-schema", 1, true) ~= nil)
  end,
}
