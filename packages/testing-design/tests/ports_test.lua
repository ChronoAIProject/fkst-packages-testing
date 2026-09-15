local ports = require("ports")
local t = fkst.test

local function with_runtime(value, body)
  local previous = rawget(_G, "testing_design_runtime")
  rawset(_G, "testing_design_runtime", value)
  local ok, result = pcall(body)
  rawset(_G, "testing_design_runtime", previous)
  if not ok then error(result, 0) end
  return result
end

local function with_globals(values, body)
  local previous = {}
  local present = {}
  for key, value in pairs(values) do
    present[key] = rawget(_G, key) ~= nil
    previous[key] = rawget(_G, key)
    rawset(_G, key, value)
  end
  local ok, result = pcall(body)
  for key, _ in pairs(values) do
    rawset(_G, key, present[key] and previous[key] or nil)
  end
  if not ok then error(result, 0) end
  return result
end

return {
  test_host_runtime_is_preferred = function()
    with_runtime({
      analyze = function() return "host" end,
      generate_candidates = function() return "generated" end,
    }, function()
      t.eq(ports.production().analyze(), "host")
      t.eq(ports.production().generate_candidates(), "generated")
    end)
  end,

  test_incomplete_runtime_and_resolve_fail_closed = function()
    with_runtime({}, function()
      t.raises(function() ports.production().analyze() end)
    end)
    t.raises(function() ports.resolve({}) end)
    t.raises(function() ports.resolve_generation({}) end)
  end,

  test_production_runtime_rejects_invalid_cli_and_missing_json_decoder = function()
    with_globals({ testing_design_runtime_cli = "bad\npath" }, function()
      t.raises(function() ports.production().analyze({}) end)
    end)
    local previous_json = rawget(_G, "json")
    rawset(_G, "json", {})
    local ok = pcall(function() ports.production().analyze({}) end)
    rawset(_G, "json", previous_json)
    t.eq(ok, false)
  end,

  test_production_runtime_bounds_effect_errors_and_rejects_invalid_envelopes = function()
    with_globals({
      exec_argv = function() return { exit_code = 7, stderr = "failed\nwith controls\1" } end,
    }, function()
      t.raises(function() ports.production().analyze({ schema = "fixture" }) end)
    end)
    with_globals({
      exec_argv = function() return { exit_code = 0, stdout = "{}" } end,
    }, function()
      t.raises(function() ports.production().analyze({ schema = "fixture" }) end)
    end)
  end,

  test_generation_runtime_uses_request_budgets_and_sanitized_envelopes = function()
    local observed
    with_globals({
      testing_design_codex = { binary = "codex", model = "pinned-model", worktree = "/approved/worktree" },
      exec_argv = function(request)
        observed = request
        return { exit_code = 0, stdout = '{"ok":true,"result":{"ok":false,"failure":{"code":"refusal"}}}' }
      end,
    }, function()
      local result = ports.production().generate_candidates({ policy = { timeout_ms = 30000 } })
      t.eq(result.failure.code, "refusal")
      t.eq(observed.timeout, 35)
      t.eq(observed.argv[3], "generate-codex-env")
      t.eq(observed.env.FKST_TESTING_DESIGN_GENERATION_JSON:find("pinned%-model") ~= nil, true)
      t.eq(observed.env.FKST_TESTING_DESIGN_GENERATION_JSON:find("SECRET") == nil, true)
    end)
    with_globals({ testing_design_codex = {} }, function()
      t.raises(function() ports.production().generate_candidates({ policy = { timeout_ms = 30000 } }) end)
    end)
  end,
}
