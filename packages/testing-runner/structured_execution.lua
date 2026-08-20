local M = {}
local browser_readiness_contract = require("contract.browser_readiness")
local environment_contract = require("contract.environment_factory")
local execution_contract = require("contract.structured_execution")
local project_profile_contract = require("contract.project_profile")
local testing_contract = require("contract.testing")
local evidence_manifest_contract = require("contract.testing_evidence_manifest")
local results_contract = require("contract.testing_results")
local results_compat = require("contract.testing_results_compat")
local strings = require("contract.strings")
local time_contract = require("contract.time")
local local_runtime = require("testing_runtime.structured_execution")

local copy = execution_contract.copy
local max_argv = 32

local function dense_list(value, maximum)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    if key > highest then highest = key end
  end
  return count == highest and count <= maximum
end

local function bounded(value, maximum)
  return type(value) == "string" and value ~= "" and #value <= maximum and value:find("[%z\1-\31]") == nil
end

local function safe_pointer(value)
  return bounded(value, 4096)
    and value:sub(1, 14) == ".testing/runs/"
    and value:find("..", 1, true) == nil
end

local function sha256(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function only_fields(value, allowed, label)
  if type(value) ~= "table" then error("testing-runner: structured-execution: " .. label .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then error("testing-runner: structured-execution: unsupported " .. label .. " field " .. tostring(key)) end
  end
end

local request_fields = {
  schema = true,
  repository = true,
  project_profile_ref = true,
  project_profile_artifact_sha256 = true,
  profile_sha256 = true,
  validation_receipt_ref = true,
  validation_receipt_sha256 = true,
  preauthorization_ref = true,
  preauthorization_sha256 = true,
  environment_receipt_ref = true,
  environment_receipt_sha256 = true,
  browser_readiness_ref = true,
  browser_readiness_sha256 = true,
  test_plan_ref = true,
  test_plan_sha256 = true,
  execution_grant_ref = true,
  execution_grant_sha256 = true,
  artifact_root = true,
  trace_id = true,
  dedup_key = true,
  source_ref = true,
}

function M.validate_request(value)
  if type(value) ~= "table" then error("testing-runner: structured-execution: request must be a table") end
  for key, _ in pairs(value) do
    if request_fields[key] ~= true then error("testing-runner: structured-execution: unsupported request field " .. tostring(key)) end
  end
  if value.schema ~= "testing-runner.structured-execution.request.v3" then
    error("testing-runner: structured-execution: unknown request schema")
  end
  local repository = value.repository
  only_fields(repository, { url = true, commit_sha = true }, "repository")
  if type(repository) ~= "table" or not bounded(repository.url, 512) or repository.url:find("@", 1, true)
    or type(repository.commit_sha) ~= "string" or #repository.commit_sha ~= 40
    or repository.commit_sha:match("^[0-9a-f]+$") == nil then
    error("testing-runner: structured-execution: immutable repository identity is required")
  end
  for _, field in ipairs({ "project_profile_ref", "validation_receipt_ref", "preauthorization_ref", "environment_receipt_ref", "browser_readiness_ref", "test_plan_ref", "execution_grant_ref", "artifact_root" }) do
    if not safe_pointer(value[field]) then error("testing-runner: structured-execution: unsafe pointer " .. field) end
  end
  for _, field in ipairs({ "project_profile_artifact_sha256", "profile_sha256", "validation_receipt_sha256", "preauthorization_sha256", "environment_receipt_sha256", "browser_readiness_sha256", "test_plan_sha256", "execution_grant_sha256" }) do
    if not sha256(value[field]) then error("testing-runner: structured-execution: invalid digest " .. field) end
  end
  if not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then
    error("testing-runner: structured-execution: bounded trace and dedup identity are required")
  end
  if type(value.source_ref) ~= "table" or not bounded(value.source_ref.kind, 80)
    or not strings.is_path_safe_key(value.source_ref.ref, 180)
    or value.source_ref.ref:find("/", 1, true) ~= nil then
    error("testing-runner: structured-execution: source_ref is required")
  end
  local artifact_run_id = strings.artifact_run_id(value.artifact_root)
  if artifact_run_id == nil or artifact_run_id ~= value.source_ref.ref then
    error("testing-runner: structured-execution: artifact_root run identity differs from source_ref")
  end
  return value
end

local function blocked(message)
  return {
    status = "blocked",
    classification = "harness-tooling-issue",
    message = message,
  }
end

local required_ports = {
  "sha256_bytes", "load_artifact", "now", "verify_grant", "replay_guard", "authorize_cli_effect",
  "exec_argv", "http_request", "write_artifact", "load_result", "complete_replay",
}

function M.production_ports()
  local ports = _G.structured_execution_runtime
  if type(ports) ~= "table" then ports = local_runtime.production() end
  for _, name in ipairs(required_ports) do
    if type(ports[name]) ~= "function" then error("testing-runner: structured-execution: missing runtime port " .. name) end
  end
  return ports
end

local function same_repository(left, right)
  return type(left) == "table"
    and type(right) == "table"
    and left.url == right.url
    and left.commit_sha == right.commit_sha
end

local function argv_allowed(argv, capabilities)
  for _, capability in ipairs(capabilities or {}) do
    local prefix = capability.argv_prefix
    if dense_list(prefix, max_argv) and #prefix > 0 and #prefix <= #argv then
      local matches = true
      for index, item in ipairs(prefix) do
        if argv[index] ~= item then matches = false break end
      end
      if matches then return true end
    end
  end
  return false
end

local function contains(list, expected)
  local found = false
  for _, item in ipairs(list or {}) do if item == expected then found = true end end
  return found
end

local function http_allowed(request, capabilities, base_url)
  local origin, path = execution_contract.local_http_origin(request.url)
  local base_origin = execution_contract.local_http_origin(base_url)
  if origin == nil or base_origin == nil or origin ~= base_origin then return false end
  for _, capability in ipairs(capabilities or {}) do
    local capability_origin = execution_contract.local_http_origin(capability.origin)
    if capability_origin == base_origin and contains(capability.methods, request.method) then
      for _, prefix in ipairs(capability.path_prefixes or {}) do
        if path:sub(1, #prefix) == prefix then return true end
      end
    end
  end
  return false
end

local function http_capabilities_bound(capabilities, base_url)
  local base_origin = execution_contract.local_http_origin(base_url)
  if base_origin == nil then return false end
  for _, capability in ipairs(capabilities or {}) do
    if execution_contract.local_http_origin(capability.origin) ~= base_origin then return false end
  end
  return true
end

local function assert_cli(assertion, response)
  return tonumber(response.exit_code) == assertion.expected
end

local function assert_http(assertion, response)
  if assertion.type == "status-code" then
    return tonumber(response.status) == assertion.expected
  end
  return tostring(response.body or ""):find(assertion.expected, 1, true) ~= nil
end

local function effect_error(case, value)
  return {
    case_id = case.case_id,
    kind = case.kind,
    status = "error",
    classification = "environment-session-issue",
    assertions = {},
    evidence = { error_excerpt = tostring(value):sub(1, 600) },
  }
end

local function valid_effect_response(case, response)
  if type(response) ~= "table" then return false end
  if case.kind == "cli" then
    return type(response.exit_code) == "number" and response.exit_code == math.floor(response.exit_code)
      and type(response.stdout) == "string" and type(response.stderr) == "string"
  end
  return type(response.status) == "number" and response.status == math.floor(response.status)
    and response.status >= 100 and response.status <= 599 and type(response.body) == "string"
    and type(response.headers) == "table"
end

local function execute_case(case, grant, ports, context)
  if case.skip_reason ~= nil then
    return {
      case_id = case.case_id,
      kind = case.kind,
      status = "skipped",
      classification = case.skip_classification,
      assertions = {},
      evidence = { reason = case.skip_reason },
    }
  end
  local effect = {
    operation_id = context.environment.operation_id,
    case_id = case.case_id,
    repository = copy(context.request.repository),
    environment_receipt_sha256 = context.environment_digest,
    artifact_root = context.request.artifact_root,
    trace_id = context.request.trace_id,
    dedup_key = context.request.dedup_key,
    timeout_seconds = case.timeout_seconds,
  }
  local ok, response
  if case.kind == "cli" then
    if not argv_allowed(case.argv, grant.cli_capabilities) then
      error("testing-runner: structured-execution: unauthorized cli capability")
    end
    local envelope = {
      schema = execution_contract.schemas.cli_action_envelope,
      effect_kind = "cli", capability = "direct-argv",
      profile_ref = context.request.project_profile_ref,
      profile_artifact_sha256 = context.profile.digest,
      profile_sha256 = context.request.profile_sha256,
      validation_receipt_ref = context.request.validation_receipt_ref,
      validation_receipt_sha256 = context.validation.digest,
      preauthorization_ref = context.request.preauthorization_ref,
      preauthorization_sha256 = context.preauthorization.digest,
      repository = copy(context.request.repository),
      run_id = context.request.source_ref.ref, operation_id = context.environment.operation_id,
      environment_receipt_ref = context.request.environment_receipt_ref,
      environment_receipt_sha256 = context.environment_digest,
      workspace_ref = copy(context.environment.workspace_ref),
      plan_ref = context.request.test_plan_ref, plan_sha256 = context.plan.digest,
      grant_ref = context.request.execution_grant_ref, grant_sha256 = context.grant.digest,
      case = copy(case),
      resource_bounds = { output_bytes = context.profile.value.resource_budgets.output_bytes },
      attempt = 1, trace_id = context.request.trace_id, dedup_key = context.request.dedup_key,
      expires_at = grant.expires_at, fence_id = context.claim.claim_id,
    }
    execution_contract.validate_cli_action_envelope(envelope)
    local receipt = ports.authorize_cli_effect({
      action_envelope = envelope, artifact_root = context.request.artifact_root,
      operation_id = context.environment.operation_id,
      trace_id = context.request.trace_id, dedup_key = context.request.dedup_key,
    })
    local receipt_ok = pcall(execution_contract.validate_effect_authorization_receipt,
      receipt, envelope, context.now)
    local authorization_path = context.request.artifact_root
      .. "/authorization/" .. case.case_id .. ".json"
    if not receipt_ok or ports.write_artifact(authorization_path, receipt) ~= true then
      error("testing-runner: structured-execution: malformed CLI authorization receipt")
    end
    if receipt.decision ~= "allow" then
      return {
        case_id = case.case_id, kind = case.kind, status = "error",
        classification = "harness-tooling-issue", assertions = {},
        evidence = {
          authorization_receipt_path = authorization_path,
          authorization_reason = receipt.reason_code,
        },
      }
    end
    ok, response = pcall(ports.exec_argv, {
      action_envelope = envelope,
      authorization_receipt = receipt,
      artifact_root = context.request.artifact_root,
    })
  else
    if not http_allowed(case.request, grant.http_capabilities, context.environment.base_url) then
      error("testing-runner: structured-execution: unauthorized http capability")
    end
    effect.base_url = context.environment.base_url
    effect.request = copy(case.request)
    ok, response = pcall(ports.http_request, effect)
  end
  local case_result = not ok and effect_error(case, response) or nil
  if case_result == nil then
    if not valid_effect_response(case, response) then
      case_result = effect_error(case, "effect returned a malformed response")
    else
      local assertions = {}
      local passed = true
      for index, assertion in ipairs(case.assertions) do
        local assertion_passed = case.kind == "cli" and assert_cli(assertion, response) or assert_http(assertion, response)
        assertions[index] = { type = assertion.type, passed = assertion_passed }
        if not assertion_passed then passed = false end
      end
      case_result = {
        case_id = case.case_id,
        kind = case.kind,
        status = passed and "passed" or "failed",
        classification = passed and "passed" or "product-defect",
        assertions = assertions,
        evidence = case.kind == "cli" and {
          exit_code = tonumber(response.exit_code) or -1,
          stdout_excerpt = tostring(response.stdout or ""):sub(1, 600),
          stderr_excerpt = tostring(response.stderr or ""):sub(1, 600),
          authorization_receipt_path = context.request.artifact_root
            .. "/authorization/" .. case.case_id .. ".json",
        } or {
          status_code = tonumber(response.status) or 0,
          body_excerpt = tostring(response.body or ""):sub(1, 600),
        },
      }
    end
  end
  return case_result
end

local function aggregate(case_results)
  local counts = { passed = 0, failed = 0, skipped = 0, error = 0 }
  local classification = "passed"
  for _, result in ipairs(case_results) do
    counts[result.status] = counts[result.status] + 1
    if result.status == "failed" then classification = "product-defect" end
    if result.status == "error" and classification ~= "product-defect" then classification = result.classification end
    if result.status == "skipped" and classification == "passed" then classification = result.classification end
  end
  local status = counts.failed > 0 and "failed"
    or (counts.error > 0 and "blocked")
    or (counts.skipped > 0 and "degraded")
    or "passed"
  return status, classification, counts
end

local function load_bound(ports, path, digest, label)
  local artifact = ports.load_artifact(path)
  if type(artifact) ~= "table" or artifact.digest ~= digest or type(artifact.value) ~= "table" then
    error("testing-runner: structured-execution: " .. label .. " digest mismatch")
  end
  return artifact
end

local function equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
  for key, _ in pairs(right) do if left[key] == nil then return false end end
  return true
end

local function hash_bytes(ports, bytes)
  local digest = ports.sha256_bytes(bytes)
  if not sha256(digest) then error("testing-runner: structured-execution: malformed sha256_bytes result") end
  return digest
end

local function write_reload(ports, path, value, label)
  if ports.write_artifact(path, value) ~= true then
    error("testing-runner: structured-execution: " .. label .. " write failed")
  end
  local artifact = ports.load_artifact(path)
  if type(artifact) ~= "table" or type(artifact.raw) ~= "string" or not sha256(artifact.digest)
    or hash_bytes(ports, artifact.raw) ~= artifact.digest
    or type(artifact.value) ~= "table" or not equal(artifact.value, value) then
    error("testing-runner: structured-execution: " .. label .. " reload mismatch")
  end
  return artifact
end

local function current_time(ports, request, environment)
  return ports.now({
    artifact_root = request.artifact_root,
    operation_id = environment.operation_id,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  })
end

local function timing(started_at, completed_at)
  local started = time_contract.iso_timestamp_epoch_seconds(started_at)
  local completed = time_contract.iso_timestamp_epoch_seconds(completed_at)
  if started == nil or completed == nil then
    error("testing-runner: structured-execution: malformed case timestamp")
  end
  return {
    started_at = started_at,
    completed_at = completed_at,
    duration_ms = math.min(86400000, math.max(0, (completed - started) * 1000)),
  }
end

local function canonical_repository(request, ports)
  return {
    id = request.repository.commit_sha,
    source_ref = {
      kind = results_contract.repository_source_kinds.git,
      ref = request.repository.url .. "@" .. request.repository.commit_sha,
    },
    source_sha256 = hash_bytes(ports, request.repository.url .. "\n" .. request.repository.commit_sha),
  }
end

local outcome_pairs = {
  ["passed\0passed"] = { status = "passed", classification = "deterministic" },
  ["failed\0product-defect"] = { status = "failed", classification = "assertion_failure" },
  ["skipped\0data-fixture-gap"] = { status = "skipped", classification = "not_applicable" },
  ["skipped\0not-executed-risk"] = { status = "skipped", classification = "not_applicable" },
  ["error\0environment-session-issue"] = { status = "error", classification = "execution_error" },
  ["error\0harness-tooling-issue"] = { status = "error", classification = "execution_error" },
}

local function error_message(legacy)
  local value = legacy.evidence and legacy.evidence.error_excerpt
  if type(value) ~= "string" or value == "" then return "structured case execution error" end
  value = value:gsub("[%z\1-\31\127]", " "):sub(1, 512)
  return value ~= "" and value or "structured case execution error"
end

local function canonical_case(case, legacy, evidence_id, repository, plan_ref, plan_sha256, case_timing, trace_id, dedup_key)
  local normalized = outcome_pairs[legacy.status .. "\0" .. legacy.classification]
  if normalized == nil then error("testing-runner: structured-execution: unsupported legacy outcome") end
  local assertions = {}
  local executed = legacy.status == "passed" or legacy.status == "failed"
  for index, planned in ipairs(case.assertions) do
    local status, classification = "skipped", "skipped"
    if executed then
      local fact = legacy.assertions[index]
      if type(fact) ~= "table" or type(fact.passed) ~= "boolean" or fact.type ~= planned.type then
        error("testing-runner: structured-execution: assertion execution facts differ from plan")
      end
      status = fact.passed and "passed" or "failed"
      classification = fact.passed and "deterministic" or "assertion_failure"
    end
    assertions[index] = {
      schema = results_contract.schemas.assertion_result,
      assertion_id = "assertion-" .. tostring(index),
      type = planned.type,
      required = true,
      status = status,
      classification = classification,
      observation_ids = {},
      evidence_refs = {},
    }
  end
  local result = {
    schema = results_contract.schemas.case_result,
    case_id = case.case_id,
    repository = copy(repository),
    reviewed_case_id = case.case_id,
    plan_ref = copy(plan_ref),
    plan_sha256 = plan_sha256,
    execution_mode = case.kind,
    execution_status = normalized.status,
    classification = normalized.classification,
    observations = {},
    assertions = assertions,
    evidence_refs = { { kind = "evidence", ref = evidence_id } },
    timing = case_timing,
    trace_id = trace_id,
    dedup_key = dedup_key,
  }
  if legacy.status == "skipped" then result.non_execution_reason = legacy.classification end
  if legacy.status == "error" then
    result.error = { code = legacy.classification, message = error_message(legacy) }
  end
  return result
end

local function evidence_entry(case, index, path, artifact, completed_at)
  local evidence_id = "evidence-" .. tostring(index)
  return evidence_id, {
    evidence_id = evidence_id,
    case_id = case.case_id,
    role = "sanitized-json",
    artifact_ref = { kind = "artifact", ref = path },
    sha256 = artifact.digest,
    media_type = "application/json",
    size_bytes = #artifact.raw,
    producer = "testing-runner",
    producer_version = "structured-execution.v1",
    created_at = completed_at,
    sensitivity = "internal",
    redaction_classification = "bounded-excerpts",
    policy_version = "structured-evidence-policy.v1",
    policy_status = "redacted",
    provenance = {
      source_kind = "artifact",
      source_ref = path,
      source_sha256 = artifact.digest,
    },
  }
end

function M.run(request, ports)
  local ok, result = pcall(function()
    M.validate_request(request)
    local profile = load_bound(ports, request.project_profile_ref, request.project_profile_artifact_sha256, "project profile")
    local validation = load_bound(ports, request.validation_receipt_ref, request.validation_receipt_sha256, "validation receipt")
    local preauthorization = load_bound(ports, request.preauthorization_ref, request.preauthorization_sha256, "preauthorization")
    local environment = load_bound(ports, request.environment_receipt_ref, request.environment_receipt_sha256, "environment receipt")
    local readiness = load_bound(ports, request.browser_readiness_ref, request.browser_readiness_sha256, "browser readiness")
    local plan = load_bound(ports, request.test_plan_ref, request.test_plan_sha256, "test plan")
    local grant = load_bound(ports, request.execution_grant_ref, request.execution_grant_sha256, "execution grant")

    local profile_ok = pcall(project_profile_contract.validate_profile, profile.value)
    local validation_ok = pcall(project_profile_contract.validate_validation_receipt, validation.value)
    local preauthorization_ok = pcall(execution_contract.validate_preauthorization, preauthorization.value)
    local environment_ok = pcall(environment_contract.validate_receipt, environment.value)
    if not profile_ok or not validation_ok or not preauthorization_ok
      or validation.value.profile_sha256 ~= request.profile_sha256
      or preauthorization.value.profile_sha256 ~= request.profile_sha256
      or validation.value.repository.url ~= request.repository.url
      or validation.value.repository.commit_sha ~= request.repository.commit_sha
      or preauthorization.value.repository.url ~= request.repository.url
      or preauthorization.value.repository.commit_sha ~= request.repository.commit_sha
      or not environment_ok or environment.value.status ~= "ready"
      or environment.value.operation_id ~= request.source_ref.ref
      or not same_repository(environment.value.repository, request.repository)
      or type(environment.value.browser_readiness) ~= "table"
      or environment.value.browser_readiness.status ~= "ready"
      or execution_contract.local_http_origin(environment.value.base_url) == nil
      or environment.value.trace_id ~= request.trace_id
      or environment.value.dedup_key ~= request.dedup_key then
      return blocked("environment receipt does not prove readiness for this run")
    end
    local readiness_ok = pcall(browser_readiness_contract.validate_result, readiness.value)
    if not readiness_ok or readiness.value.status ~= "ready"
      or type(readiness.value.source_ref) ~= "table" or readiness.value.source_ref.kind ~= "workflow-qa"
      or readiness.value.source_ref.ref ~= request.source_ref.ref
      or type(readiness.value.correlation) ~= "table"
      or readiness.value.correlation.trace_id ~= request.trace_id
      or readiness.value.correlation.dedup_key ~= request.dedup_key then
      return blocked("post-design browser readiness does not belong to this run")
    end
    local plan_ok = pcall(execution_contract.validate_plan, plan.value)
    if not plan_ok or plan.value.execution_mode ~= "structured-api-cli"
      or not same_repository(plan.value.repository, request.repository)
      or plan.value.environment_receipt_sha256 ~= request.environment_receipt_sha256
      or plan.value.browser_readiness_sha256 ~= request.browser_readiness_sha256
      or plan.value.trace_id ~= request.trace_id or plan.value.dedup_key ~= request.dedup_key then
      return blocked("test plan does not belong to this environment")
    end

    local now = ports.now({
      artifact_root = request.artifact_root,
      operation_id = environment.value.operation_id,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    })
    local grant_ok = pcall(execution_contract.validate_grant, grant.value, now)
    if not grant_ok or grant.value.plan_sha256 ~= request.test_plan_sha256
      or grant.value.parent_authorization_sha256 ~= preauthorization.digest
      or grant.value.environment_receipt_sha256 ~= request.environment_receipt_sha256
      or not same_repository(grant.value.repository, request.repository)
      or not http_capabilities_bound(grant.value.http_capabilities, environment.value.base_url)
      or grant.value.trace_id ~= request.trace_id
      or grant.value.dedup_key ~= request.dedup_key then
      return blocked("execution grant does not belong to this plan")
    end
    local verified = ports.verify_grant({
      grant = grant.value,
      grant_raw = grant.raw,
      grant_sha256 = grant.digest,
      now = now,
      artifact_root = request.artifact_root,
      operation_id = environment.value.operation_id,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    })
    if not execution_contract.attestation_matches(verified, grant.value, grant.digest) then
      return blocked("execution grant authentication failed")
    end
    local claim = ports.replay_guard({
      grant_id = grant.value.grant_id,
      grant_sha256 = grant.digest,
      parent_authorization_sha256 = grant.value.parent_authorization_sha256,
      plan_sha256 = plan.digest,
      environment_receipt_sha256 = environment.digest,
      repository = request.repository,
      artifact_root = request.artifact_root,
      operation_id = environment.value.operation_id,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    })
    if type(claim) ~= "table" then return blocked("replay guard rejected execution") end
    if claim.status == "completed" then
      local replayed = ports.load_result({
        artifact_root = request.artifact_root,
        result_ref = claim.result_ref,
        result_sha256 = claim.result_sha256,
        operation_id = environment.value.operation_id,
        repository = copy(request.repository),
        environment_receipt_sha256 = environment.digest,
        trace_id = request.trace_id,
        dedup_key = request.dedup_key,
      })
      if type(replayed) ~= "table" then return blocked("completed replay result is unavailable") end
      replayed.replayed = true
      return replayed
    end
    if claim.status ~= "claimed" or not bounded(claim.claim_id, 180) then
      return blocked("replay guard did not claim execution")
    end

    local run_id = request.source_ref.ref
    local test_plan_path = request.artifact_root .. "/test-plan.json"
    local evidence_manifest_path = request.artifact_root .. "/evidence-manifest.json"
    local case_result_set_path = request.artifact_root .. "/case-result-set.json"
    local case_results_path = request.artifact_root .. "/case-results.json"
    local execution_path = request.artifact_root .. "/execution.json"
    local plan_ref = { kind = "artifact", ref = test_plan_path }
    local persisted_plan = write_reload(ports, test_plan_path, plan.value, "plan")
    if persisted_plan.digest ~= plan.digest then
      error("testing-runner: structured-execution: persisted plan digest differs from source plan")
    end

    local repository = canonical_repository(request, ports)
    local case_results, canonical_cases, evidence_entries = {}, {}, {}
    local authorities = results_contract.plan_assertion_authorities(plan.value, plan_ref, plan.digest)
    local execution_context = {
      request = request,
      profile = profile,
      validation = validation,
      preauthorization = preauthorization,
      environment = environment.value,
      environment_digest = environment.digest,
      plan = plan,
      grant = grant,
      claim = claim,
      now = now,
    }
    for index, case in ipairs(plan.value.cases) do
      local started_at = current_time(ports, request, environment.value)
      local case_result = execute_case(case, grant.value, ports, execution_context)
      local completed_at = current_time(ports, request, environment.value)
      local case_timing = timing(started_at, completed_at)
      local evidence_path = request.artifact_root .. "/evidence/" .. case.case_id .. ".json"
      local evidence_artifact = write_reload(ports, evidence_path, case_result.evidence, "evidence")
      local evidence_id, entry = evidence_entry(case, index, evidence_path, evidence_artifact, completed_at)
      local authority = authorities[index]
      local canonical = canonical_case(case, case_result, evidence_id, repository, plan_ref,
        plan.digest, case_timing, request.trace_id, request.dedup_key)
      results_contract.validate_case_result(canonical, authority)
      canonical_cases[index], evidence_entries[index] = canonical, entry
      case_result.evidence = nil
      case_result.evidence_ref = evidence_path
      case_results[index] = case_result
    end
    local status, classification, counts = aggregate(case_results)
    local root_context = { artifact_root = request.artifact_root }
    local hash = function(bytes) return hash_bytes(ports, bytes) end
    local manifest = {
      schema = evidence_manifest_contract.schema,
      manifest_id = run_id,
      canonicalization = evidence_manifest_contract.canonicalization,
      canonical_sha256 = string.rep("0", 64),
      repository = copy(repository),
      run_id = run_id,
      plan_ref = copy(plan_ref),
      plan_sha256 = plan.digest,
      entries = evidence_entries,
    }
    manifest.canonical_sha256 = evidence_manifest_contract.sha256(manifest, hash, root_context)
    evidence_manifest_contract.validate(manifest, nil, hash, root_context)
    local persisted_manifest = write_reload(ports, evidence_manifest_path, manifest, "evidence manifest")
    local result_set = {
      schema = results_contract.schemas.case_result_set,
      set_id = run_id,
      run_id = run_id,
      plan_ref = copy(plan_ref),
      plan_sha256 = plan.digest,
      cases = canonical_cases,
      evidence_manifest_ref = { kind = "artifact", ref = evidence_manifest_path,
        sha256 = persisted_manifest.digest },
      evidence_manifest_sha256 = manifest.canonical_sha256,
      evidence_manifest_artifact_sha256 = persisted_manifest.digest,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    }
    results_contract.validate_case_result_set(result_set, authorities, manifest, hash, root_context)
    local persisted_result_set = write_reload(ports, case_result_set_path, result_set, "case result set")
    local compat_context = {
      artifact_root = request.artifact_root,
      plan_sha256 = plan.digest,
      plan = plan.value,
      repository = repository,
      run_id = run_id,
      plan_ref = plan_ref,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
      sha256_bytes = hash,
    }
    local projected = results_compat.project_v1(result_set, manifest, compat_context)
    results_compat.validate_v1(projected, compat_context)
    write_reload(ports, case_results_path, projected, "case results")
    local execution = {
      schema = "testing-structured-execution.v1",
      operation_id = environment.value.operation_id,
      status = status,
      classification = classification,
      repository = request.repository,
      environment_receipt_sha256 = environment.digest,
      browser_readiness_sha256 = readiness.digest,
      plan_sha256 = plan.digest,
      grant_sha256 = grant.digest,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
      case_count = #case_results,
      passed_count = counts.passed,
      failed_count = counts.failed,
      skipped_count = counts.skipped,
      error_count = counts.error,
      test_plan_path = test_plan_path,
      case_results_path = case_results_path,
      case_result_set_path = case_result_set_path,
      case_result_set_artifact_sha256 = persisted_result_set.digest,
      evidence_manifest_path = evidence_manifest_path,
      evidence_manifest_artifact_sha256 = persisted_manifest.digest,
      execution_path = execution_path,
    }
    if ports.write_artifact(execution_path, execution) ~= true then error("testing-runner: structured-execution: execution write failed") end
    local result = {
      schema = testing_contract.schemas.structured_execution_summary,
      status = status,
      classification = classification,
      mode = "structured-api-cli",
      artifact_root = request.artifact_root,
      case_count = #case_results,
      passed_count = counts.passed,
      failed_count = counts.failed,
      skipped_count = counts.skipped,
      error_count = counts.error,
      test_plan_path = test_plan_path,
      case_results_path = case_results_path,
      case_result_set_path = case_result_set_path,
      case_result_set_artifact_sha256 = persisted_result_set.digest,
      evidence_manifest_path = evidence_manifest_path,
      evidence_manifest_artifact_sha256 = persisted_manifest.digest,
      execution_path = execution_path,
      replayed = false,
    }
    if ports.write_artifact(request.artifact_root .. "/metadata.json", {
      schema = testing_contract.schemas.native_metadata,
      job = "structured-execution",
      status = status,
      artifact_root = request.artifact_root,
      source_ref = request.source_ref,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
      adapter = { name = "fkst-native", mode = "structured-api-cli" },
      native_summary = result,
    }) ~= true then error("testing-runner: structured-execution: metadata write failed") end
    if ports.complete_replay({
      artifact_root = request.artifact_root,
      claim = claim,
      result_ref = execution_path,
      operation_id = environment.value.operation_id,
      repository = copy(request.repository),
      environment_receipt_sha256 = environment.digest,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    }) ~= true then
      error("testing-runner: structured-execution: replay completion failed")
    end
    return result
  end)
  if not ok then return blocked(tostring(result)) end
  return result
end

function M.result_payload(request, ports)
  local runtime = ports
  if runtime == nil then
    local ok, resolved = pcall(M.production_ports)
    if ok then runtime = resolved end
  end
  local outcome = runtime and M.run(request, runtime) or blocked("host runtime capability is unavailable")
  local artifact_root = safe_pointer(request.artifact_root)
    and request.artifact_root or ".testing/runs/invalid-structured-execution"
  local summary = {
    schema = testing_contract.schemas.structured_execution_summary,
    status = outcome.status,
    classification = outcome.classification,
    mode = "structured-api-cli",
    artifact_root = artifact_root,
    test_plan_path = outcome.test_plan_path or (artifact_root .. "/test-plan.json"),
    execution_path = outcome.execution_path or (artifact_root .. "/execution.json"),
    case_results_path = outcome.case_results_path or (artifact_root .. "/case-results.json"),
    case_count = outcome.case_count or 0,
    passed_count = outcome.passed_count or 0,
    failed_count = outcome.failed_count or 0,
    skipped_count = outcome.skipped_count or 0,
    error_count = outcome.error_count or 0,
    replayed = outcome.replayed == true,
  }
  if outcome.case_result_set_path ~= nil and outcome.case_result_set_artifact_sha256 ~= nil
    and outcome.evidence_manifest_path ~= nil and outcome.evidence_manifest_artifact_sha256 ~= nil then
    summary.case_result_set_path = outcome.case_result_set_path
    summary.case_result_set_artifact_sha256 = outcome.case_result_set_artifact_sha256
    summary.evidence_manifest_path = outcome.evidence_manifest_path
    summary.evidence_manifest_artifact_sha256 = outcome.evidence_manifest_artifact_sha256
  end
  return {
    schema = testing_contract.schemas.runner_result,
    job = "structured-execution",
    status = outcome.status,
    artifact_root = artifact_root,
    source_ref = request.source_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    adapter = { name = "fkst-native", mode = "structured-api-cli" },
    stderr_excerpt = outcome.status == "blocked" and tostring(outcome.message or "structured execution blocked"):sub(1, 600) or nil,
    native_summary = summary,
  }
end

return M
