local browser_contract = require("contract.browser_control")
local environment_contract = require("contract.environment_factory")
local structured_contract = require("contract.structured_execution")
local testing_contract = require("contract.testing")
local browser_ai = require("testing_ai.browser_control")
local browser_runtime = require("testing_runtime.browser_control")

local M = {}

local required_ports = {
  "load_artifact", "write_artifact", "artifact_digest", "now", "verify_grant",
  "replay_guard", "complete_replay", "load_result", "verify_completion", "decode",
  "monotonic_seconds",
}

local function copy(value)
  return structured_contract.copy(value)
end

local function blocked(message)
  return {
    status = "blocked",
    classification = "harness-tooling-issue",
    message = tostring(message):sub(1, 600),
  }
end

function M.production_ports()
  local ports = _G.ai_browser_control_runtime
  if type(ports) ~= "table" then
    error("testing-runner: ai-browser-control: host runtime capability is unavailable")
  end
  for _, name in ipairs(required_ports) do
    if type(ports[name]) ~= "function" then
      error("testing-runner: ai-browser-control: missing runtime port " .. name)
    end
  end
  return ports
end

local function load_bound(ports, path, expected_digest, label)
  local artifact = ports.load_artifact(path)
  if type(artifact) ~= "table" or artifact.digest ~= expected_digest
    or type(artifact.value) ~= "table" then
    error("testing-runner: ai-browser-control: " .. label .. " digest mismatch")
  end
  return artifact
end

local function same_repository(left, right)
  return structured_contract.same_repository(left, right)
end

local function cdp_url(environment)
  local found
  for _, session in ipairs(environment.sessions or {}) do
    if type(session.cdp_url) == "string" then
      if found ~= nil and found ~= session.cdp_url then
        error("testing-runner: ai-browser-control: conflicting CDP endpoints")
      end
      found = session.cdp_url
    end
  end
  if found == nil then error("testing-runner: ai-browser-control: ready CDP endpoint is unavailable") end
  return found
end

local function action_key(action)
  return table.concat({
    action.kind or "", action.handle or "", action.secret_ref or "", action.advisory_status or "",
  }, "\0")
end

local function parse_action(result, ports, grant, turn)
  if type(result) ~= "table" or result.deferred == true or result.exit_code ~= 0
    or type(result.stdout) ~= "string" or #result.stdout > 4096 then
    error("testing-runner: ai-browser-control: AI turn did not return bounded JSON")
  end
  local action = ports.decode(result.stdout)
  browser_contract.validate_action(action, grant.allowed_actions, grant.approved_secret_refs)
  if action.turn ~= turn then error("testing-runner: ai-browser-control: AI action turn is stale") end
  return action
end

local function unsafe_observation(observation)
  local signals = observation.signals
  if signals.target_changed then return "browser-target-changed" end
  if signals.popup_detected then return "browser-popup-detected" end
  if signals.mfa_detected then return "browser-mfa-detected" end
  if signals.captcha_detected then return "browser-captcha-detected" end
  return nil
end

local function completion_passed(completion)
  return completion.callback_observed and completion.process_exit_zero
    and completion.whoami_succeeded and completion.status_authenticated
end

local function summary(request, outcome, replayed)
  local passed = outcome.status == "passed" and 1 or 0
  local failed = outcome.status == "failed" and 1 or 0
  local errors = outcome.status == "blocked" and 1 or 0
  return {
    schema = testing_contract.schemas.browser_control_summary,
    status = outcome.status,
    classification = outcome.classification,
    mode = "agentic-browser",
    artifact_root = request.artifact_root,
    test_plan_path = request.artifact_root .. "/test-plan.json",
    execution_path = request.artifact_root .. "/browser-agent-execution.json",
    case_results_path = request.artifact_root .. "/case-results.json",
    case_count = 1,
    passed_count = passed,
    failed_count = failed,
    skipped_count = 0,
    error_count = errors,
    turn_count = outcome.turn_count or 0,
    replayed = replayed == true,
  }
end

local function write_terminal(request, environment, plan, grant_artifact, steps, completion, outcome, claim, ports)
  local browser_case = plan.cases[1]
  local receipt_path = request.artifact_root .. "/browser-agent-execution.json"
  local plan_path = request.artifact_root .. "/test-plan.json"
  local results_path = request.artifact_root .. "/case-results.json"
  local receipt = {
    schema = browser_contract.schemas.receipt,
    status = outcome.status,
    classification = outcome.classification,
    repository = copy(request.repository),
    environment_receipt_sha256 = request.environment_receipt_sha256,
    reviewed_plan_sha256 = request.reviewed_plan_sha256,
    browser_grant_sha256 = request.browser_grant_sha256,
    readiness_attempt_sha256 = grant_artifact.value.readiness_attempt_sha256,
    target_sha256 = grant_artifact.value.target_sha256,
    case_id = browser_case.case_id,
    steps = copy(steps),
    completion = copy(completion),
    artifact_root = request.artifact_root,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  browser_contract.validate_receipt(receipt, grant_artifact.value)
  if ports.write_artifact(plan_path, plan) ~= true
    or ports.write_artifact(receipt_path, receipt) ~= true then
    error("testing-runner: ai-browser-control: terminal artifact write failed")
  end
  local case_status = outcome.status == "passed" and "passed"
    or outcome.status == "failed" and "failed" or "error"
  local classification = outcome.status == "passed" and "passed"
    or outcome.status == "failed" and "product-defect" or "environment-session-issue"
  if ports.write_artifact(results_path, {
    schema = "testing-structured-case-results.v1",
    plan_sha256 = request.reviewed_plan_sha256,
    cases = { {
      case_id = browser_case.case_id,
      kind = "browser",
      status = case_status,
      classification = classification,
      assertions = {},
      evidence_ref = receipt_path,
    } },
  }) ~= true then error("testing-runner: ai-browser-control: case results write failed") end
  local native = summary(request, {
    status = outcome.status,
    classification = outcome.classification,
    turn_count = #steps,
  }, false)
  if ports.write_artifact(request.artifact_root .. "/metadata.json", {
    schema = testing_contract.schemas.native_metadata,
    job = "ai-browser-control",
    status = outcome.status,
    artifact_root = request.artifact_root,
    source_ref = copy(request.source_ref),
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    adapter = { name = "fkst-native", mode = "agentic-browser" },
    native_summary = native,
  }) ~= true then error("testing-runner: ai-browser-control: metadata write failed") end
  if ports.complete_replay(claim, receipt_path) ~= true then
    error("testing-runner: ai-browser-control: replay completion failed")
  end
  return native
end

local function run_inner(request, ports)
  browser_contract.validate_request(request)
  local environment_artifact = load_bound(ports, request.environment_receipt_ref,
    request.environment_receipt_sha256, "environment receipt")
  local plan_artifact = load_bound(ports, request.reviewed_plan_ref,
    request.reviewed_plan_sha256, "reviewed plan")
  local grant_artifact = load_bound(ports, request.browser_grant_ref,
    request.browser_grant_sha256, "browser grant")
  local environment = environment_artifact.value
  environment_contract.validate_receipt(environment)
  structured_contract.validate_plan(plan_artifact.value)
  local now = ports.now()
  browser_contract.validate_grant(grant_artifact.value, now)
  local plan = plan_artifact.value
  local grant = grant_artifact.value
  if environment.status ~= "ready" or plan.execution_mode ~= "agentic-browser"
    or not same_repository(environment.repository, request.repository)
    or not same_repository(plan.repository, request.repository)
    or not same_repository(grant.repository, request.repository)
    or plan.environment_receipt_sha256 ~= request.environment_receipt_sha256
    or grant.environment_receipt_sha256 ~= request.environment_receipt_sha256
    or grant.reviewed_plan_sha256 ~= request.reviewed_plan_sha256
    or environment.trace_id ~= request.trace_id or environment.dedup_key ~= request.dedup_key
    or plan.trace_id ~= request.trace_id or plan.dedup_key ~= request.dedup_key
    or grant.trace_id ~= request.trace_id or grant.dedup_key ~= request.dedup_key then
    error("testing-runner: ai-browser-control: artifact identity binding differs")
  end
  local correlation = environment.browser_readiness and environment.browser_readiness.correlation
  if type(correlation) ~= "table" or correlation.target_id ~= grant.target_id
    or correlation.target_sha256 ~= grant.target_sha256
    or correlation.readiness_attempt_sha256 ~= grant.readiness_attempt_sha256
    or correlation.attempt_id ~= grant.readiness_attempt_id
    or ports.artifact_digest(correlation.readiness_attempt_ref.ref) ~= grant.readiness_attempt_sha256 then
    error("testing-runner: ai-browser-control: readiness target binding differs")
  end
  local verified = ports.verify_grant({
    grant = grant, grant_raw = grant_artifact.raw,
    grant_sha256 = grant_artifact.digest, now = now,
  })
  if not structured_contract.attestation_matches(verified, grant, grant_artifact.digest) then
    error("testing-runner: ai-browser-control: browser grant authentication failed")
  end
  local claim = ports.replay_guard({
    grant_id = grant.grant_id,
    grant_sha256 = grant_artifact.digest,
    plan_sha256 = plan_artifact.digest,
    environment_receipt_sha256 = environment_artifact.digest,
    readiness_attempt_sha256 = grant.readiness_attempt_sha256,
    target_sha256 = grant.target_sha256,
    repository = request.repository,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  })
  if type(claim) ~= "table" then error("testing-runner: ai-browser-control: replay guard rejected execution") end
  if claim.status == "completed" then
    local replayed = ports.load_result(claim.result_ref)
    if type(replayed) ~= "table" then error("testing-runner: ai-browser-control: replay result is unavailable") end
    replayed.replayed = true
    return replayed
  end
  if claim.status ~= "claimed" or type(claim.claim_id) ~= "string" or claim.claim_id == "" then
    error("testing-runner: ai-browser-control: replay guard did not claim execution")
  end

  local context = {
    artifact_root = request.artifact_root,
    grant = grant,
    cdp_url = cdp_url(environment),
  }
  local steps, seen_actions = {}, {}
  local completion = {
    callback_observed = false, process_exit_zero = false,
    whoami_succeeded = false, status_authenticated = false,
  }
  local observe = ports.browser_observe or function(value, turn)
    return browser_runtime.observe(value, turn, ports)
  end
  local act = ports.browser_act or function(value, turn, action, runtime_paths)
    return browser_runtime.act(value, turn, action, runtime_paths, ports)
  end
  local ai_turn = ports.ai_turn or function(browser_case, value, observation)
    return browser_ai.choose(browser_case, value, observation, {
      worktree = ports.worktree or ".",
      dedup_key = request.dedup_key,
    })
  end
  local started = ports.monotonic_seconds()
  for turn = 1, grant.step_budget do
    if ports.monotonic_seconds() - started >= grant.time_budget_seconds then
      return write_terminal(request, environment, plan, grant_artifact, steps, completion, {
        status = "blocked", classification = "browser-time-budget-exhausted",
      }, claim, ports)
    end
    local observation, runtime_paths = observe(context, turn)
    browser_contract.validate_observation(observation)
    local unsafe = unsafe_observation(observation)
    if unsafe ~= nil then
      return write_terminal(request, environment, plan, grant_artifact, steps, completion, {
        status = "blocked", classification = unsafe,
      }, claim, ports)
    end
    if observation.signals.callback_detected then
      completion = browser_contract.validate_completion(ports.verify_completion(request))
      if completion_passed(completion) then
        return write_terminal(request, environment, plan, grant_artifact, steps, completion, {
          status = "passed", classification = "passed",
        }, claim, ports)
      end
    end
    local action = parse_action(ai_turn(plan.cases[1], grant, observation), ports, grant, turn)
    local key = action_key(action)
    if seen_actions[key] then
      return write_terminal(request, environment, plan, grant_artifact, steps, completion, {
        status = "blocked", classification = "repeated-ai-action",
      }, claim, ports)
    end
    seen_actions[key] = true
    local step = act(context, turn, action, runtime_paths)
    browser_contract.validate_step_receipt(step, grant)
    table.insert(steps, step)
    unsafe = unsafe_observation(step.after)
    if unsafe ~= nil then
      return write_terminal(request, environment, plan, grant_artifact, steps, completion, {
        status = "blocked", classification = unsafe,
      }, claim, ports)
    end
    if step.after.signals.callback_detected then
      completion = browser_contract.validate_completion(ports.verify_completion(request))
      if completion_passed(completion) then
        return write_terminal(request, environment, plan, grant_artifact, steps, completion, {
          status = "passed", classification = "passed",
        }, claim, ports)
      end
    end
  end
  return write_terminal(request, environment, plan, grant_artifact, steps, completion, {
    status = "blocked", classification = "browser-step-budget-exhausted",
  }, claim, ports)
end

function M.run(request, supplied_ports)
  local ports = supplied_ports or M.production_ports()
  local ok, result = pcall(run_inner, request, ports)
  if ok then return result end
  return blocked(result)
end

function M.result_payload(request, supplied_ports)
  local outcome = M.run(request, supplied_ports)
  local native = outcome.schema == testing_contract.schemas.browser_control_summary
    and outcome or summary(request, outcome, outcome.replayed)
  return {
    schema = testing_contract.schemas.runner_result,
    job = "ai-browser-control",
    status = native.status,
    artifact_root = request.artifact_root,
    source_ref = copy(request.source_ref),
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    adapter = { name = "fkst-native", mode = "agentic-browser" },
    stderr_excerpt = native.status == "blocked" and tostring(outcome.message or native.classification):sub(1, 600) or nil,
    native_summary = native,
  }
end

return M
