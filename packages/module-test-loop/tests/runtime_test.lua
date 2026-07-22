local codec = require("testing_runtime.json")
local ports_module = require("ports")
local runtime = require("runtime")
local t = fkst.test

local function expect_failure(fragment, fn)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(fragment, 1, true) ~= nil)
end

local function with_globals(values, fn)
  local previous = {}
  for name, value in pairs(values) do
    previous[name] = { value = rawget(_G, name) }
    rawset(_G, name, value)
  end
  local ok, result = pcall(fn)
  for name, entry in pairs(previous) do rawset(_G, name, entry.value) end
  if not ok then error(result, 0) end
  return result
end

return {
  test_production_runtime_maps_node_envelopes_and_failures = function()
    local responses = {
      ["load-state"] = { ok = true, found = true, result = { version = 1 } },
      ["save-state"] = { ok = true, saved = true },
      ["list-pending-states"] = { ok = true, result = { ".testing/runs/a/module-loop-state.json" } },
      ["artifact-digest"] = { ok = true, found = true, digest = string.rep("a", 64) },
    }
    local calls = {}
    with_globals({
      module_test_loop_runtime_cli = "custom-module-loop-runtime.js",
      exec_argv = function(request)
        local operation = request.argv[3]
        table.insert(calls, operation)
        t.eq(request.argv[1], "node")
        t.eq(request.argv[2], "custom-module-loop-runtime.js")
        return { exit_code = 0, stdout = codec.encode(responses[operation]) }
      end,
    }, function()
      local ports = runtime.production()
      t.eq(ports.load_state(".testing/runs/a/module-loop-state.json").version, 1)
      t.eq(ports.save_state(".testing/runs/a/module-loop-state.json", { version = 2 }, 1), true)
      t.eq(ports.list_pending_states(4)[1], ".testing/runs/a/module-loop-state.json")
      t.eq(ports.artifact_digest(".testing/runs/a/test-plan.json"), string.rep("a", 64))
      responses["load-state"] = { ok = true, found = false }
      t.eq(ports.load_state(".testing/runs/missing/module-loop-state.json"), nil)
      responses["artifact-digest"] = { ok = true, found = false }
      expect_failure("artifact-unavailable", function()
        ports.artifact_digest(".testing/runs/a/missing.json")
      end)
      t.eq(#calls, 6)
    end)

    with_globals({
      exec_argv = function() return { exit_code = 7, stderr = "runtime failed" } end,
    }, function()
      expect_failure("runtime-effect-failed", function()
        runtime.production().load_state(".testing/runs/a/module-loop-state.json")
      end)
    end)
    with_globals({
      exec_argv = function() return { exit_code = 0, stdout = "{}" } end,
    }, function()
      expect_failure("runtime-effect-invalid", function()
        runtime.production().load_state(".testing/runs/a/module-loop-state.json")
      end)
    end)
    with_globals({ module_test_loop_runtime_cli = "" }, function()
      expect_failure("runtime-cli-invalid", function()
        runtime.production().load_state(".testing/runs/a/module-loop-state.json")
      end)
    end)
    with_globals({ json = false }, function()
      expect_failure("runtime-port-unavailable: json.decode", function()
        runtime.production().load_state(".testing/runs/a/module-loop-state.json")
      end)
    end)
  end,

  test_testing_runtime_persists_cas_index_and_terminal_filter = function()
    local files = {}
    local old_getenv = os.getenv
    os.getenv = function(name)
      if name == "FKST_RUNTIME_ROOT" then return "/tmp/module-test-loop-runtime-test" end
      return old_getenv(name)
    end
    with_globals({
      file = {
        read = function(path)
          if files[path] == nil then error("missing") end
          return files[path]
        end,
        write = function(path, body) files[path] = body end,
      },
    }, function()
      local ports = runtime.testing()
      local ref = ".testing/runs/testing-runtime/module-loop-state.json"
      t.eq(ports.load_state(ref), nil)
      t.eq(ports.save_state(ref, { version = 1, phase = "runner-pending" }, 0), true)
      t.eq(ports.save_state(ref, { version = 2, phase = "runner-pending" }, 0), false)
      t.eq(ports.load_state(ref).phase, "runner-pending")
      t.eq(ports.list_pending_states(8)[1], ref)
      t.eq(#ports.artifact_digest(".testing/runs/testing-runtime/test-plan.json"), 64)
      t.eq(ports.save_state(ref, { version = 2, phase = "terminal" }, 1), true)
      t.eq(ports.load_state(ref), nil)
      t.eq(#ports.list_pending_states(8), 0)
      t.eq(ports.save_state(ref, { version = 1, phase = "runner-pending" }, 0), true)
      t.is_true(files["/tmp/module-test-loop-runtime-test/module-test-loop-test-state-store.json"] ~= nil)
    end)
    os.getenv = old_getenv
  end,

  test_testing_runtime_falls_back_to_io_files = function()
    local files = {}
    local fake_io = {
      open = function(path, mode)
        if mode == "r" then
          if files[path] == nil then return nil end
          return {
            read = function(_, format)
              t.eq(format, "*a")
              return files[path]
            end,
            close = function() end,
          }
        end
        t.eq(mode, "w")
        return {
          write = function(_, value) files[path] = value end,
          close = function() end,
        }
      end,
    }
    with_globals({ file = false, io = fake_io }, function()
      local runtime_ports = runtime.testing()
      local ref = ".testing/runs/io-runtime/module-loop-state.json"
      t.eq(runtime_ports.load_state(ref), nil)
      t.eq(runtime_ports.save_state(ref, { version = 1, phase = "runner-pending" }, 0), true)
      t.eq(runtime_ports.load_state(ref).version, 1)
    end)
  end,

  test_ports_select_host_testing_and_production_runtimes = function()
    local required = {
      load_state = function() end,
      save_state = function() end,
      list_pending_states = function() return {} end,
      artifact_digest = function() return string.rep("a", 64) end,
    }
    with_globals({ module_test_loop_runtime = required }, function()
      t.eq(ports_module.production(), required)
    end)
    local old_getenv = os.getenv
    os.getenv = function(name)
      if name == "FKST_MODULE_TEST_LOOP_TEST_RUNTIME" then return "1" end
      return old_getenv(name)
    end
    local testing_ports = ports_module.production()
    os.getenv = old_getenv
    t.eq(type(testing_ports.load_state), "function")
    with_globals({ module_test_loop_runtime = {} }, function()
      expect_failure("runtime-port-unavailable", function() ports_module.production() end)
    end)
    with_globals({ module_test_loop_runtime = false }, function()
      local previous_getenv = os.getenv
      os.getenv = function() return nil end
      local selected = ports_module.production()
      os.getenv = previous_getenv
      t.eq(type(selected.load_state), "function")
    end)
    expect_failure("invalid-runtime", function() ports_module.resolve({}) end)
  end,
}
