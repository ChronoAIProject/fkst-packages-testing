local core = require("core")
local t = fkst.test

local function request()
  return {
    schema = "browser-readiness.check.v1",
    base_url = "http://localhost:8080/",
    sessions = {
      { role = "admin", browser_harness_command = "browser-harness" },
      { role = "user1", cdp_endpoint_env = "APP_USER1_CDP_ENDPOINT" },
    },
  }
end

local function probe(env_values, commands, urls)
  return {
    env = function(name)
      return env_values[name]
    end,
    command_exists = function(command)
      return commands[command] == true
    end,
    local_http_ready = function(url)
      return urls[url] == true
    end,
  }
end

return {
  test_validates_browser_harness_or_cdp_sessions = function()
    local payload = core.validate_request(request())
    t.eq(#payload.sessions, 2)
  end,

  test_rejects_empty_sessions = function()
    t.raises(function()
      core.validate_request({ schema = "browser-readiness.check.v1", sessions = {} })
    end)
  end,

  test_rejects_session_without_readiness_source = function()
    t.raises(function()
      core.validate_request({
        schema = "browser-readiness.check.v1",
        sessions = { { role = "admin" } },
      })
    end)
  end,

  test_forced_result_keeps_planned_compatibility = function()
    local result = core.result(request(), "planned")
    t.eq(result.schema, "browser-readiness.result.v1")
    t.eq(result.status, "planned")
    t.eq(result.sessions[1].role, "admin")
    t.eq(result.sessions[1].status, "planned")
  end,

  test_result_preserves_small_request_context = function()
    local payload = request()
    payload.request_context = {
      native_argv = { "lua", "checks/module-a.lua" },
      dry_run = false,
      no_browser = true,
    }
    local result = core.result(payload, {
      probe = probe(
        { APP_USER1_CDP_ENDPOINT = "http://127.0.0.1:9222/json/version" },
        { ["browser-harness"] = true },
        { ["http://localhost:8080/"] = true }
      ),
    })
    t.eq(result.status, "ready")
    t.eq(result.request_context.native_argv[1], "lua")
    t.eq(result.request_context.dry_run, false)
    t.eq(result.request_context.no_browser, true)
  end,

  test_rejects_unsupported_request_context_fields = function()
    local payload = request()
    payload.request_context = { extra = true }
    t.raises(function()
      core.result(payload)
    end)
  end,

  test_ready_when_local_base_url_harness_and_cdp_are_available = function()
    local result = core.result(request(), {
      probe = probe(
        { APP_USER1_CDP_ENDPOINT = "http://127.0.0.1:9222/json/version" },
        { ["browser-harness"] = true },
        { ["http://localhost:8080/"] = true }
      ),
    })

    t.eq(result.schema, "browser-readiness.result.v1")
    t.eq(result.status, "ready")
    t.eq(result.sessions[1].role, "base_url")
    t.eq(result.sessions[1].status, "ready")
    t.eq(result.sessions[2].role, "admin")
    t.eq(result.sessions[2].status, "ready")
    t.eq(result.sessions[2].checks[1].name, "browser_harness_command")
    t.eq(result.sessions[3].role, "user1")
    t.eq(result.sessions[3].checks[1].name, "cdp_endpoint_env")
  end,

  test_env_driven_harness_command_can_be_ready = function()
    local result = core.result({
      schema = "browser-readiness.check.v1",
      sessions = {
        { role = "admin", browser_harness_command_env = "APP_ADMIN_BROWSER_HARNESS_COMMAND" },
      },
    }, {
      probe = probe(
        { APP_ADMIN_BROWSER_HARNESS_COMMAND = "browser-harness" },
        { ["browser-harness"] = true },
        {}
      ),
    })

    t.eq(result.status, "ready")
    t.eq(result.sessions[1].checks[1].name, "browser_harness_command_env")
  end,

  test_missing_env_blocks_session = function()
    local result = core.result({
      schema = "browser-readiness.check.v1",
      sessions = {
        { role = "user1", cdp_endpoint_env = "APP_USER1_CDP_ENDPOINT" },
      },
    }, {
      probe = probe({}, {}, {}),
    })

    t.eq(result.status, "blocked")
    t.eq(result.sessions[1].status, "blocked")
    t.eq(result.sessions[1].checks[1].reason, "missing or non-local endpoint")
  end,

  test_non_local_base_url_and_cdp_url_block = function()
    local result = core.result({
      schema = "browser-readiness.check.v1",
      base_url = "https://example.com/",
      sessions = {
        { role = "user1", cdp_url = "https://example.com/devtools" },
      },
    }, {
      probe = probe({}, {}, {}),
    })

    t.eq(result.status, "blocked")
    t.eq(result.sessions[1].role, "base_url")
    t.eq(result.sessions[1].status, "blocked")
    t.eq(result.sessions[2].checks[1].name, "cdp_url")
    t.eq(result.sessions[2].checks[1].reason, "non-local endpoint")
  end,

  test_command_name_rejects_shell_metacharacters = function()
    t.eq(core.command_name("browser-harness --project local"), "browser-harness")
    t.eq(core.command_name("browser-harness;rm"), nil)
  end,
}
