local json_codec = require("testing_runtime.json")
local runtime = require("testing_runtime.structured_execution")
local host_json = json
local t = fkst.test

local function with_globals(values, fn)
  local previous = {}
  for name, value in pairs(values) do
    previous[name] = rawget(_G, name)
    rawset(_G, name, value)
  end
  local ok, result = pcall(fn)
  for name, value in pairs(previous) do rawset(_G, name, value) end
  if not ok then error(result, 0) end
  return result
end

local function fake_host()
  local files = {}
  local calls = {}
  local responses = {
    ["load-artifact"] = { raw = "{}\n", digest = string.rep("a", 64), value = { status = "ready" } },
    ["now"] = { now = "2026-07-24T00:00:00Z" },
    ["verify-grant"] = { grant_sha256 = string.rep("b", 64) },
    ["replay-guard"] = { status = "claimed", claim_id = "claim", grant_id = "grant" },
    ["exec-argv"] = { exit_code = 0, stdout = "ok", stderr = "" },
    ["http-request"] = { status = 200, body = "ok", headers = {} },
    ["write-artifact"] = { written = true },
    ["load-result"] = { status = "passed" },
    ["complete-replay"] = { completed = true },
  }
  return {
    files = files,
    calls = calls,
    globals = {
      file = {
        write = function(path, value) files[path] = value return true end,
        read = function(path) return assert(files[path], "missing fake file " .. tostring(path)) end,
      },
      json = { decode = function(value) return host_json.decode(value) end },
      exec_argv = function(request)
        local argv = request.argv
        local name, response_path = argv[5], argv[9]
        table.insert(calls, {
          name = name,
          timeout = request.timeout,
          argv = argv,
          payload = host_json.decode(files[argv[7]]),
        })
        files[response_path] = json_codec.encode({ ok = true, result = responses[name] }) .. "\n"
        return { exit_code = 0, stdout = "", stderr = "" }
      end,
    },
  }
end

local function options(host)
  return {
    runtime_cli = "fixtures/fake-structured-runtime.js",
    runtime_config_ref = { kind = "artifact", ref = ".testing/host/structured-runtime-config.json" },
    exec_argv = host and host.globals.exec_argv,
    file = host and host.globals.file,
    json = host and host.globals.json,
  }
end

return {
  test_production_adapter_invokes_every_typed_runtime_port = function()
    local host = fake_host()
    with_globals(host.globals, function()
      local ports = runtime.production(options(host))
      local root = ".testing/runs/runtime-adapter/execution"
      t.eq(ports.load_artifact(root .. "/source.json").value.status, "ready")
      t.eq(ports.now({ artifact_root = root, operation_id = "op" }), "2026-07-24T00:00:00Z")
      t.eq(ports.verify_grant({ artifact_root = root, operation_id = "op" }).grant_sha256, string.rep("b", 64))
      t.eq(ports.replay_guard({ artifact_root = root, grant_id = "grant" }).status, "claimed")
      t.eq(ports.exec_argv({ artifact_root = root, case_id = "cli", timeout_seconds = 7 }).exit_code, 0)
      t.eq(ports.http_request({ artifact_root = root, case_id = "http", timeout_seconds = 9 }).status, 200)
      t.eq(ports.write_artifact(root .. "/result.json", { status = "passed" }), true)
      t.eq(ports.load_result({ artifact_root = root, result_ref = root .. "/execution.json" }).status, "passed")
      t.eq(ports.complete_replay({ artifact_root = root, result_ref = root .. "/execution.json" }), true)
      local timeouts = {}
      for _, call in ipairs(host.calls) do timeouts[call.name] = call.timeout end
      t.eq(timeouts["exec-argv"], 10)
      t.eq(timeouts["http-request"], 12)
    end)
  end,

  test_default_and_host_override_resolution_fail_closed = function()
    local host = fake_host()
    local configured = options(host)
    configured.runtime_cli = nil
    configured.runtime_config_ref = {
      kind = "artifact", ref = ".testing/host/default-structured-runtime.json",
    }
    t.eq(runtime.production(configured).now({ artifact_root = ".testing/runs/default-runtime/execution" }),
      "2026-07-24T00:00:00Z")

    local environment = options(host)
    environment.runtime_config_ref = nil
    environment.getenv = function(name)
      if name == "FKST_STRUCTURED_EXECUTION_RUNTIME_CONFIG_REF" then
        return ".testing/host/environment-structured-runtime.json"
      end
    end
    t.eq(runtime.production(environment).now({ artifact_root = ".testing/runs/environment-runtime/execution" }),
      "2026-07-24T00:00:00Z")
    t.eq(host.calls[#host.calls].payload.runtime_config_ref.ref,
      ".testing/host/environment-structured-runtime.json")

    configured.runtime_cli = "host-runtime.js"
    configured.runtime_config_ref = function(context)
      t.eq(context.artifact_root, ".testing/runs/function-runtime")
      return { kind = "artifact", ref = ".testing/host/function-runtime.json" }
    end
    t.eq(runtime.production(configured).now({ artifact_root = ".testing/runs/function-runtime/execution" }),
      "2026-07-24T00:00:00Z")

    configured.runtime_cli = ""
    configured.runtime_config_ref = { kind = "artifact", ref = ".testing/host/invalid-runtime.json" }
    t.raises(function()
      runtime.production(configured).now({ artifact_root = ".testing/runs/invalid-runtime/execution" })
    end)
    local fallback = runtime.production({
      runtime_cli = "host-runtime.js",
      runtime_config_ref = { kind = "artifact", ref = ".testing/host/fallback-runtime.json" },
    })
    t.raises(function() fallback.load_artifact("outside") end)

    configured.runtime_cli = "host-runtime.js"
    configured.runtime_config_ref = false
    t.raises(function()
      runtime.production(configured).now({ artifact_root = ".testing/runs/missing-config/execution" })
    end)
    configured.runtime_config_ref = {
      kind = "artifact", ref = ".testing/runs/inside-root/config.json",
    }
    t.raises(function()
      runtime.production(configured).now({ artifact_root = ".testing/runs/inside-root/execution" })
    end)
  end,

  test_missing_host_ports_and_invalid_effect_results_are_rejected = function()
    local host = fake_host()
    local configured = options(host)
    configured.exec_argv = false
    t.raises(function()
      runtime.production(configured).now({ artifact_root = ".testing/runs/no-exec/execution" })
    end)
    configured = options(host)
    configured.file = false
    t.raises(function()
      runtime.production(configured).now({ artifact_root = ".testing/runs/no-file/execution" })
    end)
    configured = options(host)
    configured.json = false
    t.raises(function()
      runtime.production(configured).now({ artifact_root = ".testing/runs/no-json/execution" })
    end)

    host.globals.exec_argv = function() return { exit_code = 1, stderr = "failed" } end
    t.raises(function()
      runtime.production(options(host)).now({ artifact_root = ".testing/runs/failed-effect/execution" })
    end)
    host = fake_host()
    host.globals.exec_argv = function(request)
      host.files[request.argv[9]] = json_codec.encode({ ok = false }) .. "\n"
      return { exit_code = 0 }
    end
    t.raises(function()
      runtime.production(options(host)).now({ artifact_root = ".testing/runs/invalid-effect/execution" })
    end)
    t.raises(function() runtime.production(options(host)).load_artifact("outside") end)
  end,
}
