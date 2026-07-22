local ai = require("testing_ai.browser_control")
local browser = require("contract.browser_control")
local structured = require("contract.structured_execution")
local t = fkst.test

local function observation(label)
  return {
    schema = browser.schemas.observation,
    turn = 1, document_token = string.rep("a", 64), target_id = "target-1",
    origin = "https://auth.example.test", path = "/login", ready_state = "complete",
    controls = { { handle = "abcdef12", role = "textbox", kind = "textbox", label = label, focused = true } },
    signals = {
      callback_detected = false, mfa_detected = false, captcha_detected = false,
      target_changed = false, popup_detected = false,
    },
    console_count = 0, network_count = 0,
  }
end

local function grant()
  return {
    allowed_actions = { "click", "type", "submit", "press_tab", "finish" },
    approved_secret_refs = { "primary-identity", "primary-secret" },
  }
end

return {
  test_prompt_contains_only_sanitized_observation_and_secret_ref_names = function()
    local value = observation("[redacted]")
    local prompt = ai.prompt({
      case_id = "login", kind = "browser", goal = "Authenticate the existing user.",
      success_conditions = { "Exact callback", "Authenticated CLI status" },
    }, grant(), value)
    t.is_true(prompt:find("primary-secret", 1, true) ~= nil)
    t.eq(prompt:find("cookie", 1, true), nil)
    t.eq(prompt:find("storage", 1, true), nil)
    t.eq(prompt:find("model transcript", 1, true), nil)
  end,

  test_canary_label_is_rejected_before_prompt_construction = function()
    local canary = "CANARY_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local value = observation(canary)
    t.raises(function() browser.validate_observation(value) end)
    t.raises(function() ai.prompt({
      case_id = "login", kind = "browser", goal = "Authenticate.",
      success_conditions = { "Callback" },
    }, grant(), structured.copy(value)) end)
  end,
}
