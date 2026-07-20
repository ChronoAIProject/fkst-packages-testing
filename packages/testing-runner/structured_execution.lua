local M = {}
local testing_contract = require("contract.testing")

local max_cases = 64
local max_argv = 32
local max_assertions = 16

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
  environment_receipt_ref = true,
  environment_receipt_sha256 = true,
  test_plan_ref = true,
  test_plan_sha256 = true,
  execution_approval_ref = true,
  execution_approval_sha256 = true,
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
  if value.schema ~= "testing-runner.structured-execution.request.v1" then
    error("testing-runner: structured-execution: unknown request schema")
  end
  local repository = value.repository
  only_fields(repository, { url = true, commit_sha = true }, "repository")
  if type(repository) ~= "table" or not bounded(repository.url, 512) or repository.url:find("@", 1, true)
    or type(repository.commit_sha) ~= "string" or #repository.commit_sha ~= 40
    or repository.commit_sha:match("^[0-9a-f]+$") == nil then
    error("testing-runner: structured-execution: immutable repository identity is required")
  end
  for _, field in ipairs({ "environment_receipt_ref", "test_plan_ref", "execution_approval_ref", "artifact_root" }) do
    if not safe_pointer(value[field]) then error("testing-runner: structured-execution: unsafe pointer " .. field) end
  end
  for _, field in ipairs({ "environment_receipt_sha256", "test_plan_sha256", "execution_approval_sha256" }) do
    if not sha256(value[field]) then error("testing-runner: structured-execution: invalid digest " .. field) end
  end
  if not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then
    error("testing-runner: structured-execution: bounded trace and dedup identity are required")
  end
  if type(value.source_ref) ~= "table" or not bounded(value.source_ref.kind, 80) or not bounded(value.source_ref.ref, 512) then
    error("testing-runner: structured-execution: source_ref is required")
  end
  return value
end

local function copy_list(value)
  local out = {}
  for _, item in ipairs(value or {}) do table.insert(out, item) end
  return out
end

local function blocked(message)
  return {
    status = "blocked",
    classification = "harness-tooling-issue",
    message = message,
  }
end

local required_ports = {
  "load_artifact", "now", "verify_approval", "replay_guard", "exec_argv", "http_request",
  "write_artifact", "load_result", "complete_replay",
}

function M.production_ports()
  local ports = _G.structured_execution_runtime
  if type(ports) ~= "table" then error("testing-runner: structured-execution: host runtime capability is unavailable") end
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

local function split_http_url(url)
  local origin, path = tostring(url or ""):match("^(https?://[^/]+)(/.*)$")
  if origin == nil then origin = tostring(url or ""):match("^(https?://[^/]+)$") path = "/" end
  if origin == nil or origin:find("@", 1, true) then return nil, nil end
  return origin, path
end

local function contains(list, expected)
  for _, item in ipairs(list or {}) do if item == expected then return true end end
  return false
end

local function http_allowed(request, capabilities)
  local origin, path = split_http_url(request.url)
  if origin == nil then return false end
  for _, capability in ipairs(capabilities or {}) do
    if capability.origin == origin and contains(capability.methods, request.method) then
      for _, prefix in ipairs(capability.path_prefixes or {}) do
        if path:sub(1, #prefix) == prefix then return true end
      end
    end
  end
  return false
end

local function validate_assertion(assertion, kind)
  only_fields(assertion, { type = true, expected = true }, "assertion")
  if kind == "cli" then
    if assertion.type ~= "exit-code" or type(assertion.expected) ~= "number"
      or assertion.expected ~= math.floor(assertion.expected) or assertion.expected < 0 or assertion.expected > 255 then
      error("testing-runner: structured-execution: unsupported cli assertion")
    end
  elseif assertion.type == "status-code" then
    if type(assertion.expected) ~= "number" or assertion.expected ~= math.floor(assertion.expected)
      or assertion.expected < 100 or assertion.expected > 599 then
      error("testing-runner: structured-execution: unsupported http assertion")
    end
  elseif assertion.type ~= "body-contains" or not bounded(assertion.expected, 512) then
    error("testing-runner: structured-execution: unsupported http assertion")
  end
end

local function validate_case(value, seen)
  only_fields(value, {
    case_id = true, kind = true, argv = true, request = true, timeout_seconds = true,
    assertions = true, skip_reason = true, skip_classification = true,
  }, "case")
  if type(value) ~= "table" or not bounded(value.case_id, 180) or seen[value.case_id] then
    error("testing-runner: structured-execution: malformed or duplicate case_id")
  end
  if value.case_id:match("^[%w%._%-]+$") == nil then error("testing-runner: structured-execution: unsafe case_id") end
  if value.skip_reason ~= nil then
    if not bounded(value.skip_reason, 512)
      or (value.skip_classification ~= "data-fixture-gap" and value.skip_classification ~= "not-executed-risk") then
      error("testing-runner: structured-execution: malformed skip reason")
    end
  elseif value.skip_classification ~= nil then
    error("testing-runner: structured-execution: skip classification requires skip_reason")
  end
  seen[value.case_id] = true
  if value.kind ~= "cli" and value.kind ~= "http" then
    error("testing-runner: structured-execution: unsupported case kind")
  end
  if type(value.timeout_seconds) ~= "number" or value.timeout_seconds ~= math.floor(value.timeout_seconds)
    or value.timeout_seconds < 1 or value.timeout_seconds > 300 then
    error("testing-runner: structured-execution: invalid timeout")
  end
  if not dense_list(value.assertions, max_assertions) or #value.assertions == 0 then
    error("testing-runner: structured-execution: assertions must be bounded")
  end
  for _, assertion in ipairs(value.assertions) do validate_assertion(assertion, value.kind) end
  if value.kind == "cli" then
    if not dense_list(value.argv, max_argv) or #value.argv == 0 then
      error("testing-runner: structured-execution: cli argv must be bounded")
    end
    for _, item in ipairs(value.argv) do
      if not bounded(item, 512) then error("testing-runner: structured-execution: invalid argv item") end
    end
    local executable = value.argv[1]:match("([^/\\]+)$")
    if contains({ "sh", "bash", "zsh", "cmd", "powershell", "pwsh" }, executable) then
      error("testing-runner: structured-execution: shell executables are unsupported")
    end
  else
    local request = value.request
    only_fields(request, { method = true, url = true, headers = true }, "http request")
    if type(request) ~= "table" or not contains({ "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE" }, request.method)
      or split_http_url(request.url) == nil or not dense_list(request.headers or {}, 16) then
      error("testing-runner: structured-execution: malformed http request")
    end
    if #(request.headers or {}) ~= 0 then error("testing-runner: structured-execution: inline http headers are unsupported") end
  end
end

local function validate_plan(plan)
  only_fields(plan, { schema = true, repository = true, environment_receipt_sha256 = true, cases = true }, "plan")
  only_fields(plan.repository, { url = true, commit_sha = true }, "plan repository")
  if not dense_list(plan.cases, max_cases) or #plan.cases == 0 then
    error("testing-runner: structured-execution: plan cases must be bounded")
  end
  local seen = {}
  for _, case in ipairs(plan.cases) do validate_case(case, seen) end
end

local function validate_ref(value, label)
  only_fields(value, { kind = true, ref = true }, label)
  if not bounded(value.kind, 80) or not bounded(value.ref, 512) then
    error("testing-runner: structured-execution: malformed " .. label)
  end
end

local function validate_approval(approval, now)
  only_fields(approval, {
    schema = true, approval_id = true, plan_sha256 = true, environment_receipt_sha256 = true,
    repository = true, cli_capabilities = true, http_capabilities = true, authority = true,
    policy_revision = true, evidence_ref = true, issued_at = true, expires_at = true,
    max_uses = true, trace_id = true, dedup_key = true,
  }, "approval")
  if not bounded(approval.approval_id, 180) or not bounded(approval.policy_revision, 180)
    or not bounded(approval.issued_at, 40) or not bounded(approval.expires_at, 40)
    or approval.issued_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") == nil
    or approval.expires_at:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") == nil
    or type(now) ~= "string" or now < approval.issued_at or now >= approval.expires_at then
    error("testing-runner: structured-execution: approval is outside its validity window")
  end
  validate_ref(approval.authority, "authority")
  validate_ref(approval.evidence_ref, "evidence_ref")
  only_fields(approval.repository, { url = true, commit_sha = true }, "approval repository")
  if not dense_list(approval.cli_capabilities, max_cases) or not dense_list(approval.http_capabilities, max_cases) then
    error("testing-runner: structured-execution: capabilities must be bounded")
  end
  for _, capability in ipairs(approval.cli_capabilities) do
    only_fields(capability, { argv_prefix = true }, "cli capability")
    if not dense_list(capability.argv_prefix, max_argv) or #capability.argv_prefix == 0 then
      error("testing-runner: structured-execution: malformed cli capability")
    end
    for _, item in ipairs(capability.argv_prefix) do
      if not bounded(item, 512) then error("testing-runner: structured-execution: malformed cli capability item") end
    end
  end
  for _, capability in ipairs(approval.http_capabilities) do
    only_fields(capability, { origin = true, methods = true, path_prefixes = true }, "http capability")
    if not bounded(capability.origin, 512) or capability.origin:match("^https?://[^/]+$") == nil
      or not dense_list(capability.methods, 8) or #capability.methods == 0
      or not dense_list(capability.path_prefixes, 16) or #capability.path_prefixes == 0 then
      error("testing-runner: structured-execution: malformed http capability")
    end
    for _, method in ipairs(capability.methods) do
      if not contains({ "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE" }, method) then
        error("testing-runner: structured-execution: unsupported http capability method")
      end
    end
    for _, prefix in ipairs(capability.path_prefixes) do
      if not bounded(prefix, 512) or prefix:sub(1, 1) ~= "/" then
        error("testing-runner: structured-execution: malformed http path capability")
      end
    end
  end
end

local function attestation_matches(attestation, approval, digest)
  return type(attestation) == "table"
    and attestation.approval_sha256 == digest
    and attestation.policy_revision == approval.policy_revision
    and type(attestation.authority) == "table"
    and attestation.authority.kind == approval.authority.kind
    and attestation.authority.ref == approval.authority.ref
    and type(attestation.evidence_ref) == "table"
    and attestation.evidence_ref.kind == approval.evidence_ref.kind
    and attestation.evidence_ref.ref == approval.evidence_ref.ref
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

local function execute_case(case, approval, ports)
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
  local ok, response
  if case.kind == "cli" then
    if not argv_allowed(case.argv, approval.cli_capabilities) then
      error("testing-runner: structured-execution: unauthorized cli capability")
    end
    ok, response = pcall(ports.exec_argv, copy_list(case.argv), case.timeout_seconds)
  else
    if not http_allowed(case.request, approval.http_capabilities) then
      error("testing-runner: structured-execution: unauthorized http capability")
    end
    ok, response = pcall(ports.http_request, case.request, case.timeout_seconds)
  end
  local case_result = not ok and effect_error(case, response) or nil
  if case_result == nil then
    if type(response) ~= "table" then
      case_result = { case_id = case.case_id, kind = case.kind, status = "error", classification = "environment-session-issue" }
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

function M.run(request, ports)
  local ok, result = pcall(function()
    M.validate_request(request)
    local environment = load_bound(ports, request.environment_receipt_ref, request.environment_receipt_sha256, "environment receipt")
    local plan = load_bound(ports, request.test_plan_ref, request.test_plan_sha256, "test plan")
    local approval = load_bound(ports, request.execution_approval_ref, request.execution_approval_sha256, "execution approval")

    if environment.value.schema ~= "environment-factory.environment-result.v1"
      or environment.value.status ~= "ready"
      or not same_repository(environment.value.repository, request.repository)
      or environment.value.trace_id ~= request.trace_id
      or environment.value.dedup_key ~= request.dedup_key then
      return blocked("environment receipt does not belong to this run")
    end
    if plan.value.schema ~= "testing-structured-plan.v1"
      or not same_repository(plan.value.repository, request.repository)
      or plan.value.environment_receipt_sha256 ~= request.environment_receipt_sha256 then
      return blocked("test plan does not belong to this environment")
    end
    if approval.value.schema ~= "testing-structured-execution-approval.v1"
      or approval.value.plan_sha256 ~= request.test_plan_sha256
      or approval.value.environment_receipt_sha256 ~= request.environment_receipt_sha256
      or not same_repository(approval.value.repository, request.repository)
      or approval.value.trace_id ~= request.trace_id
      or approval.value.dedup_key ~= request.dedup_key then
      return blocked("execution approval does not belong to this plan")
    end

    validate_plan(plan.value)

    local now = ports.now()
    validate_approval(approval.value, now)
    local verified = ports.verify_approval({
      approval = approval.value,
      approval_raw = approval.raw,
      approval_sha256 = approval.digest,
      now = now,
    })
    if not attestation_matches(verified, approval.value, approval.digest) then
      return blocked("execution approval authentication failed")
    end
    if approval.value.max_uses ~= 1 then return blocked("execution approval must be single use") end
    local claim = ports.replay_guard({
      approval_id = approval.value.approval_id,
      approval_sha256 = approval.digest,
      plan_sha256 = plan.digest,
      environment_receipt_sha256 = environment.digest,
      repository = request.repository,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    })
    if type(claim) ~= "table" then return blocked("replay guard rejected execution") end
    if claim.status == "completed" then
      local replayed = ports.load_result(claim.result_ref)
      if type(replayed) ~= "table" then return blocked("completed replay result is unavailable") end
      replayed.replayed = true
      return replayed
    end
    if claim.status ~= "claimed" or not bounded(claim.claim_id, 180) then
      return blocked("replay guard did not claim execution")
    end

    local case_results = {}
    for _, case in ipairs(plan.value.cases) do
      local case_result = execute_case(case, approval.value, ports)
      local evidence_path = request.artifact_root .. "/evidence/" .. case.case_id .. ".json"
      if ports.write_artifact(evidence_path, case_result.evidence) ~= true then
        error("testing-runner: structured-execution: evidence write failed")
      end
      case_result.evidence = nil
      case_result.evidence_ref = evidence_path
      table.insert(case_results, case_result)
    end
    local status, classification, counts = aggregate(case_results)
    local case_results_path = request.artifact_root .. "/case-results.json"
    local execution_path = request.artifact_root .. "/execution.json"
    local test_plan_path = request.artifact_root .. "/test-plan.json"
    if ports.write_artifact(test_plan_path, plan.value) ~= true then error("testing-runner: structured-execution: plan write failed") end
    if ports.write_artifact(case_results_path, {
      schema = "testing-structured-case-results.v1",
      plan_sha256 = plan.digest,
      cases = case_results,
    }) ~= true then error("testing-runner: structured-execution: case results write failed") end
    local execution = {
      schema = "testing-structured-execution.v1",
      status = status,
      classification = classification,
      repository = request.repository,
      environment_receipt_sha256 = environment.digest,
      plan_sha256 = plan.digest,
      approval_sha256 = approval.digest,
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
      case_count = #case_results,
      passed_count = counts.passed,
      failed_count = counts.failed,
      skipped_count = counts.skipped,
      error_count = counts.error,
      test_plan_path = test_plan_path,
      case_results_path = case_results_path,
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
    if ports.complete_replay(claim, execution_path) ~= true then
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
  local summary = {
    schema = testing_contract.schemas.structured_execution_summary,
    status = outcome.status,
    classification = outcome.classification,
    mode = "structured-api-cli",
    artifact_root = request.artifact_root,
    test_plan_path = outcome.test_plan_path or (request.artifact_root .. "/test-plan.json"),
    execution_path = outcome.execution_path or (request.artifact_root .. "/execution.json"),
    case_results_path = outcome.case_results_path or (request.artifact_root .. "/case-results.json"),
    case_count = outcome.case_count or 0,
    passed_count = outcome.passed_count or 0,
    failed_count = outcome.failed_count or 0,
    skipped_count = outcome.skipped_count or 0,
    error_count = outcome.error_count or 0,
    replayed = outcome.replayed == true,
  }
  return {
    schema = testing_contract.schemas.runner_result,
    job = "structured-execution",
    status = outcome.status,
    artifact_root = request.artifact_root,
    source_ref = request.source_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    adapter = { name = "fkst-native", mode = "structured-api-cli" },
    stderr_excerpt = outcome.status == "blocked" and tostring(outcome.message or "structured execution blocked"):sub(1, 600) or nil,
    native_summary = summary,
  }
end

return M
