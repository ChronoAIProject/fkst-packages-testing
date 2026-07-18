local ports_module = require("ports")
local t = fkst.test

local function with_globals(values, fn)
  local names, old = {}, {}
  for key, value in pairs(values) do
    table.insert(names, key)
    old[key] = rawget(_G, key)
    rawset(_G, key, value)
  end
  local ok, result = pcall(fn)
  for _, key in ipairs(names) do rawset(_G, key, old[key]) end
  if not ok then error(result, 0) end
  return result
end

return {
  test_json_encoder_covers_scalars_arrays_objects_and_escaping = function()
    t.eq(ports_module.encode_json(nil), "null")
    t.eq(ports_module.encode_json(true), "true")
    t.eq(ports_module.encode_json(7), "7")
    t.eq(ports_module.encode_json("a\nb"), '"a\\nb"')
    t.eq(ports_module.encode_json({ "a", "b" }), '["a","b"]')
    t.eq(ports_module.encode_json({ b = 2, a = 1 }), '{"a":1,"b":2}')
    t.raises(function() ports_module.encode_json(function() end) end)
    t.raises(function() ports_module.encode_json({ [2] = "sparse" }) end)
  end,

  test_default_state_ports_use_authenticated_runtime_adapter = function()
    local response = { ok = true, result = { authenticated = true, state = { schema = "state" } } }
    with_globals({
      environment_factory_runtime = nil,
      environment_factory_runtime_config_ref = {
        kind = "artifact",
        ref = ".testing/host/environment-factory/ports-test/config.json",
      },
      exec_argv = function() return { exit_code = 0 } end,
      file = {
        read = function() return "response" end,
        write = function(path, body)
          t.is_true(path:find("runtime-io", 1, true) ~= nil)
          t.is_true(body:find('"runtime_config_ref"', 1, true) ~= nil)
        end,
      },
      json = { decode = function(body) t.eq(body, "response"); return response end },
    }, function()
      local ports = ports_module.production()
      local envelope = ports.load_state({ kind = "artifact", ref = ".testing/runs/x/operation-state.json" })
      t.eq(envelope.authenticated, true)
      t.eq(envelope.state.schema, "state")
      response = { ok = true, result = { saved = true, revision = 1 } }
      local saved = ports.save_state(
        { kind = "artifact", ref = ".testing/runs/x/operation-state.json" },
        { schema = "state" },
        0
      )
      t.eq(saved.saved, true)
      t.eq(saved.revision, 1)
    end)
  end,

  test_default_runtime_fails_without_host_capabilities = function()
    with_globals({
      environment_factory_runtime = nil,
      environment_factory_runtime_config_ref = nil,
      exec_argv = false,
      file = false,
      json = false,
    }, function()
      local ports = ports_module.production()
      t.raises(function()
        ports.load_state({ kind = "artifact", ref = ".testing/runs/x/operation-state.json" })
      end)
      t.raises(function()
        ports.save_state({ kind = "artifact", ref = ".testing/runs/x/operation-state.json" }, {})
      end)
    end)
  end,

  test_incomplete_host_runtime_fails_closed_per_port = function()
    with_globals({ environment_factory_runtime = {} }, function()
      local ports = ports_module.production()
      t.raises(function() ports.load_state() end)
      t.raises(function() ports.checkout() end)
    end)
  end,

  test_host_runtime_is_preferred_and_resolve_rejects_missing_methods = function()
    local host = {}
    for _, name in ipairs({
      "load_state", "save_state", "load_authorization_bundle", "authorize_claim_ports", "checkout",
      "remaining_budget", "create_readiness_attempt", "run_argv", "wait_readiness", "cleanup", "write_receipt",
    }) do host[name] = function() return name end end
    with_globals({ environment_factory_runtime = host }, function()
      local ports = ports_module.production()
      t.eq(ports.checkout(), "checkout")
      t.eq(ports.load_state(), "load_state")
    end)
    t.raises(function() ports_module.resolve({ load_state = function() end }) end)
    t.eq(ports_module.resolve(host), host)
  end,
}
