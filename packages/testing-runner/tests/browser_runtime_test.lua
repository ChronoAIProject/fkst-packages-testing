local browser = require("contract.browser_control")
local executor_contract = require("contract.testing_package_executor")
local sha256 = require("tests.fixtures.sha256_helpers")
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

  test_read_title_validates_closed_receipt_and_persisted_evidence = function()
    local title_context = { artifact_root=".testing/runs/dedup-walking-skeleton",
      cdp_url="http://127.0.0.1:9222", target_id="target-1", target_sha256=sha256("target-1") }
    local request = { schema=executor_contract.schemas.browser_read_title, effect_id=executor_contract.effect_id,
      url=executor_contract.target_url }
    local evidence_bytes = "{\"observed_title\":\"Fixture Home\",\"observed_url\":\"http://127.0.0.1:4173/\"}"
    local title_receipt = { schema=executor_contract.schemas.effect_receipt, effect_id=executor_contract.effect_id,
      status="succeeded", observed_url=executor_contract.target_url, observed_title="Fixture Home",
      evidence_refs={{kind="artifact",ref=".testing/runs/dedup-walking-skeleton/evidence/title.json",sha256=sha256(evidence_bytes)}},
      evidence_size_bytes=#evidence_bytes }
    local title = ports(title_receipt)
    title.value.sha256 = sha256
    title.value.read = function(path)
      if path == ".testing/runs/dedup-walking-skeleton/evidence/title.json" then return evidence_bytes end
      return path
    end
    local value, paths = runtime.read_title(title_context, request, title.value)
    t.eq(value.observed_title, "Fixture Home")
    t.eq(title.calls[1].argv[3], "read-title")
    t.is_true(title.writes[paths.input] ~= nil)

    title.value.sha256 = function() return string.rep("0", 64) end
    t.raises(function() runtime.read_title(title_context, request, title.value) end)
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
