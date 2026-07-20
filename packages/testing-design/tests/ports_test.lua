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
    with_runtime({ analyze = function() return "host" end }, function()
      t.eq(ports.production().analyze(), "host")
    end)
  end,

  test_incomplete_runtime_and_resolve_fail_closed = function()
    with_runtime({}, function()
      t.raises(function() ports.production().analyze() end)
    end)
    t.raises(function() ports.resolve({}) end)
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
}
