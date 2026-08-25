-- contract.project_profile: host-authorized Project Profile contracts.
local error_facts = require("contract.error_facts")
local time = require("contract.time")

local P = {}

P.schemas = {
  profile = "testing-project-profile.v1",
  approval = "testing-project-profile-approval.v1",
  validation_receipt = "testing-project-profile-validation-receipt.v1",
}

P.canonicalization = "fkst-project-profile-canonical-json.v1"
P.listener_mode = "fkst-inherited-listeners-v1"

local max_string = 1024
local max_id = 180
local max_argv = 64
local max_argv_bytes = 16384
local max_list = 32
local max_approval_seconds = 86400

local command_phases = {
  install = true,
  build = true,
  migrate = true,
  seed = true,
  start = true,
  cleanup = true,
}

local shell_executables = {
  sh = true,
  bash = true,
  dash = true,
  zsh = true,
  fish = true,
  ksh = true,
  csh = true,
  tcsh = true,
  cmd = true,
  ["cmd.exe"] = true,
  powershell = true,
  ["powershell.exe"] = true,
  pwsh = true,
  ["pwsh.exe"] = true,
}

local mutation_operations = {
  create = true,
  update = true,
  delete = true,
}

local credential_options = {
  ["--password"] = true,
  ["--passwd"] = true,
  ["--token"] = true,
  ["--secret"] = true,
  ["--api-key"] = true,
  ["--api_key"] = true,
  ["--apikey"] = true,
  ["--authorization"] = true,
}

local function fail(classification, message)
  error(error_facts.error_message("contract.project-profile", classification, message))
end

local function valid_utf8(value)
  if type(value) ~= "string" then return false end
  if type(utf8) ~= "table" or type(utf8.len) ~= "function" then return false end
  local ok, length = pcall(utf8.len, value)
  return ok and length ~= nil
end

local function bounded(value, limit)
  return type(value) == "string"
    and value ~= ""
    and #value <= (limit or max_string)
    and value:find("[%z\1-\31\127]") == nil
    and valid_utf8(value)
end

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

local function only_fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, context .. " must be a table") end
  for key, _ in pairs(value) do
    if type(key) ~= "string" or allowed[key] ~= true then
      fail("malformed-" .. context, "unsupported field " .. tostring(key))
    end
  end
end

local function require_bounded(value, field, limit)
  if not bounded(value, limit) then fail("malformed-field", field .. " must be a bounded UTF-8 string") end
  return value
end

local function require_id(value, field)
  require_bounded(value, field, max_id)
  if value:find("%s") ~= nil then fail("malformed-field", field .. " must not contain whitespace") end
  return value
end

local function require_integer(value, field, minimum, maximum)
  if type(value) ~= "number" or value ~= math.floor(value) or value < minimum or value > maximum then
    fail("unbounded-value", field .. " must be an integer from " .. tostring(minimum) .. " to " .. tostring(maximum))
  end
  return value
end

local function require_boolean(value, field)
  if type(value) ~= "boolean" then fail("malformed-field", field .. " must be a boolean") end
  return value
end

local function require_sha256(value, field)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    fail("malformed-digest", field .. " must be a lowercase SHA-256 digest")
  end
  return value
end

local function require_commit_sha(value, field)
  if type(value) ~= "string" or #value ~= 40 or value:match("^[0-9a-f]+$") == nil then
    fail("mutable-revision", field .. " must be an immutable lowercase 40-hex commit ID")
  end
  return value
end

local function contains_embedded_credential(value)
  local text = tostring(value or "")
  local lower = text:lower()
  if lower:match("^[a-z][a-z0-9+.-]*://[^/?#]*@") ~= nil then return true end
  for _, marker in ipairs({
    "password=",
    "passwd=",
    "token=",
    "secret=",
    "api_key=",
    "apikey=",
    "authorization:",
    "bearer ",
    "-----begin private key-----",
  }) do
    if lower:find(marker, 1, true) ~= nil then return true end
  end
  return false
end

local function require_no_credential(value, field)
  if contains_embedded_credential(value) then
    fail("embedded-credential", field .. " must not contain credential material")
  end
  return value
end

local function validate_authority(authority, field)
  require_bounded(authority, field, 512)
  if authority:find("@", 1, true) ~= nil then fail("credential-url", field .. " must not contain userinfo") end
  if authority ~= authority:lower() then fail("noncanonical-url", field .. " must use a lowercase host") end

  local host, port
  if authority:sub(1, 1) == "[" then
    host, port = authority:match("^%[([0-9a-f:.]+)%]:?(%d*)$")
  else
    host, port = authority:match("^([a-z0-9.-]+):?(%d*)$")
  end
  if host == nil or host == "" then fail("malformed-url", field .. " has an invalid host") end
  if port ~= nil and port ~= "" then require_integer(tonumber(port), field .. " port", 1, 65535) end
  return authority
end

local function http_url_parts(value, field)
  require_bounded(value, field, 2048)
  require_no_credential(value, field)
  local scheme, authority, suffix = value:match("^(https?)://([^/?#]+)(.*)$")
  if scheme == nil then fail("malformed-url", field .. " must use http or https") end
  validate_authority(authority, field .. " authority")
  if suffix:find("?", 1, true) ~= nil or suffix:find("#", 1, true) ~= nil then
    fail("malformed-url", field .. " must not contain query or fragment data")
  end
  if suffix ~= "" and suffix:sub(1, 1) ~= "/" then fail("malformed-url", field .. " has an invalid path") end
  if suffix:find("\\", 1, true) ~= nil or suffix:find("%s") ~= nil then
    fail("unsafe-path", field .. " path is unsafe")
  end
  for segment in suffix:gmatch("[^/]+") do
    if segment == "." or segment == ".." then fail("unsafe-path", field .. " path contains traversal") end
  end
  return scheme .. "://" .. authority, suffix
end

local function require_origin(value, field)
  local origin, suffix = http_url_parts(value, field)
  if suffix ~= "" then fail("malformed-origin", field .. " must contain only an origin") end
  return origin
end

local function require_repository_url(value, field)
  require_bounded(value, field, 2048)
  require_no_credential(value, field)
  local authority, path = value:match("^https://([^/?#]+)(/[^?#]+)$")
  if authority == nil then fail("malformed-repository", field .. " must be a credential-free https URL") end
  validate_authority(authority, field .. " authority")
  if path:sub(-1) == "/" or path:find("//", 1, true) ~= nil or path:find("\\", 1, true) ~= nil
    or path:find("%s") ~= nil or path:find("%%") ~= nil then
    fail("unsafe-path", field .. " path is not canonical")
  end
  for segment in path:gmatch("[^/]+") do
    if segment == "." or segment == ".." or segment:find("^[%w._~-]+$") == nil then
      fail("unsafe-path", field .. " contains an unsafe repository path")
    end
  end
  return value
end

local function validate_repository(value, field)
  only_fields(value, { url = true, commit_sha = true }, field)
  require_repository_url(value.url, field .. ".url")
  require_commit_sha(value.commit_sha, field .. ".commit_sha")
  return value
end

local function same_repository(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.url == right.url
    and left.commit_sha == right.commit_sha
end

local function require_safe_workdir(value, field)
  require_bounded(value, field, 512)
  if value == "." then return value end
  if value:sub(1, 1) == "/" or value:find("\\", 1, true) ~= nil or value:find("%s") ~= nil
    or value:find("[^%w%._%-%/]") ~= nil then
    fail("unsafe-path", field .. " must be a safe repository-relative path")
  end
  for segment in value:gmatch("[^/]+") do
    if segment == "." or segment == ".." then fail("unsafe-path", field .. " contains traversal") end
  end
  return value
end

local function executable_basename(value)
  return tostring(value or ""):gsub("\\", "/"):match("([^/]+)$")
end

local function validate_argv(value, field)
  if not dense_list(value, max_argv) or #value == 0 then
    fail("malformed-argv", field .. " must be a non-empty bounded dense argv list")
  end
  local bytes = 0
  for index, item in ipairs(value) do
    require_bounded(item, field .. "[" .. tostring(index) .. "]")
    require_no_credential(item, field .. "[" .. tostring(index) .. "]")
    if credential_options[item:lower()] then
      fail("embedded-credential", field .. " must use typed secret references instead of credential argv options")
    end
    bytes = bytes + #item
  end
  if bytes > max_argv_bytes then fail("unbounded-value", field .. " exceeds the argv byte budget") end

  local executable = executable_basename(value[1]):lower()
  if executable == "env" then
    for index = 2, #value do
      local item = value[index]
      if item:sub(1, 1) ~= "-" and item:match("^[A-Za-z_][A-Za-z0-9_]*=") == nil then
        executable = executable_basename(item):lower()
        break
      end
    end
  end
  if shell_executables[executable] then
    fail("shell-command", field .. " must execute a direct argv command, not a shell interpreter")
  end
  return value
end

local function validate_source_ref(value, field)
  only_fields(value, { kind = true, ref = true }, field)
  require_id(value.kind, field .. ".kind")
  require_bounded(value.ref, field .. ".ref", 2048)
  require_no_credential(value.ref, field .. ".ref")
  local kind = value.kind:lower()
  if kind == "inline" or kind == "literal" or kind == "value" or kind == "resolved-secret" then
    fail("non-reference-value", field .. " must identify an external reference")
  end
  return value
end

local function same_source_ref(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.kind == right.kind
    and left.ref == right.ref
end

local function validate_secret_refs(value)
  if value == nil then return nil end
  if not dense_list(value, max_list) or #value == 0 then
    fail("malformed-secret-refs", "secret_refs must be a non-empty bounded dense list")
  end
  local seen = {}
  for index, item in ipairs(value) do
    only_fields(item, { name = true, type = true, source_ref = true }, "secret-reference")
    require_id(item.name, "secret_refs[" .. tostring(index) .. "].name")
    if item.name:match("^[A-Za-z_][A-Za-z0-9_]*$") == nil then
      fail("malformed-secret-ref", "secret reference names must be environment-style identifiers")
    end
    if item.type ~= "secret-reference" then fail("non-reference-value", "secret_refs.type must be secret-reference") end
    validate_source_ref(item.source_ref, "secret_refs[" .. tostring(index) .. "].source_ref")
    if seen[item.name] then fail("duplicate-secret-ref", item.name) end
    seen[item.name] = true
  end
  return value
end

local function validate_origins(value)
  if not dense_list(value, 16) or #value == 0 then
    fail("malformed-origins", "allowed_origins must be a non-empty bounded dense list")
  end
  local seen = {}
  for index, origin in ipairs(value) do
    require_origin(origin, "allowed_origins[" .. tostring(index) .. "]")
    if seen[origin] then fail("duplicate-origin", origin) end
    seen[origin] = true
  end
  return seen
end

local readiness_fields = {
  type = true,
  url = true,
  expected_status = true,
  host = true,
  port = true,
  argv = true,
}

local function loopback_http_origin(origin)
  return origin:match("^https?://127%.0%.0%.1:%d+$") ~= nil
    or origin:match("^https?://localhost:%d+$") ~= nil
    or origin:match("^https?://%[::1%]:%d+$") ~= nil
end

local function validate_readiness_check(value, field, allowed_origins, service_check)
  only_fields(value, readiness_fields, "readiness-check")
  if value.type == "http" then
    if value.host ~= nil or value.port ~= nil or value.argv ~= nil then
      fail("malformed-readiness", field .. " http checks contain unsupported fields")
    end
    local origin = http_url_parts(value.url, field .. ".url")
    if service_check then
      if not loopback_http_origin(origin) then fail("non-loopback", field .. ".url must use an explicit loopback origin") end
    elseif allowed_origins[origin] ~= true then
      fail("foreign-origin", field .. ".url is outside allowed_origins")
    end
    require_integer(value.expected_status, field .. ".expected_status", 100, 599)
  elseif value.type == "tcp" then
    if value.url ~= nil or value.expected_status ~= nil or value.argv ~= nil then
      fail("malformed-readiness", field .. " tcp checks contain unsupported fields")
    end
    require_bounded(value.host, field .. ".host", 253)
    require_no_credential(value.host, field .. ".host")
    if value.host:find("%s") ~= nil or value.host:find("[^A-Za-z0-9.:%-]") ~= nil then
      fail("malformed-readiness", field .. ".host is invalid")
    end
    require_integer(value.port, field .. ".port", 1, 65535)
  elseif value.type == "argv" then
    if value.url ~= nil or value.expected_status ~= nil or value.host ~= nil or value.port ~= nil then
      fail("malformed-readiness", field .. " argv checks contain unsupported fields")
    end
    validate_argv(value.argv, field .. ".argv")
  else
    fail("unsupported-readiness", field .. ".type")
  end
  return value
end

local function validate_readiness_checks(value, field, allowed_origins, service_check)
  if not dense_list(value, max_list) or #value == 0 then
    fail("malformed-readiness", field .. " must be a non-empty bounded dense list")
  end
  for index, item in ipairs(value) do
    validate_readiness_check(item, field .. "[" .. tostring(index) .. "]", allowed_origins, service_check)
  end
  return value
end

local function validate_commands(value)
  only_fields(value, command_phases, "commands")
  local count = 0
  for phase, _ in pairs(command_phases) do
    if value[phase] ~= nil then
      validate_argv(value[phase], "commands." .. phase)
      count = count + 1
    end
  end
  if value.start == nil then fail("missing-command", "commands.start is required") end
  if value.cleanup == nil then fail("missing-command", "commands.cleanup is required") end
  if count == 0 then fail("missing-command", "at least one lifecycle command is required") end
  return value
end

local function validate_listener_mode(value, field)
  if value ~= P.listener_mode then
    fail("unsupported-listener-mode", field .. " must be " .. P.listener_mode)
  end
  return value
end

local function validate_services(value, allowed_origins)
  if value == nil then return nil end
  if not dense_list(value, 16) or #value == 0 then
    fail("malformed-services", "dependent_services must be a non-empty bounded dense list")
  end
  local seen = {}
  for index, service in ipairs(value) do
    only_fields(service, {
      name = true,
      listener_mode = true,
      start_argv = true,
      cleanup_argv = true,
      readiness_checks = true,
    }, "dependent-service")
    require_id(service.name, "dependent_services[" .. tostring(index) .. "].name")
    validate_listener_mode(service.listener_mode, "dependent_services[" .. tostring(index) .. "].listener_mode")
    if seen[service.name] then fail("duplicate-service", service.name) end
    seen[service.name] = true
    validate_argv(service.start_argv, "dependent_services[" .. tostring(index) .. "].start_argv")
    validate_argv(service.cleanup_argv, "dependent_services[" .. tostring(index) .. "].cleanup_argv")
    local readiness_field = "dependent_services[" .. tostring(index) .. "].readiness_checks"
    validate_readiness_checks(service.readiness_checks, readiness_field, allowed_origins, true)
  end
  return value
end

local function validate_mutation_policy(value)
  only_fields(value, { mode = true, allowed_operations = true, cleanup_required = true }, "mutation-policy")
  if value.mode == "read-only" then
    if value.allowed_operations ~= nil or value.cleanup_required ~= nil then
      fail("malformed-mutation-policy", "read-only policy must not declare mutation fields")
    end
  elseif value.mode == "fixture-scoped" then
    if not dense_list(value.allowed_operations, 3) or #value.allowed_operations == 0 then
      fail("malformed-mutation-policy", "fixture-scoped allowed_operations must be a non-empty dense list")
    end
    local seen = {}
    for _, operation in ipairs(value.allowed_operations) do
      if mutation_operations[operation] ~= true then fail("unsupported-mutation", tostring(operation)) end
      if seen[operation] then fail("duplicate-mutation", operation) end
      seen[operation] = true
    end
    if require_boolean(value.cleanup_required, "mutation_policy.cleanup_required") ~= true then
      fail("unsafe-mutation-policy", "fixture-scoped mutation requires cleanup")
    end
  else
    fail("unsupported-mutation-policy", tostring(value.mode))
  end
  return value
end

local timeout_fields = {
  install_seconds = true,
  build_seconds = true,
  migrate_seconds = true,
  seed_seconds = true,
  start_seconds = true,
  readiness_seconds = true,
  cleanup_seconds = true,
  total_seconds = true,
  receipt_ttl_seconds = true,
}

local function validate_timeouts(value, commands, service_count)
  only_fields(value, timeout_fields, "timeouts")
  local phase_seconds = {
    install = require_integer(value.install_seconds, "timeouts.install_seconds", 1, 3600),
    build = require_integer(value.build_seconds, "timeouts.build_seconds", 1, 3600),
    migrate = require_integer(value.migrate_seconds, "timeouts.migrate_seconds", 1, 3600),
    seed = require_integer(value.seed_seconds, "timeouts.seed_seconds", 1, 3600),
    start = require_integer(value.start_seconds, "timeouts.start_seconds", 1, 3600),
  }
  require_integer(value.cleanup_seconds, "timeouts.cleanup_seconds", 1, 3600)
  local readiness = require_integer(value.readiness_seconds, "timeouts.readiness_seconds", 1, 3600)
  local total = require_integer(value.total_seconds, "timeouts.total_seconds", 1, 14400)
  require_integer(value.receipt_ttl_seconds, "timeouts.receipt_ttl_seconds", 1, 300)
  local required = readiness
  for phase, seconds in pairs(phase_seconds) do
    if commands[phase] ~= nil then required = required + seconds end
  end
  if (service_count or 0) > 0 then required = required + phase_seconds.start + readiness end
  if total < required then fail("unbounded-value", "timeouts.total_seconds is below the declared lifecycle bound") end
  return value
end

local budget_fields = {
  cpu_millis = true,
  memory_mb = true,
  disk_mb = true,
  processes = true,
  network_requests = true,
  output_bytes = true,
}

local function validate_resource_budgets(value)
  only_fields(value, budget_fields, "resource-budgets")
  require_integer(value.cpu_millis, "resource_budgets.cpu_millis", 100, 64000)
  require_integer(value.memory_mb, "resource_budgets.memory_mb", 64, 131072)
  require_integer(value.disk_mb, "resource_budgets.disk_mb", 64, 1048576)
  require_integer(value.processes, "resource_budgets.processes", 1, 256)
  require_integer(value.network_requests, "resource_budgets.network_requests", 0, 100000)
  require_integer(value.output_bytes, "resource_budgets.output_bytes", 1024, 104857600)
  return value
end

function P.validate_profile(value)
  only_fields(value, {
    schema = true,
    revision = true,
    repository = true,
    working_directory = true,
    commands = true,
    application_listener_mode = true,
    dependent_services = true,
    readiness_checks = true,
    allowed_origins = true,
    secret_refs = true,
    mutation_policy = true,
    timeouts = true,
    resource_budgets = true,
  }, "profile")
  if value.schema ~= P.schemas.profile then fail("unknown-schema", "profile schema") end
  require_id(value.revision, "revision")
  validate_repository(value.repository, "repository")
  require_safe_workdir(value.working_directory, "working_directory")
  validate_commands(value.commands)
  validate_listener_mode(value.application_listener_mode, "application_listener_mode")
  local origins = validate_origins(value.allowed_origins)
  validate_services(value.dependent_services, origins)
  validate_readiness_checks(value.readiness_checks, "readiness_checks", origins, false)
  validate_secret_refs(value.secret_refs)
  validate_mutation_policy(value.mutation_policy)
  validate_timeouts(value.timeouts, value.commands, #(value.dependent_services or {}))
  validate_resource_budgets(value.resource_budgets)
  return value
end

local function escape_json(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\b", "\\b")
  text = text:gsub("\f", "\\f")
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  return text
end

local function canonical_json(value)
  local kind = type(value)
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then
    if value ~= math.floor(value) then fail("canonicalization", "only integers are supported") end
    return tostring(value)
  end
  if kind == "string" then
    if not valid_utf8(value) then fail("canonicalization", "strings must be valid UTF-8") end
    return '"' .. escape_json(value) .. '"'
  end
  if kind ~= "table" then fail("canonicalization", "unsupported value type " .. kind) end

  local count, numeric, string_keys = 0, 0, {}
  for key, _ in pairs(value) do
    count = count + 1
    if type(key) == "number" then
      numeric = numeric + 1
    else
      table.insert(string_keys, key)
    end
  end
  if count == 0 then fail("canonicalization", "empty tables are not canonical") end
  if numeric > 0 then
    local parts = {}
    for _, item in ipairs(value) do table.insert(parts, canonical_json(item)) end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  table.sort(string_keys)
  local parts = {}
  for _, key in ipairs(string_keys) do
    table.insert(parts, '"' .. escape_json(key) .. '":' .. canonical_json(value[key]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function P.canonicalize_profile(value)
  P.validate_profile(value)
  return canonical_json(value)
end

local function digest_bytes(bytes, sha256)
  if type(sha256) ~= "function" then fail("missing-sha256", "a host-supplied SHA-256 function is required") end
  local ok, digest = pcall(sha256, bytes)
  if not ok then fail("sha256-failed", "the host SHA-256 function failed") end
  return require_sha256(digest, "sha256 result")
end

function P.profile_sha256(value, sha256)
  return digest_bytes(P.canonicalize_profile(value), sha256)
end

function P.validate_approval(value)
  only_fields(value, {
    schema = true,
    approval_id = true,
    canonicalization = true,
    profile_sha256 = true,
    repository = true,
    authority = true,
    policy_revision = true,
    evidence_ref = true,
    issued_at = true,
    expires_at = true,
    max_uses = true,
    trace_id = true,
    dedup_key = true,
  }, "approval")
  if value.schema ~= P.schemas.approval then fail("unknown-schema", "approval schema") end
  require_id(value.approval_id, "approval_id")
  if value.canonicalization ~= P.canonicalization then fail("unknown-canonicalization", "approval canonicalization") end
  require_sha256(value.profile_sha256, "profile_sha256")
  validate_repository(value.repository, "repository")
  validate_source_ref(value.authority, "authority")
  require_id(value.policy_revision, "policy_revision")
  validate_source_ref(value.evidence_ref, "evidence_ref")
  local issued = time.iso_timestamp_epoch_seconds(value.issued_at)
  local expires = time.iso_timestamp_epoch_seconds(value.expires_at)
  if issued == nil or expires == nil or expires <= issued then
    fail("malformed-approval-window", "issued_at and expires_at must form a valid UTC interval")
  end
  if expires - issued > max_approval_seconds then
    fail("unbounded-value", "approval validity must not exceed " .. tostring(max_approval_seconds) .. " seconds")
  end
  if value.max_uses ~= 1 then fail("replayable-approval", "max_uses must be exactly 1") end
  require_id(value.trace_id, "trace_id")
  require_id(value.dedup_key, "dedup_key")
  return value
end

function P.canonicalize_approval(value)
  P.validate_approval(value)
  return canonical_json(value)
end

function P.approval_sha256(value, sha256)
  return digest_bytes(P.canonicalize_approval(value), sha256)
end

local function validate_trusted_authorities(value)
  if not dense_list(value, max_list) then fail("malformed-trust-root", "trusted_authorities must be a bounded dense list") end
  local seen = {}
  for index, entry in ipairs(value) do
    only_fields(entry, { source_ref = true, policy_revision = true, verify = true }, "trusted-authority")
    validate_source_ref(entry.source_ref, "trusted_authorities[" .. tostring(index) .. "].source_ref")
    require_id(entry.policy_revision, "trusted_authorities[" .. tostring(index) .. "].policy_revision")
    if type(entry.verify) ~= "function" then fail("malformed-trust-root", "trusted authority verify must be a function") end
    local key = entry.source_ref.kind .. "\0" .. entry.source_ref.ref .. "\0" .. entry.policy_revision
    if seen[key] then fail("malformed-trust-root", "trusted authority entries must be unique") end
    seen[key] = entry
  end
  return seen
end

local function authority_key(source_ref, policy_revision)
  return source_ref.kind .. "\0" .. source_ref.ref .. "\0" .. policy_revision
end

local function authenticate_approval(approval, approval_bytes, approval_digest, trusted)
  local entry = trusted[authority_key(approval.authority, approval.policy_revision)]
  if entry == nil then fail("unknown-authority", "approval authority or policy revision is not trusted") end
  local ok, attestation = pcall(entry.verify, {
    approval = approval,
    canonical_approval = approval_bytes,
    approval_sha256 = approval_digest,
  })
  if not ok or type(attestation) ~= "table" then
    fail("authority-verification-failed", "trusted authority did not authenticate the approval")
  end
  only_fields(attestation, {
    authenticated = true,
    approval_sha256 = true,
    authority = true,
    policy_revision = true,
    evidence_ref = true,
  }, "authority-attestation")
  if attestation.authenticated ~= true
    or attestation.approval_sha256 ~= approval_digest
    or not same_source_ref(attestation.authority, approval.authority)
    or attestation.policy_revision ~= approval.policy_revision
    or not same_source_ref(attestation.evidence_ref, approval.evidence_ref) then
    fail("authority-verification-failed", "authority attestation is missing exact approval bindings")
  end
  return true
end

local function require_now(value)
  local epoch = time.iso_timestamp_epoch_seconds(value)
  if epoch == nil then fail("malformed-time", "now must be a valid UTC timestamp") end
  return epoch
end

local function validate_common_context(value)
  if type(value) ~= "table" then fail("malformed-context", "authorization context must be a table") end
  if type(value.sha256) ~= "function" then fail("missing-sha256", "authorization context requires sha256") end
  local now = require_now(value.now)
  local trusted = validate_trusted_authorities(value.trusted_authorities)
  validate_source_ref(value.approval_ref, "approval_ref")
  return now, trusted
end

local function validate_profile_approval_binding(profile, approval, context)
  P.validate_profile(profile)
  P.validate_approval(approval)
  local profile_digest = P.profile_sha256(profile, context.sha256)
  if profile_digest ~= approval.profile_sha256 then fail("profile-digest-mismatch", "approval is stale or foreign") end
  if not same_repository(profile.repository, approval.repository) then
    fail("repository-scope-mismatch", "approval repository or commit does not match the profile")
  end

  local now, trusted = validate_common_context(context)
  local issued = time.iso_timestamp_epoch_seconds(approval.issued_at)
  local expires = time.iso_timestamp_epoch_seconds(approval.expires_at)
  if now < issued or now >= expires then fail("stale-approval", "approval is outside its validity window") end

  local approval_bytes = P.canonicalize_approval(approval)
  local approval_digest = digest_bytes(approval_bytes, context.sha256)
  authenticate_approval(approval, approval_bytes, approval_digest, trusted)
  return profile_digest, approval_digest, now
end

local function copy_source_ref(value)
  return { kind = value.kind, ref = value.ref }
end

local function copy_repository(value)
  return { url = value.url, commit_sha = value.commit_sha }
end

function P.issue_validation_receipt(profile, approval, context)
  only_fields(context, {
    now = true,
    sha256 = true,
    trusted_authorities = true,
    approval_ref = true,
  }, "receipt-context")
  local profile_digest, approval_digest = validate_profile_approval_binding(profile, approval, context)
  return {
    schema = P.schemas.validation_receipt,
    profile_schema = profile.schema,
    profile_revision = profile.revision,
    canonicalization = P.canonicalization,
    profile_sha256 = profile_digest,
    repository = copy_repository(profile.repository),
    approval_ref = copy_source_ref(context.approval_ref),
    approval_id = approval.approval_id,
    approval_sha256 = approval_digest,
    authority = copy_source_ref(approval.authority),
    policy_revision = approval.policy_revision,
    evidence_ref = copy_source_ref(approval.evidence_ref),
    issued_at = context.now,
    trace_id = approval.trace_id,
    dedup_key = approval.dedup_key,
  }
end

function P.validate_validation_receipt(value)
  only_fields(value, {
    schema = true,
    profile_schema = true,
    profile_revision = true,
    canonicalization = true,
    profile_sha256 = true,
    repository = true,
    approval_ref = true,
    approval_id = true,
    approval_sha256 = true,
    authority = true,
    policy_revision = true,
    evidence_ref = true,
    issued_at = true,
    trace_id = true,
    dedup_key = true,
  }, "validation-receipt")
  if value.schema ~= P.schemas.validation_receipt then fail("unknown-schema", "validation receipt schema") end
  if value.profile_schema ~= P.schemas.profile then fail("unknown-schema", "receipt profile schema") end
  require_id(value.profile_revision, "profile_revision")
  if value.canonicalization ~= P.canonicalization then fail("unknown-canonicalization", "receipt canonicalization") end
  require_sha256(value.profile_sha256, "profile_sha256")
  validate_repository(value.repository, "repository")
  validate_source_ref(value.approval_ref, "approval_ref")
  require_id(value.approval_id, "approval_id")
  require_sha256(value.approval_sha256, "approval_sha256")
  validate_source_ref(value.authority, "authority")
  require_id(value.policy_revision, "policy_revision")
  validate_source_ref(value.evidence_ref, "evidence_ref")
  if time.iso_timestamp_epoch_seconds(value.issued_at) == nil then fail("malformed-time", "issued_at is invalid") end
  require_id(value.trace_id, "trace_id")
  require_id(value.dedup_key, "dedup_key")
  return value
end

local function receipt_matches(profile, approval, receipt, context, profile_digest, approval_digest, now)
  P.validate_validation_receipt(receipt)
  if receipt.profile_revision ~= profile.revision
    or receipt.canonicalization ~= P.canonicalization
    or receipt.profile_sha256 ~= profile_digest
    or not same_repository(receipt.repository, profile.repository) then
    fail("stale-receipt", "receipt does not bind the current profile and repository")
  end
  if not same_source_ref(receipt.approval_ref, context.approval_ref)
    or receipt.approval_id ~= approval.approval_id
    or receipt.approval_sha256 ~= approval_digest
    or not same_source_ref(receipt.authority, approval.authority)
    or receipt.policy_revision ~= approval.policy_revision
    or not same_source_ref(receipt.evidence_ref, approval.evidence_ref)
    or receipt.trace_id ~= approval.trace_id
    or receipt.dedup_key ~= approval.dedup_key then
    fail("foreign-receipt", "receipt does not bind the current approval")
  end

  local receipt_issued = time.iso_timestamp_epoch_seconds(receipt.issued_at)
  local approval_issued = time.iso_timestamp_epoch_seconds(approval.issued_at)
  if receipt_issued < approval_issued or receipt_issued > now
    or now - receipt_issued > profile.timeouts.receipt_ttl_seconds then
    fail("stale-receipt", "receipt is outside its point-of-use freshness window")
  end
end

local function claim_replay_guard(profile, approval, receipt, profile_digest, approval_digest, replay_guard)
  if type(replay_guard) ~= "function" then fail("missing-replay-guard", "an atomic replay guard is required") end
  local ok, claim = pcall(replay_guard, {
    approval_id = approval.approval_id,
    approval_sha256 = approval_digest,
    profile_sha256 = profile_digest,
    repository = copy_repository(profile.repository),
    trace_id = receipt.trace_id,
    dedup_key = receipt.dedup_key,
    max_uses = approval.max_uses,
  })
  if not ok or type(claim) ~= "table" then fail("replay-guard-failed", "replay guard did not return a claim") end
  only_fields(claim, { claimed = true, claim_id = true }, "replay-claim")
  if claim.claimed ~= true then fail("replay-rejected", "approval was already claimed or replayed") end
  require_id(claim.claim_id, "replay claim_id")
end

local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, item in pairs(value) do copy[deep_copy(key)] = deep_copy(item) end
  return copy
end

function P.authorize_execution(profile, approval, receipt, context)
  only_fields(context, {
    now = true,
    sha256 = true,
    trusted_authorities = true,
    approval_ref = true,
    replay_guard = true,
  }, "execution-context")
  local profile_digest, approval_digest, now = validate_profile_approval_binding(profile, approval, context)
  receipt_matches(profile, approval, receipt, context, profile_digest, approval_digest, now)
  claim_replay_guard(profile, approval, receipt, profile_digest, approval_digest, context.replay_guard)
  return deep_copy(profile)
end

return P
