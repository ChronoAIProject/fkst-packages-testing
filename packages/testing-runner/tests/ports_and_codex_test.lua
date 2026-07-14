local codex = require("workflow.codex")
local ports_module = require("testing_runtime.ports")
local t = fkst.test

local function with_globals(values, fn)
  local names = {}
  local previous = {}
  for name, value in pairs(values) do
    table.insert(names, name)
    previous[name] = _G[name]
    _G[name] = value
  end
  local ok, result = pcall(fn)
  for _, name in ipairs(names) do
    _G[name] = previous[name]
  end
  if not ok then
    error(result)
  end
  return result
end

return {
  test_testing_runtime_production_ports_wrap_engine_globals = function()
    local exec_request
    local written = {}
    with_globals({
      exec_argv = function(request)
        exec_request = request
        return { exit_code = 0, stdout = "ok", stderr = "" }
      end,
      file = {
        read = function(path)
          t.eq(path, ".testing/runs/input.json")
          return "{\"ok\":true}"
        end,
        write = function(path, body)
          written[path] = body
        end,
      },
      json = {
        decode = function(body)
          t.eq(body, "{\"ok\":true}")
          return { ok = true }
        end,
      },
    }, function()
      local ports = ports_module.production()
      local exec_result = ports.exec_argv({ "node", "runner.js" }, 9)
      t.eq(exec_result.stdout, "ok")
      t.eq(exec_request.timeout, 9)
      t.eq(exec_request.argv[2], "runner.js")

      local decoded = ports.decode(ports.read(".testing/runs/input.json"))
      t.eq(decoded.ok, true)
      t.eq(ports.write(".testing/runs/output.json", "{\"status\":\"passed\"}"), true)
      t.eq(written[".testing/runs/output.json"], "{\"status\":\"passed\"}")
    end)
  end,

  test_codex_live_run_active_matches_non_expired_run = function()
    local previous_codex_runs = fkst.codex_runs
    fkst.codex_runs = function()
      return {
        running = {
          {
            role = "reviewer",
            proposal_id = "proposal-1",
            dedup_key = "dedup-1",
            status = "running",
            lease_expires_at_ms = 20 * 1000,
          },
        },
      }
    end
    local ok, result = pcall(function()
      return with_globals({
        now = function()
          return 10
        end,
      }, function()
        return codex.live_run_active({
          role = "reviewer",
          proposal_id = "proposal-1",
          dedup_key = "dedup-1",
        })
      end)
    end)
    fkst.codex_runs = previous_codex_runs
    if not ok then
      error(result)
    end
    t.eq(result, true)
  end,
}
