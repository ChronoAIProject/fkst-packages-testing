-- contract.environment_factory: pointer-only Environment Factory v1 contracts.
local error_facts = require("contract.error_facts")
local project_profile = require("contract.project_profile")
local source_ref = require("contract.source_ref")
local strings = require("contract.strings")

local E = {}

E.schemas = {
  start = "environment-factory.start.v1",
  finalize = "environment-factory.finalize.v1",
  interrupt = "environment-factory.interrupt.v1",
  result = "environment-factory.result.v1",
  receipt = "environment-factory.receipt.v2",
  cleanup_receipt = "environment-factory.cleanup-receipt.v1",
  state = "environment-factory.operation-state.v1",
  start_binding = "environment-factory.start-binding.v1",
  readiness_correlation = "environment-factory.browser-readiness-correlation.v1",
}

E.max_diagnostic_refs = 32

local max_id = 180
local max_string = 1024
local max_ports = 32
local max_sessions = 16
local max_resources = 64

local function fail(classification, message)
  error(error_facts.error_message("contract.environment-factory", classification, message))
end

local function bounded(value, limit)
  return strings.is_bounded_string(value, limit or max_string)
    and value:find("[%z\1-\31\127]") == nil
end

local function require_bounded(value, field, limit)
  if not bounded(value, limit) then fail("malformed-field", field .. " must be a bounded string") end
  return value
end

local function require_id(value, field)
  require_bounded(value, field, max_id)
  if value:find("%s") ~= nil then fail("malformed-field", field .. " must not contain whitespace") end
  return value
end

local function require_digest(value, field)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    fail("malformed-field", field .. " must be a lowercase SHA-256 digest")
  end
  return value
end

local function require_integer(value, field, minimum, maximum)
  if type(value) ~= "number" or value ~= math.floor(value) or value < minimum or value > maximum then
    fail("malformed-field", field .. " must be an integer from " .. minimum .. " to " .. maximum)
  end
  return value
end

local function dense_list(value, maximum, non_empty)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    if key > highest then highest = key end
  end
  return count == highest and count <= maximum and (not non_empty or count > 0)
end

local function only_fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, context .. " must be a table") end
  for key, _ in pairs(value) do
    if type(key) ~= "string" or allowed[key] ~= true then
      fail("malformed-" .. context, "unsupported field " .. tostring(key))
    end
  end
end

local function copy_ref(value)
  return { kind = value.kind, ref = value.ref }
end

local function contains_credential(value)
  local text = tostring(value or ""):lower()
  return text:match("^[a-z][a-z0-9+.-]*://[^/?#]*@") ~= nil
    or text:find("password=", 1, true) ~= nil
    or text:find("token=", 1, true) ~= nil
    or text:find("secret=", 1, true) ~= nil
    or text:find("authorization:", 1, true) ~= nil
    or text:find("bearer ", 1, true) ~= nil
end

local function validate_ref(value, field)
  only_fields(value, { kind = true, ref = true }, "pointer")
  if not source_ref.has_bounded_source_ref(value, 2048) then
    fail("malformed-pointer", field .. " must be a bounded source_ref")
  end
  if value.kind:find("%s") ~= nil or contains_credential(value.kind) or contains_credential(value.ref) then
    fail("credential-pointer", field .. " must not contain credential material")
  end
  return value
end

local function validate_artifact_ref(value, field)
  validate_ref(value, field)
  if value.kind ~= "artifact" then fail("malformed-pointer", field .. " must use kind=artifact") end
  if not strings.is_path_safe_key(value.ref, 4096) or value.ref:sub(1, 9) ~= ".testing/" then
    fail("malformed-pointer", field .. " must be a safe .testing artifact path")
  end
  return value
end

local function validate_repository(value)
  only_fields(value, { url = true, commit_sha = true }, "repository")
  require_bounded(value.url, "repository.url", 2048)
  if value.url:match("^https://[^/@]+/[^?#]+$") == nil or value.url:find("@", 1, true) ~= nil then
    fail("malformed-repository", "repository.url must be a credential-free HTTPS Git URL")
  end
  if type(value.commit_sha) ~= "string" or #value.commit_sha ~= 40
    or value.commit_sha:match("^[0-9a-f]+$") == nil then
    fail("mutable-revision", "repository.commit_sha must be an exact lowercase 40-hex commit")
  end
  return value
end

local function same_repository(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.url == right.url and left.commit_sha == right.commit_sha
end
E.same_repository = same_repository

local function loopback_host(host)
  local value = tostring(host or ""):lower()
  return value == "localhost" or value == "127.0.0.1" or value == "::1"
end

local function url_parts(value, field)
  require_bounded(value, field, 2048)
  local scheme, authority, suffix = value:match("^(https?)://([^/%?#]+)([^%?#]*)$")
  if scheme == nil then fail("malformed-url", field .. " must be an HTTP(S) URL without query or fragment") end
  local host, port
  if authority:sub(1, 1) == "[" then
    host, port = authority:match("^%[([^%]]+)%]:(%d+)$")
  else
    host, port = authority:match("^([^:]+):(%d+)$")
  end
  if not loopback_host(host) then fail("non-loopback", field .. " must use an explicit loopback host") end
  require_integer(tonumber(port), field .. " port", 1, 65535)
  if suffix ~= "" and suffix:sub(1, 1) ~= "/" then fail("malformed-url", field .. " has an invalid path") end
  return scheme, host:lower(), tonumber(port), suffix
end

local function port_set_from_list(value)
  if not dense_list(value, max_ports, true) then
    fail("malformed-ports", "runtime_ports must be a non-empty bounded dense list")
  end
  local set, names = {}, {}
  for index, item in ipairs(value) do
    only_fields(item, { name = true, port = true }, "runtime-port")
    require_id(item.name, "runtime_ports[" .. index .. "].name")
    require_integer(item.port, "runtime_ports[" .. index .. "].port", 1, 65535)
    if set[item.port] ~= nil then fail("duplicate-port", tostring(item.port)) end
    if names[item.name] then fail("duplicate-port-name", item.name) end
    set[item.port] = item.name
    names[item.name] = true
  end
  return set
end

local function add_profile_port(set, port, field)
  if set[port] == nil then set[port] = field end
end

local function collect_checks(set, checks, field)
  for index, check in ipairs(checks or {}) do
    if check.type == "http" then
      local _, _, port = url_parts(check.url, field .. "[" .. index .. "].url")
      add_profile_port(set, port, field)
    elseif check.type == "tcp" then
      if not loopback_host(check.host) then fail("non-loopback", field .. " tcp host must be loopback") end
      add_profile_port(set, check.port, field)
    end
  end
end

function E.profile_port_set(profile)
  project_profile.validate_profile(profile)
  local set = {}
  for index, origin in ipairs(profile.allowed_origins or {}) do
    local _, _, port = url_parts(origin, "allowed_origins[" .. index .. "]")
    add_profile_port(set, port, "allowed_origins")
  end
  collect_checks(set, profile.readiness_checks, "readiness_checks")
  for index, service in ipairs(profile.dependent_services or {}) do
    collect_checks(set, service.readiness_checks, "dependent_services[" .. index .. "].readiness_checks")
  end
  return set
end

function E.require_exact_runtime_ports(profile, runtime_ports)
  local approved = E.profile_port_set(profile)
  local requested = port_set_from_list(runtime_ports)
  for port, _ in pairs(approved) do
    if requested[port] == nil then fail("missing-runtime-port", tostring(port)) end
  end
  for port, _ in pairs(requested) do
    if approved[port] == nil then fail("unapproved-runtime-port", tostring(port)) end
  end
  return runtime_ports
end

local function check_ports(checks, field)
  local ports = {}
  for index, check in ipairs(checks or {}) do
    if check.type == "http" then
      local _, _, port = url_parts(check.url, field .. "[" .. index .. "].url")
      ports[port] = true
    elseif check.type == "tcp" then
      if not loopback_host(check.host) then fail("non-loopback", field .. " tcp host must be loopback") end
      ports[check.port] = true
    end
  end
  return ports
end

function E.supervised_port_assignments(profile, runtime_ports)
  project_profile.validate_profile(profile)
  E.require_exact_runtime_ports(profile, runtime_ports)
  local requested = {}
  for _, item in ipairs(runtime_ports) do requested[item.port] = { name = item.name, port = item.port } end
  local owners = {}
  local assignments = { application = {}, services = {} }

  local function assign(owner, ports, output)
    for port, _ in pairs(ports) do
      if owners[port] ~= nil and owners[port] ~= owner then
        fail("ambiguous-runtime-port", tostring(port) .. " is owned by both " .. owners[port] .. " and " .. owner)
      end
      owners[port] = owner
      if requested[port] ~= nil then table.insert(output, requested[port]) end
    end
    table.sort(output, function(left, right) return left.port < right.port end)
  end

  local application_ports = check_ports(profile.readiness_checks, "readiness_checks")
  for index, origin in ipairs(profile.allowed_origins or {}) do
    local _, _, port = url_parts(origin, "allowed_origins[" .. index .. "]")
    application_ports[port] = true
  end
  assign("application", application_ports, assignments.application)
  for index, service in ipairs(profile.dependent_services or {}) do
    assignments.services[index] = {}
    assign("service-" .. index, check_ports(service.readiness_checks,
      "dependent_services[" .. index .. "].readiness_checks"), assignments.services[index])
  end
  for port, _ in pairs(requested) do
    if owners[port] == nil then fail("unowned-runtime-port", tostring(port)) end
  end
  return assignments
end

local function validate_sessions(value)
  if not dense_list(value, max_sessions, true) then
    fail("malformed-sessions", "sessions must be a non-empty bounded dense list")
  end
  for index, session in ipairs(value) do
    only_fields(session, {
      role = true,
      browser_harness_command = true,
      browser_harness_command_env = true,
      cdp_endpoint_env = true,
      cdp_url = true,
    }, "session")
    require_id(session.role, "sessions[" .. index .. "].role")
    local has_source = false
    if session.browser_harness_command ~= nil then
      require_bounded(session.browser_harness_command, "sessions[" .. index .. "].browser_harness_command", 256)
      if contains_credential(session.browser_harness_command) then fail("credential-session", "browser harness command is unsafe") end
      has_source = true
    end
    for _, field in ipairs({ "browser_harness_command_env", "cdp_endpoint_env" }) do
      if session[field] ~= nil then
        require_bounded(session[field], "sessions[" .. index .. "]." .. field, 128)
        if session[field]:match("^[A-Za-z_][A-Za-z0-9_]*$") == nil then
          fail("malformed-sessions", field .. " must be an environment identifier")
        end
        has_source = true
      end
    end
    if session.cdp_url ~= nil then
      url_parts(session.cdp_url, "sessions[" .. index .. "].cdp_url")
      if contains_credential(session.cdp_url) then fail("credential-session", "cdp_url is unsafe") end
      has_source = true
    end
    if not has_source then fail("malformed-sessions", "session must use a supported browser readiness source") end
  end
  return value
end

local start_fields = {
  schema = true,
  operation_id = true,
  repository = true,
  profile_ref = true,
  approval_ref = true,
  validation_receipt_ref = true,
  operation_state_ref = true,
  artifact_root = true,
  base_url = true,
  runtime_ports = true,
  sessions = true,
  trace_id = true,
  dedup_key = true,
}

function E.validate_start(value)
  only_fields(value, start_fields, "start-request")
  if value.schema ~= E.schemas.start then fail("unknown-schema", "expected " .. E.schemas.start) end
  require_id(value.operation_id, "operation_id")
  validate_repository(value.repository)
  validate_ref(value.profile_ref, "profile_ref")
  validate_ref(value.approval_ref, "approval_ref")
  validate_artifact_ref(value.validation_receipt_ref, "validation_receipt_ref")
  validate_artifact_ref(value.operation_state_ref, "operation_state_ref")
  if not strings.is_artifact_root(value.artifact_root) then
    fail("malformed-artifact-root", "artifact_root must be a safe .testing/runs/... path")
  end
  if value.operation_state_ref.ref ~= value.artifact_root .. "/operation-state.json" then
    fail("malformed-pointer", "operation_state_ref must point to operation-state.json under artifact_root")
  end
  url_parts(value.base_url, "base_url")
  port_set_from_list(value.runtime_ports)
  validate_sessions(value.sessions)
  require_id(value.trace_id, "trace_id")
  require_id(value.dedup_key, "dedup_key")
  return value
end

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[deep_copy(key)] = deep_copy(item) end
  return out
end

local function same_value(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, value in pairs(left) do
    if not same_value(value, right[key]) then return false end
  end
  for key, _ in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
end

function E.start_binding(value)
  E.validate_start(value)
  return { schema = E.schemas.start_binding, request = deep_copy(value) }
end

function E.same_start_binding(left, right)
  return same_value(left, right)
end

function E.validate_readiness_correlation(value)
  only_fields(value, {
    schema = true,
    attempt_id = true,
    operation_id = true,
    operation_state_ref = true,
    readiness_attempt_ref = true,
    readiness_attempt_sha256 = true,
    target_id = true,
    target_sha256 = true,
    base_url = true,
    sessions = true,
    trace_id = true,
    dedup_key = true,
  }, "readiness-correlation")
  if value.schema ~= E.schemas.readiness_correlation then
    fail("unknown-schema", "expected " .. E.schemas.readiness_correlation)
  end
  require_id(value.attempt_id, "attempt_id")
  require_id(value.operation_id, "operation_id")
  validate_artifact_ref(value.operation_state_ref, "operation_state_ref")
  validate_artifact_ref(value.readiness_attempt_ref, "readiness_attempt_ref")
  require_digest(value.readiness_attempt_sha256, "readiness_attempt_sha256")
  local has_target_binding = value.target_id ~= nil or value.target_sha256 ~= nil
  if has_target_binding then
    require_id(value.target_id, "target_id")
    require_digest(value.target_sha256, "target_sha256")
  end
  url_parts(value.base_url, "base_url")
  validate_sessions(value.sessions)
  require_id(value.trace_id, "trace_id")
  require_id(value.dedup_key, "dedup_key")
  return value
end

local function validate_browser_checks(value, field)
  if not dense_list(value, 8, true) then fail("malformed-browser-result", field .. " must be a non-empty dense list") end
  for index, item in ipairs(value) do
    only_fields(item, { name = true, status = true, reason = true }, "browser-check")
    require_id(item.name, field .. "[" .. index .. "].name")
    if item.status ~= "ready" and item.status ~= "blocked" then
      fail("malformed-browser-result", field .. " status is invalid")
    end
    if item.reason ~= nil then
      require_bounded(item.reason, field .. "[" .. index .. "].reason", 256)
      if contains_credential(item.reason) then fail("credential-browser-result", field .. " reason is unsafe") end
    end
  end
end

function E.sanitize_browser_readiness_result(value)
  only_fields(value, {
    schema = true,
    status = true,
    sessions = true,
    source_ref = true,
    request_context = true,
    correlation = true,
  }, "browser-result")
  if value.schema ~= "browser-readiness.result.v1" then
    fail("unknown-schema", "expected browser-readiness.result.v1")
  end
  if value.status ~= "ready" and value.status ~= "blocked" then
    fail("malformed-browser-result", "status must be ready or blocked")
  end
  validate_artifact_ref(value.source_ref, "browser-result.source_ref")
  only_fields(value.request_context, { dry_run = true }, "browser-request-context")
  if value.request_context.dry_run ~= false then
    fail("malformed-browser-result", "request_context.dry_run must be false")
  end
  E.validate_readiness_correlation(value.correlation)
  if not dense_list(value.sessions, max_sessions + 1, true) then
    fail("malformed-browser-result", "sessions must be a bounded dense list")
  end
  for index, session in ipairs(value.sessions) do
    only_fields(session, { role = true, status = true, checks = true, cdp_url = true }, "browser-session-result")
    require_id(session.role, "sessions[" .. index .. "].role")
    if session.status ~= "ready" and session.status ~= "blocked" then
      fail("malformed-browser-result", "session status is invalid")
    end
    validate_browser_checks(session.checks, "sessions[" .. index .. "].checks")
    if session.cdp_url ~= nil then
      url_parts(session.cdp_url, "sessions[" .. index .. "].cdp_url")
      if contains_credential(session.cdp_url) then fail("credential-browser-result", "cdp_url is unsafe") end
    end
    if value.status == "ready" then
      if session.status ~= "ready" then
        fail("malformed-browser-result", "ready aggregate contains a blocked session")
      end
      for _, item in ipairs(session.checks) do
        if item.status ~= "ready" then
          fail("malformed-browser-result", "ready aggregate contains a blocked check")
        end
      end
    end
  end
  return deep_copy(value)
end

function E.same_value(left, right)
  return same_value(left, right)
end

function E.validate_profile_binding(request, profile)
  E.validate_start(request)
  project_profile.validate_profile(profile)
  if not same_repository(request.repository, profile.repository) then
    fail("source-mismatch", "request repository does not match the approved profile")
  end
  E.require_exact_runtime_ports(profile, request.runtime_ports)
  local found_base = false
  for _, check in ipairs(profile.readiness_checks or {}) do
    if check.type == "http" and check.url == request.base_url then found_base = true end
  end
  if not found_base then fail("unapproved-base-url", "base_url must be an exact application readiness URL") end
  return profile
end

local finalize_fields = {
  schema = true,
  operation_id = true,
  cleanup_ref = true,
  operation_state_ref = true,
  trace_id = true,
  dedup_key = true,
}

function E.validate_finalize(value)
  only_fields(value, finalize_fields, "finalize-request")
  if value.schema ~= E.schemas.finalize then fail("unknown-schema", "expected " .. E.schemas.finalize) end
  require_id(value.operation_id, "operation_id")
  validate_ref(value.cleanup_ref, "cleanup_ref")
  validate_artifact_ref(value.operation_state_ref, "operation_state_ref")
  require_id(value.trace_id, "trace_id")
  require_id(value.dedup_key, "dedup_key")
  return value
end

local interrupt_fields = {
  schema = true,
  operation_id = true,
  cleanup_ref = true,
  operation_state_ref = true,
  interruption = true,
  trace_id = true,
  dedup_key = true,
}

function E.validate_interrupt(value)
  only_fields(value, interrupt_fields, "interrupt-request")
  if value.schema ~= E.schemas.interrupt then fail("unknown-schema", "expected " .. E.schemas.interrupt) end
  require_id(value.operation_id, "operation_id")
  validate_ref(value.cleanup_ref, "cleanup_ref")
  validate_artifact_ref(value.operation_state_ref, "operation_state_ref")
  if value.interruption ~= "cancelled" and value.interruption ~= "interrupted" then
    fail("malformed-interruption", "interruption must be cancelled or interrupted")
  end
  require_id(value.trace_id, "trace_id")
  require_id(value.dedup_key, "dedup_key")
  return value
end

local result_statuses = {
  ready = true,
  blocked = true,
  finalized = true,
  cancelled = true,
  interrupted = true,
}
local result_fields = {
  schema = true,
  operation_id = true,
  status = true,
  failure_class = true,
  environment_receipt_ref = true,
  cleanup_receipt_ref = true,
  cleanup_ref = true,
  diagnostic_refs = true,
  cleanup_status = true,
  source_ref = true,
  trace_id = true,
  dedup_key = true,
}

local cleanup_receipt_fields = {
  schema = true,
  operation_id = true,
  status = true,
  attempted_resources = true,
  verified_removals = true,
  remaining_resources = true,
  artifact_root = true,
  trace_id = true,
  dedup_key = true,
}

local receipt_fields = {
  schema = true,
  operation_id = true,
  status = true,
  failure_class = true,
  profile_revision = true,
  profile_sha256 = true,
  repository = true,
  workspace_ref = true,
  base_url = true,
  runtime_ports = true,
  sessions = true,
  browser_readiness = true,
  artifact_root = true,
  diagnostic_refs = true,
  cleanup_ref = true,
  cleanup_receipt_ref = true,
  cleanup_status = true,
  trace_id = true,
  dedup_key = true,
}

function E.validate_cleanup_receipt(value)
  only_fields(value, cleanup_receipt_fields, "cleanup-receipt")
  if value.schema ~= E.schemas.cleanup_receipt then
    fail("unknown-schema", "expected " .. E.schemas.cleanup_receipt)
  end
  require_id(value.operation_id, "operation_id")
  if value.status ~= "complete" and value.status ~= "incomplete" then
    fail("malformed-cleanup-status", tostring(value.status))
  end
  if not dense_list(value.attempted_resources, max_resources, true) then
    fail("malformed-cleanup-receipt", "attempted_resources must be a non-empty bounded dense list")
  end
  local attempted = {}
  local cleaned = {}
  for index, resource in ipairs(value.attempted_resources) do
    only_fields(resource, {
      resource_id = true,
      resource_kind = true,
      status = true,
      diagnostic_ref = true,
    }, "cleanup-attempt")
    local resource_id = require_id(resource.resource_id, "attempted_resources[" .. index .. "].resource_id")
    if attempted[resource_id] then fail("duplicate-resource", resource_id) end
    attempted[resource_id] = true
    require_id(resource.resource_kind, "attempted_resources[" .. index .. "].resource_kind")
    if resource.status ~= "cleaned" and resource.status ~= "remaining" then
      fail("malformed-cleanup-status", tostring(resource.status))
    end
    if resource.status == "cleaned" then cleaned[resource_id] = true end
    if resource.diagnostic_ref ~= nil then
      validate_artifact_ref(resource.diagnostic_ref, "attempted_resources[" .. index .. "].diagnostic_ref")
    end
  end
  if not dense_list(value.verified_removals, max_resources, false) then
    fail("malformed-cleanup-receipt", "verified_removals must be a bounded dense list")
  end
  local verified = {}
  for index, resource_id in ipairs(value.verified_removals) do
    require_id(resource_id, "verified_removals[" .. index .. "]")
    if verified[resource_id] or cleaned[resource_id] ~= true then
      fail("invalid-verified-removal", resource_id)
    end
    verified[resource_id] = true
  end
  if not dense_list(value.remaining_resources, max_resources, false) then
    fail("malformed-cleanup-receipt", "remaining_resources must be a bounded dense list")
  end
  local remaining = {}
  for index, resource in ipairs(value.remaining_resources) do
    only_fields(resource, {
      resource_id = true,
      resource_kind = true,
      cleanup_ref = true,
    }, "remaining-resource")
    local resource_id = require_id(resource.resource_id, "remaining_resources[" .. index .. "].resource_id")
    if remaining[resource_id] or attempted[resource_id] ~= true or cleaned[resource_id] == true then
      fail("invalid-remaining-resource", resource_id)
    end
    remaining[resource_id] = true
    require_id(resource.resource_kind, "remaining_resources[" .. index .. "].resource_kind")
    validate_ref(resource.cleanup_ref, "remaining_resources[" .. index .. "].cleanup_ref")
  end
  for resource_id, _ in pairs(attempted) do
    if cleaned[resource_id] == true then
      if verified[resource_id] ~= true then fail("missing-verified-removal", resource_id) end
    elseif remaining[resource_id] ~= true then
      fail("missing-remaining-resource", resource_id)
    end
  end
  if value.status == "complete" and next(remaining) ~= nil then
    fail("cleanup-status-mismatch", "complete receipt has remaining resources")
  end
  if value.status == "incomplete" and next(remaining) == nil then
    fail("cleanup-status-mismatch", "incomplete receipt has no remaining resources")
  end
  if not strings.is_artifact_root(value.artifact_root) then
    fail("malformed-artifact-root", "artifact_root must be a safe .testing/runs/... path")
  end
  require_id(value.trace_id, "trace_id")
  require_id(value.dedup_key, "dedup_key")
  return value
end

function E.validate_receipt(value)
  only_fields(value, receipt_fields, "receipt")
  if value.schema ~= E.schemas.receipt then fail("unknown-schema", "expected " .. E.schemas.receipt) end
  require_id(value.operation_id, "operation_id")
  if result_statuses[value.status] ~= true then fail("malformed-status", tostring(value.status)) end
  if value.failure_class ~= nil then require_id(value.failure_class, "failure_class") end
  require_bounded(value.profile_revision, "profile_revision", max_id)
  if type(value.profile_sha256) ~= "string" or #value.profile_sha256 ~= 64
    or value.profile_sha256:match("^[0-9a-f]+$") == nil then
    fail("malformed-profile-digest", "profile_sha256 must be exact lowercase 64-hex")
  end
  validate_repository(value.repository)
  if value.workspace_ref ~= nil then validate_ref(value.workspace_ref, "workspace_ref") end
  url_parts(value.base_url, "base_url")
  port_set_from_list(value.runtime_ports)
  validate_sessions(value.sessions)
  if value.browser_readiness ~= nil then
    local readiness = E.sanitize_browser_readiness_result(value.browser_readiness)
    if readiness.correlation.operation_id ~= value.operation_id
      or readiness.correlation.base_url ~= value.base_url
      or readiness.correlation.trace_id ~= value.trace_id
      or readiness.correlation.dedup_key ~= value.dedup_key
      or readiness.source_ref.kind ~= readiness.correlation.operation_state_ref.kind
      or readiness.source_ref.ref ~= readiness.correlation.operation_state_ref.ref then
      fail("browser-readiness-mismatch", "browser readiness proof differs from receipt identity")
    end
  end
  if value.status == "ready" then
    if type(value.workspace_ref) ~= "table" or value.workspace_ref.kind ~= "workspace" then
      fail("missing-workspace-ref", "ready receipt requires an owned workspace_ref")
    end
    if value.browser_readiness == nil or value.browser_readiness.status ~= "ready" then
      fail("missing-browser-readiness", "ready receipt requires a successful browser readiness proof")
    end
    if value.failure_class ~= nil then fail("ready-failure-class", "ready receipt must not have failure_class") end
  end
  if not strings.is_artifact_root(value.artifact_root) then
    fail("malformed-artifact-root", "artifact_root must be a safe .testing/runs/... path")
  end
  if not dense_list(value.diagnostic_refs or {}, E.max_diagnostic_refs, false) then
    fail("malformed-diagnostics", "diagnostic_refs must be a bounded dense list")
  end
  for index, ref in ipairs(value.diagnostic_refs or {}) do
    validate_artifact_ref(ref, "diagnostic_refs[" .. index .. "]")
  end
  validate_ref(value.cleanup_ref, "cleanup_ref")
  if value.cleanup_status ~= "pending" and value.cleanup_status ~= "complete"
    and value.cleanup_status ~= "incomplete" then
    fail("malformed-cleanup-status", tostring(value.cleanup_status))
  end
  if value.status == "ready" then
    if value.cleanup_status ~= "pending" or value.cleanup_receipt_ref ~= nil then
      fail("premature-cleanup-receipt", "ready receipt must retain pending cleanup without a cleanup receipt")
    end
  else
    validate_artifact_ref(value.cleanup_receipt_ref, "cleanup_receipt_ref")
    local cleanup_suffix = "/cleanup-receipt-" .. value.cleanup_status .. ".json"
    if value.cleanup_receipt_ref.ref:sub(-#cleanup_suffix) ~= cleanup_suffix then
      fail("mutable-cleanup-receipt-pointer", "cleanup receipt pointer must match cleanup status")
    end
  end
  require_id(value.trace_id, "trace_id")
  require_id(value.dedup_key, "dedup_key")
  return value
end

function E.validate_result(value)
  only_fields(value, result_fields, "result")
  if value.schema ~= E.schemas.result then fail("unknown-schema", "expected " .. E.schemas.result) end
  require_id(value.operation_id, "operation_id")
  if result_statuses[value.status] ~= true then fail("malformed-status", tostring(value.status)) end
  if value.failure_class ~= nil then require_id(value.failure_class, "failure_class") end
  validate_artifact_ref(value.source_ref, "source_ref")
  validate_artifact_ref(value.environment_receipt_ref, "environment_receipt_ref")
  local suffix = "/environment-receipt-" .. value.status .. ".json"
  if value.environment_receipt_ref.ref:sub(-#suffix) ~= suffix then
    fail("mutable-receipt-pointer", "environment receipt pointer must be immutable for status " .. value.status)
  end
  validate_ref(value.cleanup_ref, "cleanup_ref")
  if not dense_list(value.diagnostic_refs or {}, E.max_diagnostic_refs, false) then
    fail("malformed-diagnostics", "diagnostic_refs must be a bounded dense list")
  end
  for index, ref in ipairs(value.diagnostic_refs or {}) do
    validate_artifact_ref(ref, "diagnostic_refs[" .. index .. "]")
  end
  if value.cleanup_status ~= nil and value.cleanup_status ~= "pending"
    and value.cleanup_status ~= "complete" and value.cleanup_status ~= "incomplete" then
    fail("malformed-cleanup-status", tostring(value.cleanup_status))
  end
  if value.status == "ready" then
    if value.cleanup_receipt_ref ~= nil then
      fail("premature-cleanup-receipt", "ready result must not include cleanup_receipt_ref")
    end
  else
    validate_artifact_ref(value.cleanup_receipt_ref, "cleanup_receipt_ref")
    local cleanup_suffix = "/cleanup-receipt-" .. value.cleanup_status .. ".json"
    if value.cleanup_receipt_ref.ref:sub(-#cleanup_suffix) ~= cleanup_suffix then
      fail("mutable-cleanup-receipt-pointer", "cleanup receipt pointer must match cleanup status")
    end
  end
  require_id(value.trace_id, "trace_id")
  require_id(value.dedup_key, "dedup_key")
  return value
end

local forbidden_runtime_fields = {
  command = true,
  commands = true,
  argv = true,
  pid = true,
  process_id = true,
  env = true,
  environment = true,
  stdout = true,
  stderr = true,
  cookie = true,
  cookies = true,
  storage = true,
  secret = true,
  secret_ref = true,
  secret_value = true,
}

function E.validate_runtime_outcome(value, context)
  if type(value) ~= "table" then fail("malformed-runtime-outcome", context .. " must return a table") end
  for key, _ in pairs(value) do
    if forbidden_runtime_fields[key] then fail("unsafe-runtime-outcome", context .. " returned forbidden field " .. key) end
  end
  if value.status ~= "passed" and value.status ~= "running" and value.status ~= "ready"
    and value.status ~= "cleaned" and value.status ~= "blocked" then
    fail("malformed-runtime-outcome", context .. " returned invalid status")
  end
  if value.diagnostic_ref ~= nil then validate_artifact_ref(value.diagnostic_ref, context .. ".diagnostic_ref") end
  if value.cleanup_ref ~= nil then validate_ref(value.cleanup_ref, context .. ".cleanup_ref") end
  if value.runtime_ports ~= nil then port_set_from_list(value.runtime_ports) end
  if value.early_exit ~= nil and type(value.early_exit) ~= "boolean" then
    fail("malformed-runtime-outcome", context .. ".early_exit must be boolean")
  end
  if value.frozen_dependencies_enforced ~= nil and type(value.frozen_dependencies_enforced) ~= "boolean" then
    fail("malformed-runtime-outcome", context .. ".frozen_dependencies_enforced must be boolean")
  end
  return value
end

E.copy_ref = copy_ref
E.validate_ref = validate_ref
E.validate_artifact_ref = validate_artifact_ref
E.validate_sessions = validate_sessions
E.port_set_from_list = port_set_from_list

return E
