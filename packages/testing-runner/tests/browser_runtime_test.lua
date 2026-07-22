local browser = require("contract.browser_control")
local runtime = require("testing_runtime.browser_control")
local t = fkst.test

local function observation(turn)
  return {
    schema = browser.schemas.observation,
    turn = turn,
    document_token = string.rep("a", 64),
    target_id = "target-1",
    origin = "https://auth.example.test",
    path = "/login",
    ready_state = "complete",
    controls = {
      { handle = "abcdef12", role = "textbox", kind = "textbox", label = "Email", focused = true },
    },
    signals = {
      callback_detected = false, mfa_detected = false, captcha_detected = false,
      target_changed = false, popup_detected = false,
    },
    console_count = 0,
    network_count = 1,
  }
end

local function context()
  return {
    artifact_root = ".testing/runs/browser-runtime",
    cdp_url = "http://127.0.0.1:9222",
    grant = {
      target_id = "target-1",
      allowed_actions = { "click", "type", "submit", "press_tab", "finish" },
      approved_secret_refs = { "primary-identity" },
    },
  }
end

local function receipt(turn, action)
  return {
    schema = browser.schemas.step_receipt,
    turn = turn,
    action = action,
    before = observation(turn),
    after = observation(turn),
    status = "executed",
    classification = "effect-applied",
  }
end

local function ports(decoded)
  local model = { writes = {}, calls = {}, decoded = decoded }
  model.value = {
    exec_argv = function(argv, timeout)
      table.insert(model.calls, { argv = argv, timeout = timeout })
      return { exit_code = 0, stdout = "", stderr = "" }
    end,
    exec_argv_with_secret_stdin = function(argv, secret_ref, timeout)
      table.insert(model.calls, { argv = argv, secret_ref = secret_ref, timeout = timeout })
      return { exit_code = 0, stdout = "", stderr = "" }
    end,
    read = function(path) return path end,
    write = function(path, body) model.writes[path] = body return true end,
    decode = function() return model.decoded end,
  }
  return model
end

return {
  test_observe_and_act_drive_runtime_cli_and_validate_artifacts = function()
    local observed = ports(observation(1))
    local value, paths = runtime.observe(context(), 1, observed.value)
    t.eq(value.target_id, "target-1")
    t.eq(observed.calls[1].argv[3], "observe")
    t.is_true(observed.writes[paths.observe_input] ~= nil)

    local click = { schema = browser.schemas.action, turn = 1, kind = "click", handle = "abcdef12" }
    local acted = ports(receipt(1, click))
    t.eq(runtime.act(context(), 1, click, runtime.paths(context().artifact_root, 1), acted.value).status, "executed")
    t.eq(acted.calls[1].argv[3], "act")

    local typed = {
      schema = browser.schemas.action, turn = 1, kind = "type",
      handle = "abcdef12", secret_ref = "primary-identity",
    }
    local secret = ports(receipt(1, typed))
    runtime.act(context(), 1, typed, runtime.paths(context().artifact_root, 1), secret.value)
    t.eq(secret.calls[1].secret_ref, "primary-identity")
  end,

  test_runtime_ports_and_effect_failures_are_fail_closed = function()
    t.raises(function() runtime.observe(context(), 1, nil) end)
    t.raises(function() runtime.observe(context(), 1, {}) end)

    local failed = ports(observation(1))
    failed.value.exec_argv = function() return { exit_code = 7, stderr = "failed" } end
    t.raises(function() runtime.observe(context(), 1, failed.value) end)

    local typed = {
      schema = browser.schemas.action, turn = 1, kind = "type",
      handle = "abcdef12", secret_ref = "primary-identity",
    }
    local missing_secret = ports(receipt(1, typed))
    missing_secret.value.exec_argv_with_secret_stdin = nil
    t.raises(function()
      runtime.act(context(), 1, typed, runtime.paths(context().artifact_root, 1), missing_secret.value)
    end)
  end,
}
