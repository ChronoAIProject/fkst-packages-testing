local browser = require("contract.browser_control")
local controller = require("ai_browser_control")
local department = require("departments.run_ai_browser_control.main")
local structured = require("contract.structured_execution")
local testing_contract = require("contract.testing")
local json_codec = require("testing_runtime.json")
local testing = require("testkit.testing")
local t = fkst.test
local function digest(char) return string.rep(char, 64) end
local function sha256(value)
  local input, output = os.tmpname(), os.tmpname()
  local handle = assert(io.open(input, "wb")); handle:write(value); handle:close()
  local ok, _, code = os.execute("sha256sum " .. input .. " > " .. output)
  local digest_file = assert(io.open(output, "r"))
  local computed = assert(digest_file:read("*l")):match("^([0-9a-f]+)")
  digest_file:close(); os.remove(input); os.remove(output)
  if not (ok == true or ok == 0) then error("sha256sum failed exit=" .. tostring(code)) end
  return computed
end
local target_sha = "75a34976ea1b88daa7ba0c80731fc1dbf0d7a3d4c63e7a255764facd1c7d0f57"
local function fixture(options)
  options = options or {}
  local root = ".testing/runs/ai-browser"
  local repository = { url = "https://github.com/owner/repo.git", commit_sha = string.rep("a", 40) }
  local request = {
    schema = browser.schemas.request,
    repository = repository,
    environment_receipt_ref = root .. "/environment-receipt-ready.json",
    environment_receipt_sha256 = digest("1"),
    reviewed_plan_ref = root .. "/structured-plan.json",
    reviewed_plan_sha256 = digest("2"),
    browser_grant_ref = root .. "/browser-grant.json",
    browser_grant_sha256 = digest("3"),
    artifact_root = root,
    trace_id = "trace-browser", dedup_key = "dedup-browser",
    source_ref = { kind = "workflow-qa", ref = "run-browser" },
  }
  local attempt_ref = root .. "/readiness-attempt.json"
  local correlation = {
    schema = "environment-factory.browser-readiness-correlation.v1",
    attempt_id = "attempt-1",
    operation_id = "run-browser",
    operation_state_ref = { kind = "artifact", ref = root .. "/operation-state.json" },
    readiness_attempt_ref = { kind = "artifact", ref = attempt_ref },
    readiness_attempt_sha256 = digest("4"),
    target_id = "target-1",
    target_sha256 = target_sha,
    base_url = "http://127.0.0.1:4173/health",
    sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
  local environment = {
    schema = "environment-factory.receipt.v2",
    operation_id = "run-browser", status = "ready",
    profile_revision = "profile-v1", profile_sha256 = digest("9"),
    repository = repository,
    workspace_ref = { kind = "workspace", ref = "run-browser-workspace" },
    base_url = correlation.base_url,
    runtime_ports = { { name = "application", port = 4173 } },
    sessions = structured.copy(correlation.sessions),
    browser_readiness = {
      schema = "browser-readiness.result.v1", status = "ready",
      sessions = {
        { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
        { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } }, cdp_url = "http://127.0.0.1:9222" },
      },
      source_ref = structured.copy(correlation.operation_state_ref),
      request_context = { dry_run = false },
      correlation = correlation,
    },
    artifact_root = root,
    diagnostic_refs = {}, cleanup_ref = { kind = "cleanup", ref = "run-browser" },
    cleanup_status = "pending", trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
  local plan = {
    schema = structured.schemas.plan,
    execution_mode = "agentic-browser",
    repository = repository,
    environment_receipt_sha256 = request.environment_receipt_sha256,
    browser_readiness_sha256 = digest("7"),
    case_catalog_sha256 = digest("5"), module_plan_sha256 = digest("6"),
    cases = { {
      case_id = "existing-user-login", kind = "browser",
      goal = "Authenticate the existing user through the approved browser target.",
      success_conditions = {
        "Exact loopback callback observed", "Login process exits zero",
        "whoami succeeds", "status reports authenticated",
      },
      completion_assertions = {
        { assertion_id = "callback-observed", type = "browser-callback-observed", required = true, completion_field = "callback_observed" },
        { assertion_id = "process-exit-zero", type = "browser-process-exit-zero", required = true, completion_field = "process_exit_zero" },
        { assertion_id = "whoami-succeeded", type = "browser-whoami-succeeded", required = true, completion_field = "whoami_succeeded" },
        { assertion_id = "status-authenticated", type = "browser-status-authenticated", required = true, completion_field = "status_authenticated" },
      },
    } },
    residual_risk_case_ids = {}, trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
  local grant = {
    schema = browser.schemas.grant,
    grant_id = "browser-grant-1", parent_authorization_sha256 = digest("0"), repository = repository,
    environment_receipt_sha256 = request.environment_receipt_sha256,
    readiness_attempt_id = correlation.attempt_id,
    readiness_attempt_sha256 = correlation.readiness_attempt_sha256,
    target_id = correlation.target_id, target_sha256 = correlation.target_sha256,
    reviewed_plan_sha256 = request.reviewed_plan_sha256,
    allowed_auth_origins = { "https://auth.example.test" },
    callback = { origin = "http://127.0.0.1:43119", path = "/callback" },
    allowed_actions = { "click", "type", "submit", "press_tab", "finish" },
    approved_secret_refs = { "primary-identity", "primary-secret" },
    step_budget = options.step_budget or 3, time_budget_seconds = 120,
    authority = { kind = "policy", ref = "browser-policy" }, policy_revision = "policy-v1",
    evidence_ref = { kind = "attestation", ref = "browser-grant-1" },
    issued_at = "2026-07-20T00:00:00Z", expires_at = "2026-07-20T01:00:00Z",
    max_uses = 1, trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
  local artifacts = {
    [request.environment_receipt_ref] = { raw = "environment", digest = request.environment_receipt_sha256, value = environment },
    [request.reviewed_plan_ref] = { raw = "plan", digest = request.reviewed_plan_sha256, value = plan },
    [request.browser_grant_ref] = { raw = "grant", digest = request.browser_grant_sha256, value = grant },
    [attempt_ref] = { raw = "attempt", digest = correlation.readiness_attempt_sha256, value = { target_id = correlation.target_id } },
  }
  return request, artifacts, grant
end
local function observation(turn, options)
  options = options or {}
  local callback = options.callback == true
  return {
    schema = browser.schemas.observation,
    turn = turn,
    document_token = digest(tostring((turn % 9) + 1)),
    target_id = "target-1",
    origin = callback and "http://127.0.0.1:43119" or "https://auth.example.test",
    path = callback and "/callback" or "/login",
    ready_state = "complete",
    controls = callback and {} or {
      { handle = "a" .. tostring(turn), role = "button", kind = "button", label = "Continue", focused = false },
    },
    signals = {
      callback_detected = callback,
      mfa_detected = options.mfa == true,
      captcha_detected = options.captcha == true,
      target_changed = options.target_changed == true,
      popup_detected = options.popup == true,
    },
    console_count = 0, network_count = turn,
  }
end
local function action(turn, kind, fields)
  local value = { schema = browser.schemas.action, turn = turn, kind = kind }
  for key, item in pairs(fields or {}) do value[key] = item end
  return value
end
local function ports(request, artifacts, grant, options)
  options = options or {}
  local writes, turns, clock = options.writes or {}, 0, 0
  local pending_action
  local runtime = {
    load_artifact = function(path)
      if artifacts[path] then return artifacts[path] end
      if writes[path] then
        local raw = json_codec.encode(writes[path]) .. "\n"
        return { value = structured.copy(writes[path]), raw = raw, digest = sha256(raw) }
      end
    end,
    write_artifact = function(path, value)
      if writes[path] ~= nil then return json_codec.encode(writes[path]) == json_codec.encode(value) end
      writes[path] = structured.copy(value)
      return true
    end,
    artifact_digest = function(path)
      if artifacts[path] then return artifacts[path].digest end
      if writes[path] then return sha256(json_codec.encode(writes[path]) .. "\n") end
    end,
    now = function() return "2026-07-20T00:30:00Z" end,
    verify_grant = function()
      return {
        grant_sha256 = request.browser_grant_sha256,
        authority = structured.copy(grant.authority), policy_revision = grant.policy_revision,
        evidence_ref = structured.copy(grant.evidence_ref),
      }
    end,
    replay_guard = function() return options.claim or { status = "claimed", claim_id = "claim-browser" } end,
    complete_replay = function() return true end,
    load_result = function() return options.replayed_result end,
    verify_completion = function()
      return options.completion or {
        callback_observed = true, process_exit_zero = true,
        whoami_succeeded = true, status_authenticated = true,
      }
    end,
    decode = function() return structured.copy(pending_action) end,
    monotonic_seconds = function() clock = clock + (options.clock_step or 0) return clock end,
    sha256 = sha256,
    failpoint = options.failpoint,
    browser_observe = function(_, turn)
      turns = turns + 1
      if options.observe then return options.observe(turn) end
      return observation(turn), {}
    end,
    browser_act = function(_, turn, selected)
      if options.act then return options.act(turn, selected) end
      local before = observation(turn)
      local after = observation(turn, { callback = options.callback_turn == turn })
      return {
        schema = browser.schemas.step_receipt, turn = turn,
        action = structured.copy(selected), before = before, after = after,
        status = selected.kind == "finish" and "advisory" or "executed",
        classification = selected.kind == "finish" and "ai-finish-advisory" or "effect-applied",
      }
    end,
    ai_turn = function(_, _, current)
      pending_action = options.ai_turn and options.ai_turn(current.turn, current)
        or action(current.turn, "click", { handle = current.controls[1].handle })
      return { exit_code = 0, stdout = "{}", stderr = "" }
    end,
  }
  return runtime, writes, function() return turns end
end
local function canonical_case(request, writes)
  local result_set = writes[request.artifact_root .. "/case-result-set.json"]
  t.eq(result_set.schema, "testing-case-result-set.v2")
  t.eq(writes[request.artifact_root .. "/evidence-manifest.json"].schema,
    "testing-evidence-manifest.v1")
  return result_set.cases[1]
end
return {
  test_deterministic_completion_overrides_advisory_ai_and_passes = function()
    local request, artifacts, grant = fixture()
    local runtime, writes = ports(request, artifacts, grant, { callback_turn = 1 })
    local result = controller.run(request, runtime)
    t.eq(result.status, "passed")
    t.eq(result.mode, "agentic-browser")
    t.eq(result.turn_count, 1)
    local receipt = writes[request.artifact_root .. "/browser-agent-execution.json"]
    t.eq(receipt.completion.callback_observed, true)
    t.eq(receipt.steps[1].action.kind, "click")
    local case_result = canonical_case(request, writes)
    t.eq(case_result.execution_status, "passed")
    t.eq(case_result.repository.source_ref.kind, "git")
    t.eq(case_result.evidence_refs[1].sha256, nil)
    t.eq(#case_result.assertions, 4)
    t.eq(case_result.assertions[1].status, "passed")
    t.is_true(#case_result.observations > 0)
    local manifest = writes[request.artifact_root .. "/evidence-manifest.json"]
    local result_set = writes[request.artifact_root .. "/case-result-set.json"]
    t.eq(result_set.evidence_manifest_ref.sha256, runtime.artifact_digest(
      request.artifact_root .. "/evidence-manifest.json"))
    t.eq(result_set.evidence_manifest_artifact_sha256, result_set.evidence_manifest_ref.sha256)
    t.is_true(result_set.evidence_manifest_sha256 ~= result_set.evidence_manifest_artifact_sha256)
    t.is_true(structured.equal(result_set, writes[request.artifact_root .. "/case-results.json"]))
    t.eq(manifest.entries[1].sha256, runtime.artifact_digest(
      request.artifact_root .. "/browser-agent-execution.json"))
    local encoded = json_codec.encode(writes)
    t.eq(encoded:find("raw provider body", 1, true), nil)
    t.eq(encoded:find("password=", 1, true), nil)
  end,
  test_ai_false_success_is_advisory_and_repetition_blocks = function()
    local request, artifacts, grant = fixture()
    local runtime, writes = ports(request, artifacts, grant, {
      ai_turn = function(turn) return action(turn, "finish", { advisory_status = "success" }) end,
    })
    local result = controller.run(request, runtime)
    t.eq(result.status, "blocked")
    t.eq(result.classification, "repeated-ai-action")
    local receipt = writes[request.artifact_root .. "/browser-agent-execution.json"]
    t.eq(#receipt.steps, 1)
    t.eq(receipt.completion.callback_observed, false)
  end,
  test_malformed_ai_action_fails_before_browser_effect = function()
    local request, artifacts, grant = fixture()
    local effects = 0
    local runtime, writes = ports(request, artifacts, grant, {
      ai_turn = function(turn) return { schema = browser.schemas.action, turn = turn, kind = "navigate" } end,
      act = function() effects = effects + 1 end,
    })
    local result = controller.run(request, runtime)
    t.eq(result.status, "blocked")
    t.eq(effects, 0)
    local case_result = canonical_case(request, writes)
    t.eq(case_result.execution_status, "error")
    t.eq(case_result.error.code, "browser-action-invalid")
  end,
  test_step_budget_exhaustion_is_terminal_and_bounded = function()
    local request, artifacts, grant = fixture({ step_budget = 2 })
    local runtime, writes = ports(request, artifacts, grant, {
      ai_turn = function(turn, current)
        if turn == 1 then return action(turn, "click", { handle = current.controls[1].handle }) end
        return action(turn, "press_tab")
      end,
    })
    local result = controller.run(request, runtime)
    t.eq(result.status, "blocked")
    t.eq(result.classification, "browser-step-budget-exhausted")
    t.eq(#writes[request.artifact_root .. "/browser-agent-execution.json"].steps, 2)
    t.eq(canonical_case(request, writes).non_execution_reason, "browser-step-budget-exhausted")
  end,
  test_mfa_captcha_popup_and_target_change_stop_without_ai_turn = function()
    for _, signal in ipairs({ "mfa", "captcha", "popup", "target_changed" }) do
      local request, artifacts, grant = fixture()
      local ai_calls = 0
      local runtime, writes = ports(request, artifacts, grant, {
        observe = function(turn) return observation(turn, { [signal] = true }), {} end,
        ai_turn = function() ai_calls = ai_calls + 1 return action(1, "finish", { advisory_status = "blocked" }) end,
      })
      local result = controller.run(request, runtime)
      t.eq(result.status, "blocked")
      t.eq(ai_calls, 0)
      local case_result = canonical_case(request, writes)
      t.eq(case_result.execution_status, "blocked")
      local reason = signal == "target_changed" and "browser-target-changed"
        or "browser-" .. signal:gsub("_", "-") .. "-detected"
      t.eq(case_result.non_execution_reason, reason)
    end
  end,
  test_target_binding_and_grant_digest_mismatches_fail_before_observation = function()
    local request, artifacts, grant = fixture()
    artifacts[request.browser_grant_ref].value.target_id = "foreign-target"
    local runtime, _, turns = ports(request, artifacts, grant)
    local result = controller.run(request, runtime)
    t.eq(result.status, "blocked")
    t.eq(turns(), 0)
    request, artifacts, grant = fixture()
    artifacts[request.browser_grant_ref].digest = digest("8")
    runtime, _, turns = ports(request, artifacts, grant)
    result = controller.run(request, runtime)
    t.eq(result.status, "blocked")
    t.eq(turns(), 0)
  end,
  test_time_budget_exhaustion_stops_before_ai_or_effect = function()
    local request, artifacts, grant = fixture()
    local ai_calls = 0
    local runtime, writes = ports(request, artifacts, grant, {
      clock_step = 121,
      ai_turn = function() ai_calls = ai_calls + 1 return action(1, "press_tab") end,
    })
    local result = controller.run(request, runtime)
    t.eq(result.status, "blocked")
    t.eq(result.classification, "browser-time-budget-exhausted")
    t.eq(ai_calls, 0)
    t.eq(#writes[request.artifact_root .. "/browser-agent-execution.json"].steps, 0)
    t.eq(canonical_case(request, writes).non_execution_reason, "browser-time-budget-exhausted")
  end,
  test_callback_failure_completion_failure_step_failure_interrupt_and_loss_are_stable = function()
    do
      local request, artifacts, grant = fixture()
      local runtime, writes = ports(request, artifacts, grant, {
        observe = function(turn) return observation(turn, { callback = true }), {} end,
      })
      runtime.verify_completion = function() error("completion process unavailable") end
      controller.run(request, runtime)
      local case_result = canonical_case(request, writes)
      t.eq(case_result.execution_status, "error")
      t.eq(case_result.error.code, "callback-verification-failed")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime, writes = ports(request, artifacts, grant, {
        callback_turn = 1,
        completion = {
          callback_observed = true, process_exit_zero = true,
          whoami_succeeded = false, status_authenticated = false,
        },
      })
      local result = controller.run(request, runtime)
      t.eq(result.status, "failed")
      local case_result = canonical_case(request, writes)
      t.eq(case_result.execution_status, "failed")
      t.eq(case_result.assertions[3].status, "failed")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime, writes = ports(request, artifacts, grant, {
        act = function(turn, selected)
          return {
            schema = browser.schemas.step_receipt, turn = turn, action = structured.copy(selected),
            before = observation(turn), after = observation(turn),
            status = "blocked", classification = "browser-step-rejected",
          }
        end,
      })
      controller.run(request, runtime)
      local case_result = canonical_case(request, writes)
      t.eq(case_result.execution_status, "error")
      t.eq(case_result.error.code, "browser-step-rejected")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime, writes = ports(request, artifacts, grant)
      runtime.ai_turn = function() error("controller interrupted") end
      controller.run(request, runtime)
      local case_result = canonical_case(request, writes)
      t.eq(case_result.execution_status, "error")
      t.eq(case_result.error.code, "browser-controller-interrupted")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime, writes = ports(request, artifacts, grant, {
        act = function() error("process interrupted after dispatch") end,
      })
      controller.run(request, runtime)
      local case_result = canonical_case(request, writes)
      t.eq(case_result.execution_status, "lost")
      t.eq(case_result.non_execution_reason, "execution-lost-between-action-and-assertion")
      t.eq(case_result.assertions[1].status, "skipped")
    end
  end,
  test_optional_screenshot_and_runner_output_evidence_require_exact_metadata = function()
    local request, artifacts, grant = fixture()
    local screenshot_path = request.artifact_root .. "/browser-runtime/turn-1-screenshot.png"
    local output_path = request.artifact_root .. "/browser-runtime/turn-1-runner.txt"
    artifacts[screenshot_path] = { digest = digest("a") }
    artifacts[output_path] = { digest = digest("b") }
    local runtime, writes = ports(request, artifacts, grant, {
      observe = function(turn)
        return observation(turn, { callback = true }), {
          screenshot = screenshot_path,
          runner_output = output_path,
          artifact_metadata = {
            screenshot = { sha256 = digest("a"), size_bytes = 24 },
            runner_output = { sha256 = digest("b"), size_bytes = 12 },
          },
        }
      end,
    })
    controller.run(request, runtime)
    local manifest = writes[request.artifact_root .. "/evidence-manifest.json"]
    local roles = {}
    for _, entry in ipairs(manifest.entries) do roles[entry.role] = true end
    t.eq(roles.screenshot, true)
    t.eq(roles["runner-log"], true)
  end,
  test_evidence_and_canonical_result_write_failures_are_fail_closed = function()
    for _, suffix in ipairs({
      "/evidence/browser-observation-1.json",
      "/evidence-manifest.json",
      "/case-result-set.json",
      "/case-results.json",
    }) do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant, { callback_turn = 1 })
      local write_artifact = runtime.write_artifact
      runtime.write_artifact = function(path, value)
        if path == request.artifact_root .. suffix then return false end
        return write_artifact(path, value)
      end
      local result = controller.run(request, runtime)
      t.eq(result.status, "blocked")
      t.is_true(result.message:find("artifact write failed", 1, true) ~= nil)
    end
  end,
  test_optional_evidence_rejects_missing_and_mismatched_metadata = function()
    do
      local request, artifacts, grant = fixture()
      local screenshot_path = request.artifact_root .. "/browser-runtime/turn-1-screenshot.png"
      local runtime = ports(request, artifacts, grant, {
        observe = function(turn)
          return observation(turn, { callback = true }), { screenshot = screenshot_path }
        end,
      })
      local result = controller.run(request, runtime)
      t.eq(result.status, "blocked")
      t.is_true(result.message:find("optional evidence metadata is unavailable", 1, true) ~= nil)
    end
    do
      local request, artifacts, grant = fixture()
      local screenshot_path = request.artifact_root .. "/browser-runtime/turn-1-screenshot.png"
      artifacts[screenshot_path] = { digest = digest("a") }
      local runtime = ports(request, artifacts, grant, {
        observe = function(turn)
          return observation(turn, { callback = true }), {
            screenshot = screenshot_path,
            artifact_metadata = { screenshot = { sha256 = digest("b"), size_bytes = 24 } },
          }
        end,
      })
      local result = controller.run(request, runtime)
      t.eq(result.status, "blocked")
      t.is_true(result.message:find("optional evidence metadata differs", 1, true) ~= nil)
    end
  end,
  test_malformed_observation_is_terminal_without_ai_or_effect = function()
    local request, artifacts, grant = fixture()
    local ai_calls = 0
    local runtime, writes = ports(request, artifacts, grant, {
      observe = function(turn)
        local value = observation(turn)
        value.turn = 0
        return value, {}
      end,
      ai_turn = function() ai_calls = ai_calls + 1 end,
    })
    local result = controller.run(request, runtime)
    t.eq(result.status, "blocked")
    t.eq(result.classification, "unsafe-browser-observation")
    t.eq(ai_calls, 0)
    t.eq(canonical_case(request, writes).non_execution_reason, "unsafe-browser-observation")
  end,
  test_observation_interruptions_before_and_after_an_action_are_distinct = function()
    do
      local request, artifacts, grant = fixture()
      local runtime, writes = ports(request, artifacts, grant, {
        observe = function() error("observation unavailable") end,
      })
      controller.run(request, runtime)
      local case_result = canonical_case(request, writes)
      t.eq(case_result.execution_status, "error")
      t.eq(case_result.error.code, "browser-observation-failed")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime, writes = ports(request, artifacts, grant, {
        observe = function(turn)
          if turn == 2 then error("observation lost after action") end
          return observation(turn), {}
        end,
      })
      controller.run(request, runtime)
      local case_result = canonical_case(request, writes)
      t.eq(case_result.execution_status, "lost")
      t.eq(case_result.non_execution_reason, "execution-lost-between-action-and-assertion")
    end
  end,
  test_invalid_completion_before_and_after_an_action_is_fail_closed = function()
    do
      local request, artifacts, grant = fixture()
      local runtime, writes = ports(request, artifacts, grant, {
        observe = function(turn) return observation(turn, { callback = true }), {} end,
        completion = { callback_observed = true },
      })
      controller.run(request, runtime)
      local case_result = canonical_case(request, writes)
      t.eq(case_result.execution_status, "error")
      t.eq(case_result.error.code, "invalid-browser-completion")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime, writes = ports(request, artifacts, grant, {
        callback_turn = 1,
        completion = { callback_observed = true },
      })
      controller.run(request, runtime)
      local case_result = canonical_case(request, writes)
      t.eq(case_result.execution_status, "lost")
      t.eq(case_result.non_execution_reason, "execution-lost-between-action-and-assertion")
    end
  end,
  test_in_progress_claim_before_effect_resumes_without_second_claim = function()
    local request, artifacts, grant = fixture()
    local writes = {}
    local effects = 0
    local first = ports(request, artifacts, grant, {
      writes = writes,
      failpoint = function(name) if name == "after-claim" then error("replace controller") end end,
      act = function() effects = effects + 1 end,
    })
    t.eq(controller.run(request, first).status, "blocked")
    t.eq(effects, 0)
    local second = ports(request, artifacts, grant, {
      writes = writes,
      claim = { status = "in-progress", claim_id = "claim-browser" },
      callback_turn = 1,
      act = function(turn, selected)
        effects = effects + 1
        return {
          schema = browser.schemas.step_receipt, turn = turn,
          action = structured.copy(selected), before = observation(turn),
          after = observation(turn, { callback = true }), status = "executed",
          classification = "effect-applied",
        }
      end,
    })
    t.eq(controller.run(request, second).status, "passed")
    t.eq(effects, 1)
  end,
  test_unresolved_effect_intent_recovers_as_lost_without_rerun = function()
    local request, artifacts, grant = fixture()
    local writes = {}
    local effects = 0
    local first = ports(request, artifacts, grant, {
      writes = writes,
      callback_turn = 1,
      failpoint = function(name) if name == "after-browser-effect" then error("browser acknowledgement lost") end end,
      act = function(turn, selected)
        effects = effects + 1
        return {
          schema = browser.schemas.step_receipt, turn = turn,
          action = structured.copy(selected), before = observation(turn),
          after = observation(turn, { callback = true }), status = "executed",
          classification = "effect-applied",
        }
      end,
    })
    t.eq(controller.run(request, first).status, "blocked")
    t.eq(effects, 1)
    local second, recovered = ports(request, artifacts, grant, {
      writes = writes,
      claim = { status = "in-progress", claim_id = "claim-browser" },
      act = function() effects = effects + 1 error("effect must not repeat") end,
    })
    t.eq(controller.run(request, second).status, "failed")
    t.eq(effects, 1)
    local case_result = canonical_case(request, recovered)
    t.eq(case_result.execution_status, "lost")
    t.eq(case_result.non_execution_reason, "execution-lost-between-action-and-assertion")
    local manifest = recovered[request.artifact_root .. "/evidence-manifest.json"]
    local effect_entry
    for _, entry in ipairs(manifest.entries) do
      if entry.redaction_classification == "sanitized-browser-effect-intent" then
        effect_entry = entry
        break
      end
    end
    t.is_true(type(effect_entry) == "table")
    t.is_true(effect_entry.evidence_id:match("^browser%-effect%-%x+$") ~= nil)
  end,
  test_recovery_and_effect_journal_fail_closed_matrix = function()
    local function successful_writes()
      local request, artifacts, grant = fixture()
      local runtime, writes = ports(request, artifacts, grant, { callback_turn = 1 })
      t.eq(controller.run(request, runtime).status, "passed")
      return request, artifacts, grant, writes
    end
    for _, failure in ipairs({ "compatibility", "replay" }) do
      local request, artifacts, grant, writes = successful_writes()
      local runtime = ports(request, artifacts, grant, {
        writes = writes, claim = { status = "in-progress", claim_id = "claim-browser" },
      })
      if failure == "compatibility" then
        local write = runtime.write_artifact
        runtime.write_artifact = function(path, value)
          if path == request.artifact_root .. "/case-results.json" then return false end
          return write(path, value)
        end
      else
        runtime.complete_replay = function() return false end
        local write = runtime.write_artifact
        runtime.write_artifact = function(path, value)
          if path == request.artifact_root .. "/metadata.json" then return true end
          return write(path, value)
        end
      end
      local replay_failure = controller.run(request, runtime)
      t.eq(replay_failure.status, "blocked")
      if failure == "replay" and replay_failure.message:find("replay completion failed", 1, true) == nil then
        error(replay_failure.message)
      end
    end
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant, { callback_turn = 1 })
      local write = runtime.write_artifact
      runtime.write_artifact = function(path, value)
        if path == request.artifact_root .. "/browser-agent-execution.json" then return false end
        return write(path, value)
      end
      t.eq(controller.run(request, runtime).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime, writes = ports(request, artifacts, grant, { callback_turn = 1 })
      local load = runtime.load_artifact
      runtime.load_artifact = function(path)
        if path:find("browser%-effects/turn%-1%-intent%.json$") and writes[path] then return nil end
        return load(path)
      end
      t.eq(controller.run(request, runtime).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant, { callback_turn = 1 })
      local artifact_digest = runtime.artifact_digest
      runtime.artifact_digest = function(path)
        if path == request.artifact_root .. "/evidence-manifest.json" then return nil end
        return artifact_digest(path)
      end
      t.eq(controller.run(request, runtime).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant, { callback_turn = 1 })
      local artifact_digest = runtime.artifact_digest
      runtime.artifact_digest = function(path)
        if path == request.artifact_root .. "/case-result-set.json" then return nil end
        return artifact_digest(path)
      end
      t.eq(controller.run(request, runtime).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local intent_path = request.artifact_root .. "/browser-effects/turn-1-intent.json"
      local writes = { [intent_path] = {
        schema = "testing-runner.ai-browser-control.effect-intent.v1",
        effect_id = "browser-effect-foreign", claim_id = "foreign", turn = 1,
        action = action(1, "click", { handle = "a1" }), target_id = "target-1",
        trace_id = request.trace_id, dedup_key = request.dedup_key,
      } }
      local runtime = ports(request, artifacts, grant, {
        writes = writes, claim = { status = "in-progress", claim_id = "claim-browser" },
      })
      t.eq(controller.run(request, runtime).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local intent_path = request.artifact_root .. "/browser-effects/turn-1-intent.json"
      local receipt_path = request.artifact_root .. "/browser-effects/turn-1-receipt.json"
      local selected = action(1, "click", { handle = "a1" })
      local writes = {
        [intent_path] = {
          schema = "testing-runner.ai-browser-control.effect-intent.v1",
          effect_id = "browser-effect-blocked", claim_id = "claim-browser", turn = 1,
          action = structured.copy(selected), target_id = "target-1",
          trace_id = request.trace_id, dedup_key = request.dedup_key,
        },
        [receipt_path] = {
          schema = browser.schemas.step_receipt, turn = 1, action = structured.copy(selected),
          before = observation(1), after = observation(1), status = "blocked",
          classification = "browser-step-rejected",
        },
      }
      local runtime, recovered = ports(request, artifacts, grant, {
        writes = writes, claim = { status = "in-progress", claim_id = "claim-browser" },
      })
      t.eq(controller.run(request, runtime).status, "blocked")
      t.eq(canonical_case(request, recovered).error.code, "browser-step-rejected")
    end
    do
      local request, artifacts, grant = fixture()
      local intent_path = request.artifact_root .. "/browser-effects/turn-1-intent.json"
      local receipt_path = request.artifact_root .. "/browser-effects/turn-1-receipt.json"
      local selected = action(1, "click", { handle = "a1" })
      local writes = {
        [intent_path] = {
          schema = "testing-runner.ai-browser-control.effect-intent.v1",
          effect_id = "browser-effect-recovered", claim_id = "claim-browser", turn = 1,
          action = structured.copy(selected), target_id = "target-1",
          trace_id = request.trace_id, dedup_key = request.dedup_key,
        },
        [receipt_path] = {
          schema = browser.schemas.step_receipt, turn = 1, action = structured.copy(selected),
          before = observation(1), after = observation(1), status = "executed",
          classification = "effect-applied",
        },
      }
      local runtime = ports(request, artifacts, grant, {
        writes = writes, claim = { status = "in-progress", claim_id = "claim-browser" },
      })
      t.eq(controller.run(request, runtime).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant)
      local load, intent_loads = runtime.load_artifact, 0
      runtime.load_artifact = function(path)
        if path:find("browser%-effects/turn%-1%-intent%.json$") then
          intent_loads = intent_loads + 1
          if intent_loads == 2 then return { value = {}, raw = "{}", digest = digest("a") } end
        end
        return load(path)
      end
      t.eq(controller.run(request, runtime).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant, { callback_turn = 1 })
      local write = runtime.write_artifact
      runtime.write_artifact = function(path, value)
        if path:find("browser%-effects/turn%-1%-receipt%.json$") then return false end
        return write(path, value)
      end
      t.eq(controller.run(request, runtime).status, "failed")
    end
  end,
  test_result_write_retry_reuses_effect_receipt_and_digest_identity = function()
    local request, artifacts, grant = fixture()
    local writes = {}
    local effects = 0
    local interrupted = false
    local first = ports(request, artifacts, grant, {
      writes = writes,
      callback_turn = 1,
      failpoint = function(name)
        if name == "after-case-result-set-write" and not interrupted then
          interrupted = true
          error("result write interrupted")
        end
      end,
      act = function(turn, selected)
        effects = effects + 1
        return {
          schema = browser.schemas.step_receipt, turn = turn,
          action = structured.copy(selected), before = observation(turn),
          after = observation(turn, { callback = true }), status = "executed",
          classification = "effect-applied",
        }
      end,
    })
    t.eq(controller.run(request, first).status, "blocked")
    local manifest_path = request.artifact_root .. "/evidence-manifest.json"
    local manifest_digest = sha256(json_codec.encode(writes[manifest_path]) .. "\n")
    local second = ports(request, artifacts, grant, {
      writes = writes,
      claim = { status = "in-progress", claim_id = "claim-browser" },
      act = function() effects = effects + 1 error("effect must not repeat") end,
    })
    t.eq(controller.run(request, second).status, "passed")
    t.eq(effects, 1)
    t.eq(sha256(json_codec.encode(writes[manifest_path]) .. "\n"), manifest_digest)
    t.eq(writes[request.artifact_root .. "/case-result-set.json"].evidence_manifest_artifact_sha256,
      manifest_digest)
  end,
  test_completed_grant_replay_performs_no_observation = function()
    local request, artifacts, grant = fixture()
    local replayed = {
      schema = "testing-runner.ai-browser-control-summary.v1",
      status = "passed", classification = "passed", mode = "agentic-browser",
      artifact_root = request.artifact_root,
      ["test_" .. "plan_path"] = request.artifact_root .. "/test-plan.json",
      execution_path = request.artifact_root .. "/browser-agent-execution.json",
      case_results_path = request.artifact_root .. "/case-results.json",
      case_result_set_path = request.artifact_root .. "/case-result-set.json",
      case_result_set_artifact_sha256 = digest("4"),
      evidence_manifest_path = request.artifact_root .. "/evidence-manifest.json",
      evidence_manifest_artifact_sha256 = digest("5"),
      case_count = 1, passed_count = 1, failed_count = 0, skipped_count = 0,
      error_count = 0, turn_count = 1, replayed = false,
    }
    local runtime, _, turns = ports(request, artifacts, grant, {
      claim = { status = "completed", result_ref = request.artifact_root .. "/browser-agent-execution.json" },
      replayed_result = replayed,
    })
    local result = controller.run(request, runtime)
    t.eq(result.status, "passed")
    t.eq(result.replayed, true)
    t.eq(turns(), 0)
  end,
  test_department_raises_testing_result = function()
    local request, artifacts, grant = fixture()
    local runtime = ports(request, artifacts, grant, { callback_turn = 1 })
    local trace = testing.run_fake(department, {
      queue = "ai_browser_control_request", payload = request, test_ports = runtime,
    })
    t.eq(department.spec.consumes[1], "ai_browser_control_request")
    t.eq(department.spec.produces[1], "testing_result")
    t.eq(trace.raises[1].queue, "testing_result")
    t.eq(trace.raises[1].payload.status, "passed")
  end,
  test_production_ports_fail_closed_and_return_complete_runtime = function()
    local previous = _G.ai_browser_control_runtime
    _G.ai_browser_control_runtime = nil
    t.raises(function() controller.production_ports() end)
    _G.ai_browser_control_runtime = { load_artifact = function() end }
    t.raises(function() controller.production_ports() end)
    local request, artifacts, grant = fixture()
    local runtime = ports(request, artifacts, grant)
    _G.ai_browser_control_runtime = runtime
    t.eq(controller.production_ports(), runtime)
    _G.ai_browser_control_runtime = previous
  end,
  test_browser_control_summary_contract_copies_only_bounded_values = function()
    local root = ".testing/runs/browser-summary"
    local summary = {
      schema = testing_contract.schemas.browser_control_summary,
      status = "passed", classification = "passed", mode = "agentic-browser",
      artifact_root = root,
      ["test_" .. "plan_path"] = root .. "/test-plan.json",
      execution_path = root .. "/browser-agent-execution.json",
      case_results_path = root .. "/case-results.json",
      case_result_set_path = root .. "/case-result-set.json",
      case_result_set_artifact_sha256 = digest("4"),
      evidence_manifest_path = root .. "/evidence-manifest.json",
      evidence_manifest_artifact_sha256 = digest("5"),
      case_count = 1, passed_count = 1, failed_count = 0, skipped_count = 0,
      error_count = 0, turn_count = 1, replayed = false,
    }
    local copied = testing_contract.copy_native_summary(summary)
    t.eq(copied.schema, summary.schema)
    t.eq(copied.execution_path, summary.execution_path)
    t.eq(copied.turn_count, 1)
    local mutations = {
      function(value) value.extra = true end,
      function(value) value.mode = "structured-api-cli" end,
      function(value) value.execution_path = value.artifact_root .. "/execution.json" end,
      function(value) value.turn_count = 65 end,
      function(value) value.replayed = "false" end,
    }
    for _, mutate in ipairs(mutations) do
      local value = structured.copy(summary)
      mutate(value)
      t.eq(testing_contract.copy_native_summary(value), nil)
    end
  end,
  test_controller_fail_closed_runtime_boundaries = function()
    local mutations = {
      function(request, artifacts)
        artifacts[request.environment_receipt_ref].value.sessions[2] = {
          role = "other-browser", cdp_url = "http://127.0.0.1:9333",
        }
      end,
      function(request, artifacts) artifacts[request.reviewed_plan_ref].value.trace_id = "foreign" end,
    }
    for _, mutate in ipairs(mutations) do
      local request, artifacts, grant = fixture()
      mutate(request, artifacts)
      t.eq(controller.run(request, ports(request, artifacts, grant)).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant)
      runtime.ai_turn = function() return { deferred = true } end
      t.eq(controller.run(request, runtime).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant, { callback_turn = 1 })
      runtime.write_artifact = function() return false end
      t.eq(controller.run(request, runtime).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant, { callback_turn = 1 })
      runtime.complete_replay = function() return false end
      t.eq(controller.run(request, runtime).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant)
      runtime.verify_grant = function() return {} end
      t.eq(controller.run(request, runtime).status, "blocked")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant, { claim = { status = "rejected" } })
      t.eq(controller.run(request, runtime).status, "blocked")
    end
  end,
  test_callback_before_action_and_unsafe_after_action_are_terminal = function()
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant, {
        observe = function(turn) return observation(turn, { callback = true }), {} end,
      })
      t.eq(controller.run(request, runtime).status, "passed")
    end
    do
      local request, artifacts, grant = fixture()
      local runtime = ports(request, artifacts, grant, {
        act = function(turn, selected)
          return {
            schema = browser.schemas.step_receipt, turn = turn, action = structured.copy(selected),
            before = observation(turn), after = observation(turn, { popup = true }),
            status = "executed", classification = "effect-applied",
          }
        end,
      })
      local result = controller.run(request, runtime)
      t.eq(result.status, "blocked")
      t.eq(result.classification, "browser-popup-detected")
    end
  end,
  test_default_runtime_and_ai_adapters_complete_one_browser_turn = function()
    local request, artifacts, grant = fixture()
    local runtime = ports(request, artifacts, grant)
    runtime.browser_observe = nil
    runtime.browser_act = nil
    runtime.ai_turn = nil
    runtime.exec_argv = function() return { exit_code = 0, stdout = "", stderr = "" } end
    runtime.read = function(path) return path end
    runtime.write = function() return true end
    runtime.decode = function(value)
      if value == "{}" then
        return action(1, "click", { handle = "a1" })
      end
      if value:find("step%-receipt", 1, false) then
        local selected = action(1, "click", { handle = "a1" })
        return {
          schema = browser.schemas.step_receipt, turn = 1, action = selected,
          before = observation(1), after = observation(1, { callback = true }),
          status = "executed", classification = "effect-applied",
        }
      end
      return observation(1)
    end
    local previous = _G.spawn_codex_sync
    _G.spawn_codex_sync = function() return { exit_code = 0, stdout = "{}", stderr = "" } end
    local result = controller.run(request, runtime)
    _G.spawn_codex_sync = previous
    t.eq(result.status, "passed")
    t.eq(result.turn_count, 1)
  end,
}
