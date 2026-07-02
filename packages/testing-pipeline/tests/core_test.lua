local core = require("core")
local t = fkst.test

local function mutation_policy()
  return {
    schema = "testing-runner.mutation-policy.v1",
    priority = "P2",
    actions = {
      {
        action = "create_test_data",
        target = "local_test_data",
        evidence_path = ".testing/runs/module-a",
        cleanup_path = ".testing/runs/module-a",
      },
    },
  }
end

return {
  test_module_loop_request_preserves_mutation_policy = function()
    local request = core.module_loop_request({
      schema = "testing-pipeline.module-start.v1",
      module = "module-a",
      backend = "fkst-native",
      priority = "P2",
      mutation_policy = mutation_policy(),
      artifact_root = ".testing/runs/module-a",
    })
    t.eq(request.schema, "module-test-loop.start.v1")
    t.eq(request.priority, "P2")
    t.eq(request.mutation_policy.actions[1].action, "create_test_data")
    t.eq(request.mutation_policy.actions[1].cleanup_path, ".testing/runs/module-a")
  end,

  test_module_start_rejects_malformed_mutation_policy = function()
    t.raises(function()
      core.module_loop_request({
        schema = "testing-pipeline.module-start.v1",
        module = "module-a",
        mutation_policy = {
          schema = "testing-runner.mutation-policy.v1",
          actions = {
            {
              action = "create_test_data",
              target = "local_test_data",
              evidence_path = ".testing/runs/module-a",
              cleanup_path = "../outside",
            },
          },
        },
      })
    end)
  end,
}
