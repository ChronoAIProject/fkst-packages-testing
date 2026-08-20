local browser_contract = require("contract.browser_control")
local environment_contract = require("contract.environment_factory")
local structured_contract = require("contract.structured_execution")
local testing_contract = require("contract.testing")
local evidence_contract = require("contract.testing_evidence_manifest")
local results_contract = require("contract.testing_results")
local browser_ai = require("testing_ai.browser_control")
local browser_runtime = require("testing_runtime.browser_control")
local json_codec = require("testing_runtime.json")

local M = {}

local required_ports = {
  "load_artifact", "write_artifact", "artifact_digest", "now", "verify_grant",
  "replay_guard", "complete_replay", "load_result", "verify_completion", "decode",
  "monotonic_seconds", "sha256",
}

local terminal_outcomes = {
  passed = { execution_status = "passed", classification = "deterministic" },
  deterministic_completion_failed = { execution_status = "failed", classification = "assertion_failure" },
  time_budget_exhausted = { execution_status = "blocked", classification = "blocked", reason = "browser-time-budget-exhausted" },
  step_budget_exhausted = { execution_status = "blocked", classification = "blocked", reason = "browser-step-budget-exhausted" },
  unsafe_observation = { execution_status = "blocked", classification = "blocked" },
  callback_detection_failed = { execution_status = "error", classification = "execution_error" },
  action_invalid = { execution_status = "error", classification = "execution_error" },
  browser_step_failed = { execution_status = "error", classification = "execution_error" },
  controller_interrupted = { execution_status = "error", classification = "execution_error" },
  assertion_lost = { execution_status = "lost", classification = "lost", reason = "execution-lost-between-action-and-assertion" },
  repeated_action = { execution_status = "blocked", classification = "blocked", reason = "repeated-ai-action" },
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

local function summary(request, outcome, replayed, artifacts)
  local status = outcome.status == "passed" and "passed"
    or (outcome.status == "failed" or outcome.status == "lost") and "failed" or "blocked"
  local passed = status == "passed" and 1 or 0
  local failed = status == "failed" and 1 or 0
  local errors = status == "blocked" and 1 or 0
  local value = {
    schema = testing_contract.schemas.browser_control_summary,
    status = status,
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
  for key, item in pairs(artifacts or {}) do value[key] = item end
  return value
end

local function artifact_ref(path, sha256)
  return { kind = "artifact", ref = path, sha256 = sha256 }
end

local function evidence_ref(evidence_id)
  return { kind = "evidence", ref = evidence_id }
end

local function failpoint(ports, name, value)
  if type(ports.failpoint) == "function" then ports.failpoint(name, copy(value)) end
end

local function effect_journal(request, claim, turn, action, observation, ports)
  local identity = {
    claim_id = claim.claim_id,
    grant_sha256 = request.browser_grant_sha256,
    plan_sha256 = request.reviewed_plan_sha256,
    target_id = observation.target_id,
    turn = turn,
    action = copy(action),
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  local effect_id = "browser-effect-" .. ports.sha256(json_codec.encode(identity))
  local root = request.artifact_root .. "/browser-effects/turn-" .. tostring(turn)
  return {
    intent_path = root .. "-intent.json",
    receipt_path = root .. "-receipt.json",
    intent = {
      schema = "testing-runner.ai-browser-control.effect-intent.v1",
      effect_id = effect_id,
      claim_id = claim.claim_id,
      turn = turn,
      action = copy(action),
      target_id = observation.target_id,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    },
  }
end

local function repository_result(request, ports)
  local source = json_codec.encode(request.repository)
  local source_sha256 = ports.sha256(source)
  return {
    id = "repository-" .. source_sha256:sub(1, 32),
    source_ref = {
      kind = results_contract.repository_source_kinds.git,
      ref = request.repository.url .. "@" .. request.repository.commit_sha,
    },
    source_sha256 = source_sha256,
  }
end

local function assertion_authority(request, browser_case)
  local assertions = {}
  for _, assertion in ipairs(browser_case.completion_assertions) do
    table.insert(assertions, {
      assertion_id = assertion.assertion_id,
      required = assertion.required,
    })
  end
  return {
    plan_ref = { kind = "artifact", ref = request.reviewed_plan_ref },
    plan_sha256 = request.reviewed_plan_sha256,
    reviewed_case_id = browser_case.case_id,
    assertions = assertions,
  }
end

local function normalize_outcome(outcome)
  local normalized = terminal_outcomes[outcome.kind]
  if normalized == nil then error("testing-runner: ai-browser-control: unknown terminal outcome") end
  local message = tostring(outcome.message or outcome.reason or outcome.kind)
    :gsub("[%z\1-\31\127]", " "):sub(1, 512)
  local reason = normalized.reason or outcome.reason
  local requires_reason = normalized.execution_status == "blocked"
    or normalized.execution_status == "lost" or normalized.execution_status == "skipped"
  return {
    execution_status = normalized.execution_status,
    classification = normalized.classification,
    public_classification = reason or normalized.classification,
    non_execution_reason = requires_reason and reason or nil,
    error = normalized.execution_status == "error" and {
      code = reason or outcome.kind,
      message = message,
    } or nil,
  }
end

local function write_json_evidence(path, value, ports)
  if ports.write_artifact(path, value) ~= true then
    error("testing-runner: ai-browser-control: evidence artifact write failed")
  end
  local sha256 = ports.artifact_digest(path)
  if type(sha256) ~= "string" then error("testing-runner: ai-browser-control: evidence digest unavailable") end
  return sha256, #json_codec.encode(value) + 1
end

local function optional_artifact_evidence(request, browser_case, raw_observations, entries, created_at, ports)
  for observation_index, item in ipairs(raw_observations) do
    for _, candidate in ipairs({
      { field = "screenshot", role = "screenshot", media_type = "image/png", sensitivity = "internal", redaction = "sanitized-browser-screenshot" },
      { field = "runner_output", role = "runner-log", media_type = "text/plain", sensitivity = "internal", redaction = "sanitized-runner-output" },
    }) do
      local path = item.runtime_paths and item.runtime_paths[candidate.field]
      if path ~= nil then
        if type(path) ~= "string" or path:sub(1, #request.artifact_root + 1) ~= request.artifact_root .. "/"
          or type(item.artifact_metadata) ~= "table" or type(item.artifact_metadata[candidate.field]) ~= "table" then
          error("testing-runner: ai-browser-control: optional evidence metadata is unavailable")
        end
        local metadata = item.artifact_metadata[candidate.field]
        if ports.artifact_digest(path) ~= metadata.sha256 or type(metadata.size_bytes) ~= "number" then
          error("testing-runner: ai-browser-control: optional evidence metadata differs")
        end
        table.insert(entries, {
          evidence_id = candidate.field .. "-" .. tostring(observation_index),
          case_id = browser_case.case_id,
          role = candidate.role,
          artifact_ref = { kind = "artifact", ref = path },
          sha256 = metadata.sha256,
          media_type = candidate.media_type,
          size_bytes = metadata.size_bytes,
          producer = "testing-runtime.browser-control",
          producer_version = "1",
          created_at = created_at,
          sensitivity = candidate.sensitivity,
          redaction_classification = candidate.redaction,
          policy_version = "agentic-browser-execution.v1",
          policy_status = "redacted",
          provenance = { source_kind = "browser-runtime", source_ref = path, source_sha256 = metadata.sha256 },
        })
      end
    end
  end
end

local function collect_observations(request, raw_observations, receipt_ref, ports, entries, created_at)
  local observations = {}
  for index, item in ipairs(raw_observations) do
    local path = request.artifact_root .. "/evidence/browser-observation-" .. tostring(index) .. ".json"
    local sha256, size_bytes = write_json_evidence(path, item.value, ports)
    local evidence_id = "browser-observation-" .. tostring(index)
    local ref = evidence_ref(evidence_id)
    table.insert(entries, {
      evidence_id = evidence_id,
      case_id = item.case_id,
      role = "sanitized-json",
      artifact_ref = { kind = "artifact", ref = path },
      sha256 = sha256,
      media_type = "application/json",
      size_bytes = size_bytes,
      producer = "testing-runner.ai-browser-control",
      producer_version = "2",
      created_at = created_at,
      sensitivity = "internal",
      redaction_classification = "sanitized-browser-observation",
      policy_version = "agentic-browser-execution.v1",
      policy_status = "redacted",
      provenance = { source_kind = "browser", source_ref = receipt_ref.ref, source_sha256 = receipt_ref.sha256 },
    })
    table.insert(observations, {
      schema = results_contract.schemas.observation,
      observation_id = evidence_id,
      kind = "sanitized-browser-observation",
      subject = "browser-target",
      value = table.concat({
        "turn=" .. tostring(item.value.turn), item.phase, item.value.ready_state,
        "document=" .. browser_contract.document_digest(item.value),
        "callback=" .. tostring(item.value.signals.callback_detected),
        "console=" .. tostring(item.value.console_count),
        "network=" .. tostring(item.value.network_count),
      }, ";"),
      source_ref = artifact_ref(path, sha256),
      evidence_refs = { ref },
    })
  end
  return observations
end

local function assertion_results(browser_case, completion, normalized, observation_ids, receipt_evidence_ref)
  local assertions = {}
  for _, authority in ipairs(browser_case.completion_assertions) do
    local status, classification
    if completion[authority.completion_field] then
      status, classification = "passed", "deterministic"
    elseif normalized.execution_status == "failed" and authority.required then
      status, classification = "failed", "assertion_failure"
    else
      status, classification = "skipped", "skipped"
    end
    table.insert(assertions, {
      schema = results_contract.schemas.assertion_result,
      assertion_id = authority.assertion_id,
      type = authority.type,
      required = authority.required,
      status = status,
      classification = classification,
      observation_ids = copy(observation_ids),
      evidence_refs = { copy(receipt_evidence_ref) },
    })
  end
  return assertions
end

local function required_completion_passed(browser_case, completion)
  local required = 0
  for _, authority in ipairs(browser_case.completion_assertions) do
    if authority.required then
      required = required + 1
      if not completion[authority.completion_field] then return false end
    end
  end
  return required > 0
end

local function write_terminal(request, environment, plan, grant_artifact, steps, raw_observations, completion, outcome, claim, ports, started_at, started_monotonic)
  local effect_records = raw_observations.effect_records or {}
  local browser_case = plan.cases[1]
  local receipt_path = request.artifact_root .. "/browser-agent-execution.json"
  local plan_path = request.artifact_root .. "/test-plan.json"
  local results_path = request.artifact_root .. "/case-result-set.json"
  local manifest_path = request.artifact_root .. "/evidence-manifest.json"
  local compatibility_path = request.artifact_root .. "/case-results.json"
  local metadata_path = request.artifact_root .. "/metadata.json"
  local persisted_result = ports.load_artifact(results_path)
  local persisted_manifest = ports.load_artifact(manifest_path)
  local persisted_receipt = ports.load_artifact(receipt_path)
  if persisted_result ~= nil and persisted_manifest ~= nil and persisted_receipt ~= nil then
    local authority = assertion_authority(request, browser_case)
    browser_contract.validate_receipt(persisted_receipt.value, grant_artifact.value)
    results_contract.validate_case_result_set(
      persisted_result.value, { authority }, persisted_manifest.value, ports.sha256)
    evidence_contract.validate(persisted_manifest.value, persisted_result.value, ports.sha256)
    if ports.write_artifact(compatibility_path, persisted_result.value) ~= true then
      error("testing-runner: ai-browser-control: compatibility result artifact write failed")
    end
    local persisted_case = persisted_result.value.cases[1]
    local native = summary(request, {
      status = persisted_case.execution_status,
      classification = persisted_case.classification,
      turn_count = #persisted_receipt.value.steps,
    }, false, {
      case_result_set_path = results_path,
      case_result_set_artifact_sha256 = persisted_result.digest,
      evidence_manifest_path = manifest_path,
      evidence_manifest_artifact_sha256 = persisted_manifest.digest,
    })
    if ports.write_artifact(metadata_path, {
      schema = testing_contract.schemas.native_metadata,
      job = "ai-browser-control",
      status = native.status,
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
  local normalized = normalize_outcome(outcome)
  local receipt_status = normalized.execution_status == "passed" and "passed"
    or normalized.execution_status == "failed" and "failed" or "blocked"
  local receipt = {
    schema = browser_contract.schemas.receipt,
    status = receipt_status,
    classification = normalized.public_classification,
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
  failpoint(ports, "before-test-plan-write", { path = plan_path })
  if ports.write_artifact(plan_path, plan) ~= true
    or ports.write_artifact(receipt_path, receipt) ~= true then
    error("testing-runner: ai-browser-control: terminal artifact write failed")
  end
  local receipt_sha256 = ports.artifact_digest(receipt_path)
  if type(receipt_sha256) ~= "string" then error("testing-runner: ai-browser-control: receipt digest unavailable") end
  local receipt_evidence_id = "browser-execution-receipt"
  local receipt_evidence_ref = evidence_ref(receipt_evidence_id)
  local created_at = ports.now()
  local entries = { {
    evidence_id = receipt_evidence_id,
    case_id = browser_case.case_id,
    role = "sanitized-json",
    artifact_ref = { kind = "artifact", ref = receipt_path },
    sha256 = receipt_sha256,
    media_type = "application/json",
    size_bytes = #json_codec.encode(receipt) + 1,
    producer = "testing-runner.ai-browser-control",
    producer_version = "2",
    created_at = created_at,
    sensitivity = "internal",
    redaction_classification = "sanitized-browser-receipt",
    policy_version = "agentic-browser-execution.v1",
    policy_status = "redacted",
    provenance = { source_kind = "runner", source_ref = receipt_path, source_sha256 = receipt_sha256 },
  } }
  for _, effect in ipairs(effect_records) do
    local intent_artifact = ports.load_artifact(effect.intent_path)
    if type(intent_artifact) ~= "table" or type(intent_artifact.digest) ~= "string"
      or type(intent_artifact.value) ~= "table" or intent_artifact.value.effect_id ~= effect.intent.effect_id then
      error("testing-runner: ai-browser-control: effect intent artifact is unavailable")
    end
    table.insert(entries, {
      evidence_id = effect.intent.effect_id,
      case_id = browser_case.case_id,
      role = "sanitized-json",
      artifact_ref = { kind = "artifact", ref = effect.intent_path },
      sha256 = intent_artifact.digest,
      media_type = "application/json",
      size_bytes = #intent_artifact.raw,
      producer = "testing-runner.ai-browser-control",
      producer_version = "2",
      created_at = created_at,
      sensitivity = "internal",
      redaction_classification = "sanitized-browser-effect-intent",
      policy_version = "agentic-browser-execution.v1",
      policy_status = "redacted",
      provenance = { source_kind = "runner", source_ref = effect.intent_path, source_sha256 = intent_artifact.digest },
    })
  end
  local observations = collect_observations(request, raw_observations,
    artifact_ref(receipt_path, receipt_sha256), ports, entries, created_at)
  optional_artifact_evidence(request, browser_case, raw_observations, entries, created_at, ports)
  local observation_ids = {}
  for _, observation in ipairs(observations) do table.insert(observation_ids, observation.observation_id) end
  local authority = assertion_authority(request, browser_case)
  local assertions = assertion_results(browser_case, completion, normalized, observation_ids, receipt_evidence_ref)
  local repository = repository_result(request, ports)
  local completed_monotonic = ports.monotonic_seconds()
  local case_result = {
    schema = results_contract.schemas.case_result,
    case_id = browser_case.case_id,
    repository = repository,
    reviewed_case_id = browser_case.case_id,
    plan_ref = copy(authority.plan_ref),
    plan_sha256 = request.reviewed_plan_sha256,
    execution_mode = "browser",
    execution_status = normalized.execution_status,
    classification = normalized.classification,
    observations = observations,
    assertions = assertions,
    evidence_refs = { receipt_evidence_ref },
    timing = {
      started_at = started_at,
      completed_at = created_at,
      duration_ms = math.max(0, math.floor((completed_monotonic - started_monotonic) * 1000)),
    },
    error = normalized.error,
    non_execution_reason = normalized.non_execution_reason,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  results_contract.validate_case_result(case_result, authority)
  local run_id = request.artifact_root:match("^%.testing/runs/([^/]+)")
  local manifest = {
    schema = evidence_contract.schema,
    manifest_id = run_id .. "-browser-evidence",
    canonicalization = evidence_contract.canonicalization,
    canonical_sha256 = string.rep("0", 64),
    repository = copy(repository),
    run_id = run_id,
    plan_ref = copy(authority.plan_ref),
    plan_sha256 = request.reviewed_plan_sha256,
    entries = entries,
  }
  manifest.canonical_sha256 = evidence_contract.sha256(manifest, ports.sha256)
  failpoint(ports, "before-evidence-manifest-write", { path = manifest_path })
  if ports.write_artifact(manifest_path, manifest) ~= true then
    error("testing-runner: ai-browser-control: canonical result artifact write failed")
  end
  failpoint(ports, "after-evidence-manifest-write", { path = manifest_path })
  local manifest_artifact_sha256 = ports.artifact_digest(manifest_path)
  if type(manifest_artifact_sha256) ~= "string" then
    error("testing-runner: ai-browser-control: evidence manifest digest unavailable")
  end
  local result_set = {
    schema = results_contract.schemas.case_result_set,
    set_id = run_id .. "-browser-results",
    run_id = run_id,
    plan_ref = copy(authority.plan_ref),
    plan_sha256 = request.reviewed_plan_sha256,
    cases = { case_result },
    evidence_manifest_ref = artifact_ref(manifest_path, manifest_artifact_sha256),
    evidence_manifest_sha256 = manifest.canonical_sha256,
    evidence_manifest_artifact_sha256 = manifest_artifact_sha256,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  results_contract.validate_case_result_set(result_set, { authority }, manifest, ports.sha256)
  failpoint(ports, "before-case-result-set-write", { path = results_path })
  if ports.write_artifact(results_path, result_set) ~= true then
    error("testing-runner: ai-browser-control: canonical result artifact write failed")
  end
  failpoint(ports, "after-case-result-set-write", { path = results_path })
  failpoint(ports, "before-compatibility-result-write", { path = compatibility_path })
  if ports.write_artifact(compatibility_path, result_set) ~= true then
    error("testing-runner: ai-browser-control: compatibility result artifact write failed")
  end
  local result_set_artifact_sha256 = ports.artifact_digest(results_path)
  if type(result_set_artifact_sha256) ~= "string" then
    error("testing-runner: ai-browser-control: case result set digest unavailable")
  end
  local native = summary(request, {
    status = normalized.execution_status,
    classification = normalized.public_classification,
    turn_count = #steps,
  }, false, {
    case_result_set_path = results_path,
    case_result_set_artifact_sha256 = result_set_artifact_sha256,
    evidence_manifest_path = manifest_path,
    evidence_manifest_artifact_sha256 = manifest_artifact_sha256,
  })
  if ports.write_artifact(metadata_path, {
    schema = testing_contract.schemas.native_metadata,
    job = "ai-browser-control",
    status = native.status,
    artifact_root = request.artifact_root,
    source_ref = copy(request.source_ref),
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    adapter = { name = "fkst-native", mode = "agentic-browser" },
    native_summary = native,
  }) ~= true then error("testing-runner: ai-browser-control: metadata write failed") end
  failpoint(ports, "before-replay-completion", { claim_id = claim.claim_id })
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
  if (claim.status ~= "claimed" and claim.status ~= "in-progress")
    or type(claim.claim_id) ~= "string" or claim.claim_id == "" then
    error("testing-runner: ai-browser-control: replay guard did not claim execution")
  end
  failpoint(ports, "after-claim", { claim_id = claim.claim_id, replayed = claim.status == "in-progress" })

  local context = {
    artifact_root = request.artifact_root,
    grant = grant,
    cdp_url = cdp_url(environment),
  }
  local steps, seen_actions, effect_records = {}, {}, {}
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
  local started_at = ports.now()
  local started = ports.monotonic_seconds()
  local raw_observations = {}
  local function terminal(outcome)
    raw_observations.effect_records = effect_records
    return write_terminal(request, environment, plan, grant_artifact, steps, raw_observations,
      completion, outcome, claim, ports, started_at, started)
  end
  for turn = 1, grant.step_budget do
    if ports.monotonic_seconds() - started >= grant.time_budget_seconds then
      return terminal({ kind = "time_budget_exhausted" })
    end
    local recovered = false
    local recovered_intent_path = request.artifact_root .. "/browser-effects/turn-" .. tostring(turn) .. "-intent.json"
    local stored_intent = ports.load_artifact(recovered_intent_path)
    if stored_intent ~= nil then
      local intent = stored_intent.value
      if type(intent) ~= "table" or intent.schema ~= "testing-runner.ai-browser-control.effect-intent.v1"
        or intent.claim_id ~= claim.claim_id or intent.turn ~= turn or intent.trace_id ~= request.trace_id
        or intent.dedup_key ~= request.dedup_key then
        error("testing-runner: ai-browser-control: effect intent identity differs")
      end
      browser_contract.validate_action(intent.action, grant.allowed_actions, grant.approved_secret_refs)
      local effect = {
        intent_path = recovered_intent_path,
        receipt_path = request.artifact_root .. "/browser-effects/turn-" .. tostring(turn) .. "-receipt.json",
        intent = copy(intent),
      }
      table.insert(effect_records, effect)
      local stored_receipt = ports.load_artifact(effect.receipt_path)
      if stored_receipt == nil then
        return terminal({ kind = "assertion_lost", message = "browser effect outcome is uncertain: " .. intent.effect_id })
      end
      local valid_stored_step, stored_step_error = pcall(
        browser_contract.validate_step_receipt, stored_receipt.value, grant)
      if not valid_stored_step then return terminal({ kind = "assertion_lost", message = stored_step_error }) end
      local step = copy(stored_receipt.value)
      table.insert(steps, step)
      table.insert(raw_observations, { case_id = plan.cases[1].case_id, phase = "before-action", value = copy(step.before) })
      table.insert(raw_observations, { case_id = plan.cases[1].case_id, phase = "after-action", value = copy(step.after) })
      if step.status == "blocked" then
        return terminal({ kind = "browser_step_failed", reason = step.classification })
      end
      local recovered_unsafe = unsafe_observation(step.after)
      if recovered_unsafe ~= nil then return terminal({ kind = "unsafe_observation", reason = recovered_unsafe }) end
      if step.after.signals.callback_detected then
        local verified, verified_completion = pcall(ports.verify_completion, request)
        if not verified then return terminal({ kind = "assertion_lost", message = verified_completion }) end
        local valid_completion, completion_error = pcall(browser_contract.validate_completion, verified_completion)
        if not valid_completion then return terminal({ kind = "assertion_lost", message = completion_error }) end
        completion = verified_completion
        return terminal({ kind = required_completion_passed(plan.cases[1], completion)
          and "passed" or "deterministic_completion_failed", reason = "browser-completion-asserted" })
      end
      recovered = true
    end
    if not recovered then
    local observed, observation, runtime_paths = pcall(observe, context, turn)
    if not observed then return terminal({ kind = #steps > 0 and "assertion_lost" or "controller_interrupted", reason = #steps > 0 and nil or "browser-observation-failed", message = observation }) end
    local valid_observation, observation_error = pcall(browser_contract.validate_observation, observation)
    if not valid_observation then return terminal({ kind = "unsafe_observation", reason = "unsafe-browser-observation", message = observation_error }) end
    table.insert(raw_observations, {
      case_id = plan.cases[1].case_id, phase = "before-action", value = copy(observation),
      runtime_paths = copy(runtime_paths), artifact_metadata = copy(runtime_paths and runtime_paths.artifact_metadata),
    })
    local unsafe = unsafe_observation(observation)
    if unsafe ~= nil then
      return terminal({ kind = "unsafe_observation", reason = unsafe })
    end
    if observation.signals.callback_detected then
      local verified, verified_completion = pcall(ports.verify_completion, request)
      if not verified then return terminal({ kind = #steps > 0 and "assertion_lost" or "callback_detection_failed", reason = #steps > 0 and nil or "callback-verification-failed", message = verified_completion }) end
      local valid_completion, completion_error = pcall(browser_contract.validate_completion, verified_completion)
      if not valid_completion then return terminal({ kind = #steps > 0 and "assertion_lost" or "callback_detection_failed", reason = #steps > 0 and nil or "invalid-browser-completion", message = completion_error }) end
      completion = verified_completion
      return terminal({ kind = required_completion_passed(plan.cases[1], completion)
        and "passed" or "deterministic_completion_failed", reason = "browser-completion-asserted" })
    end
    local chose, ai_result = pcall(ai_turn, plan.cases[1], grant, observation)
    if not chose then return terminal({ kind = "controller_interrupted", reason = "browser-controller-interrupted", message = ai_result }) end
    local parsed, action = pcall(parse_action, ai_result, ports, grant, turn)
    if not parsed then return terminal({ kind = "action_invalid", reason = "browser-action-invalid", message = action }) end
    local key = action_key(action)
    if seen_actions[key] then
      return terminal({ kind = "repeated_action" })
    end
    seen_actions[key] = true
    local effect = effect_journal(request, claim, turn, action, observation, ports)
    if ports.load_artifact(effect.intent_path) ~= nil then
      error("testing-runner: ai-browser-control: effect intent appeared concurrently")
    end
    if ports.write_artifact(effect.intent_path, effect.intent) ~= true then
      error("testing-runner: ai-browser-control: effect intent artifact write failed")
    end
    table.insert(effect_records, effect)
    failpoint(ports, "after-effect-intent", { effect_id = effect.intent.effect_id })
    local acted, step = pcall(act, context, turn, action, runtime_paths)
    if not acted then return terminal({ kind = "assertion_lost", message = step }) end
    failpoint(ports, "after-browser-effect", { effect_id = effect.intent.effect_id })
    local valid_step, step_error = pcall(browser_contract.validate_step_receipt, step, grant)
    if not valid_step then return terminal({ kind = "assertion_lost", message = step_error }) end
    if ports.write_artifact(effect.receipt_path, step) ~= true then
      return terminal({ kind = "assertion_lost", message = "browser effect receipt write failed" })
    end
    table.insert(steps, step)
    table.insert(raw_observations, { case_id = plan.cases[1].case_id, phase = "after-action", value = copy(step.after) })
    if step.status == "blocked" then
      return terminal({ kind = "browser_step_failed", reason = step.classification })
    end
    unsafe = unsafe_observation(step.after)
    if unsafe ~= nil then return terminal({ kind = "unsafe_observation", reason = unsafe }) end
    if step.after.signals.callback_detected then
      local verified, verified_completion = pcall(ports.verify_completion, request)
      if not verified then return terminal({ kind = "assertion_lost", message = verified_completion }) end
      local valid_completion, completion_error = pcall(browser_contract.validate_completion, verified_completion)
      if not valid_completion then return terminal({ kind = "assertion_lost", message = completion_error }) end
      completion = verified_completion
      return terminal({ kind = required_completion_passed(plan.cases[1], completion)
        and "passed" or "deterministic_completion_failed", reason = "browser-completion-asserted" })
    end
    end
  end
  return terminal({ kind = "step_budget_exhausted" })
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
