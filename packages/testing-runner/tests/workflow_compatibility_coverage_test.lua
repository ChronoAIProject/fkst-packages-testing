local workflow_env = require("workflow.env")
local workflow_logging = require("workflow.logging")
local workflow_ports = require("workflow.ports")
local restart_liveness = require("workflow.restart_liveness_contract")
local saga = require("workflow.saga")
local t = fkst.test

local function valid_spec()
  return {
    consumes = { "request" },
    produces = { "result" },
    stall_window = "1m",
  }
end

return {
  test_environment_reader_supports_direct_and_bound_forms = function()
    local command
    local value = workflow_env.read_env("TOKEN", function(argument)
      command = argument
      return { exit_code = 0, stdout = "value", stderr = "" }
    end, function(name)
      return "read:" .. name
    end)
    t.eq(command, "read:TOKEN")
    t.eq(value, "value")

    local reader = workflow_env.read_env(function(name)
      return "bound:" .. name
    end, { propagate_exec_errors = true })
    t.eq(reader("TOKEN", function(argument)
      t.eq(argument, "bound:TOKEN")
      return { exit_code = 0, stdout = "bound-value", stderr = "" }
    end), "bound-value")
    t.eq(reader("TOKEN", function()
      return { exit_code = 1, stdout = "", stderr = "failed" }
    end), nil)

    t.eq(workflow_env.read_env("TOKEN", function() error("read failed") end, function(name) return name end), nil)
    t.eq(workflow_env.read_env("TOKEN", function() return {} end, nil), nil)
  end,

  test_logging_helpers_cover_validation_and_unidentified_failures = function()
    t.raises(function() workflow_logging.wrap_pipeline_failure("coverage", nil) end)
    t.eq(workflow_logging.payload_field(nil, "key"), nil)
    t.eq(workflow_logging.payload_field({ key = "value" }, "key"), "value")

    local captured = {}
    local previous_error = log.error
    log.error = function(message) table.insert(captured, tostring(message)) end
    workflow_logging.log_entry("coverage", "entry", {}, nil, "dedup")
    local wrapped = workflow_logging.wrap_pipeline_failure("coverage", function()
      error("coverage: forced-failure: expected")
    end)
    local ok, err = pcall(wrapped, nil)
    log.error = previous_error
    t.eq(ok, false)
    t.is_true(tostring(err):find("forced-failure", 1, true) ~= nil)
    t.eq(#captured, 1)
    t.is_true(captured[1]:find("proposal_id=unknown", 1, true) ~= nil)
  end,

  test_workflow_port_validation_fails_closed = function()
    t.raises(function() workflow_ports.require_ports({ workflow_ports = {} }, "unknown-group") end)
    t.raises(function() workflow_ports.require_ports(nil, "owner", {}) end)
    t.raises(function() workflow_ports.require_ports({}, "owner", {}) end)
    t.raises(function()
      workflow_ports.require_ports({ workflow_ports = {} }, "owner", { "unknown-port" })
    end)
    t.raises(function()
      workflow_ports.require_ports(
        { workflow_ports = {} },
        "owner",
        { workflow_ports.names.dependency_release_marker }
      )
    end)
  end,

  test_restart_liveness_requires_installation = function()
    t.raises(function()
      restart_liveness.restart_liveness_inventory_errors({}, {}, {})
    end)
  end,

  test_saga_department_validates_required_shape = function()
    t.raises(function() saga.department(nil, nil) end)
    t.raises(function() saga.department({}, nil) end)
    t.raises(function() saga.department(valid_spec(), nil) end)
    t.raises(function() saga.department(valid_spec(), {}) end)
    t.raises(function()
      saga.department(valid_spec(), { done = function() return false end })
    end)
  end,
}
