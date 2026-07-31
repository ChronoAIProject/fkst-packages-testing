local runtime = require("runtime")
local t = fkst.test

local config_ref = {
  kind = "artifact",
  ref = ".testing/host/environment-factory/runtime-owned-test/config.json",
}

local function with_globals(values, fn)
  local names, previous = {}, {}
  for key, value in pairs(values) do
    table.insert(names, key)
    previous[key] = rawget(_G, key)
    rawset(_G, key, value)
  end
  local ok, result = pcall(fn)
  for _, key in ipairs(names) do rawset(_G, key, previous[key]) end
  if not ok then error(result, 0) end
  return result
end

local function response_decoder(responses)
  local index = 0
  return function()
    index = index + 1
    local response = responses[index]
    if response == nil then error("missing runtime response " .. tostring(index)) end
    return { ok = true, result = response }
  end
end

return {
  test_runtime_owned_listener_plan_rejects_engine_claims = function()
    local application = { name = "application", port = 4173 }
    local responses = {
      {
        profile = { revision = "runtime-profile" }, approval = {}, receipt = {},
        context = {
          now = "2026-07-16T00:00:30Z",
          approval_ref = { kind = "artifact", ref = ".testing/runs/runtime-owned/approval.json" },
          trusted_authorities = {},
        },
      },
      {
        status = "planned",
        needs_claim = { application },
        already_owned = {},
        runtime_owned = true,
      },
    }
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      network_listener = false,
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder(responses) },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      local ports = runtime.production()
      ports.load_authorization_bundle({
        operation_id = "runtime-owned",
        artifact_root = ".testing/runs/runtime-owned",
      })
      t.raises(function()
        ports.authorize_claim_ports({
          artifact_root = ".testing/runs/runtime-owned",
          operation_id = "runtime-owned",
          effect_id = "runtime-owned/environment-factory/port-claim",
          runtime_ports = { application },
          listener_groups = { { application } },
          request_binding = { schema = "binding" },
          authorize = function() return { revision = "runtime-profile" } end,
        })
      end)
    end)
  end,

  test_runtime_owned_listener_plan_runs_supervised_process_without_engine_claim = function()
    local application = { name = "application", port = 4174 }
    local responses = {
      {
        profile = { revision = "runtime-profile" }, approval = {}, receipt = {},
        context = {
          now = "2026-07-16T00:00:30Z",
          approval_ref = { kind = "artifact", ref = ".testing/runs/runtime-owned/approval.json" },
          trusted_authorities = {},
        },
      },
      { status = "planned", needs_claim = {}, already_owned = { application }, runtime_owned = true },
      { found = false },
      { status = "passed", claim_id = "runtime-owned-claim" },
      {
        status = "running",
        cleanup_ref = { kind = "process-cleanup", ref = "runtime-owned-application" },
        early_exit = false,
        runtime_ports = { application },
      },
    }
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      network_listener = false,
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder(responses) },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      local ports = runtime.production()
      local bundle = ports.load_authorization_bundle({
        operation_id = "runtime-owned",
        artifact_root = ".testing/runs/runtime-owned",
      })
      local authorized = ports.authorize_claim_ports({
        artifact_root = ".testing/runs/runtime-owned",
        operation_id = "runtime-owned",
        effect_id = "runtime-owned/environment-factory/port-claim",
        runtime_ports = { application },
        listener_groups = { { application } },
        request_binding = { schema = "binding" },
        authorize = function()
          local claim = bundle.context.replay_guard({ approval_id = "approval" })
          t.eq(claim.claimed, true)
          return { revision = "runtime-profile" }
        end,
      })
      t.eq(authorized.status, "passed")
      local started = ports.run_argv({
        artifact_root = ".testing/runs/runtime-owned",
        operation_id = "runtime-owned",
        effect_id = "runtime-owned/application/start",
        mode = "supervised",
        listener_mode = "fkst-inherited-listeners-v1",
        runtime_ports = { application },
        argv = { "node", "server.js" },
        timeout_seconds = 5,
      })
      t.eq(started.status, "running")
    end)
  end,
}
