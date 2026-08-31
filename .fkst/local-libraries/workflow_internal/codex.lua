local workflow_env = require("workflow_internal.env")

local M = {}

local role_timeout_defaults = {
  consensus = 3600,
  implement = 5 * 60 * 60,
  fix = 5 * 60 * 60,
  ["review-meta"] = 3600,
  archaudit = 3600,
  ["release-notes"] = 3600,
  judgment = 3600,
  decompose = 3600,
  intake = 3600,
  ["workflow-select"] = 3600,
  ["workflow-materialize"] = 3600,
  ["sync-conflict"] = 3600,
}

local role_timeout_env = {
  consensus = "FKST_CODEX_TIMEOUT_CONSENSUS",
  implement = "FKST_CODEX_TIMEOUT_IMPLEMENT",
  fix = "FKST_CODEX_TIMEOUT_FIX",
  ["review-meta"] = "FKST_CODEX_TIMEOUT_REVIEW_META",
  archaudit = "FKST_CODEX_TIMEOUT_ARCHAUDIT",
  ["release-notes"] = "FKST_CODEX_TIMEOUT_RELEASE_NOTES",
  judgment = "FKST_CODEX_TIMEOUT_JUDGMENT",
  decompose = "FKST_CODEX_TIMEOUT_DECOMPOSE",
  intake = "FKST_CODEX_TIMEOUT_INTAKE",
  ["workflow-select"] = "FKST_CODEX_TIMEOUT_WORKFLOW_SELECT",
  ["workflow-materialize"] = "FKST_CODEX_TIMEOUT_WORKFLOW_MATERIALIZE",
  ["sync-conflict"] = "FKST_CODEX_TIMEOUT_SYNC_CONFLICT",
}

local allowed_timeout_env = {}
for _, env_name in pairs(role_timeout_env) do
  allowed_timeout_env[env_name] = true
end
local with_repository_context
local function timeout_env_command(name)
  if not allowed_timeout_env[name] then
    error("workflow_internal.codex: invalid-env-name: env name is not allowed")
  end
  return 'printf %s "$' .. name .. '"'
end

local read_timeout_env = workflow_env.read_env(timeout_env_command)

local function copy_opts(opts)
  local out = {}
  for key, value in pairs(type(opts) == "table" and opts or {}) do
    out[key] = value
  end
  return out
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function parse_timeout_seconds(env_name, raw)
  local value = trim(raw)
  if value == "" or value:find("[^0-9]") ~= nil then
    error("workflow_internal.codex: timeout-config-invalid: invalid " .. env_name .. ": expected positive integer seconds")
  end
  local parsed = tonumber(value)
  if parsed == nil or parsed <= 0 then
    error("workflow_internal.codex: timeout-config-invalid: invalid " .. env_name .. ": expected positive integer seconds")
  end
  return parsed
end

local function resolved_role_timeout(role, dispatch_opts)
  local default = M.default_role_timeout_seconds(role)
  if default == nil then
    error("workflow_internal.codex: timeout-role-unknown: unknown timeout role: " .. tostring(role))
  end
  if dispatch_opts.timeout ~= nil then
    return dispatch_opts.timeout
  end
  local env_name = role_timeout_env[role]
  local raw = env_name and read_timeout_env(env_name) or nil
  if raw ~= nil then
    return parse_timeout_seconds(env_name, raw)
  end
  return default
end

function M.default_role_timeout_seconds(role)
  return role_timeout_defaults[role]
end

-- The attempt budget for a role, for callers that must stay inside the same budget as the
-- attempt itself rather than restate it. A verification gate that hardcodes its own timeout
-- drifts the moment a deployment raises the role env, and then times out on work that is
-- still within budget (#2887).
function M.role_timeout_seconds(role)
  return resolved_role_timeout(role, {})
end

function M.with_resolved_timeout(role, opts)
  local dispatch_opts = copy_opts(opts)
  dispatch_opts.timeout = resolved_role_timeout(role, dispatch_opts)
  return with_repository_context(dispatch_opts)
end

function M.judgment_codex_opts(prompt, worktree)
  return {
    prompt = prompt,
    worktree = worktree,
    sandbox = "read-only",
  }
end

function M.unrestricted_codex_opts(prompt, worktree)
  return {
    prompt = prompt,
    worktree = worktree,
  }
end

local function identity_parts(identity_or_role, proposal_id, dedup_key)
  if type(identity_or_role) == "table" then
    local legacy_id = identity_or_role.proposal_id
    local invocation_id = identity_or_role.invocation_id
    if legacy_id ~= nil and invocation_id ~= nil and tostring(legacy_id) ~= tostring(invocation_id) then
      error("workflow_internal.codex: run-identity-conflict: conflicting run identity")
    end
    return identity_or_role.role, invocation_id or legacy_id, identity_or_role.dedup_key
  end
  return identity_or_role, proposal_id, dedup_key
end

local function run_lease_expired(run)
  -- A running record whose lease deadline is already past is NOT live: it is a
  -- dead/hung run awaiting reap, and a redrive must reactivate it (start a
  -- replacement), never defer to it. lease_expires_at_ms is data on the run
  -- record (milliseconds), not a magic constant; now() is seconds.
  local lease = run.lease_expires_at_ms
  if type(lease) ~= "number" or type(now) ~= "function" then
    return false
  end
  return lease < now() * 1000
end

local function run_matches(run, role, proposal_id, dedup_key)
  return type(run) == "table"
    and tostring(run.role or "") == tostring(role or "")
    and tostring(run.proposal_id or "") == tostring(proposal_id or "")
    and tostring(run.dedup_key or "") == tostring(dedup_key or "")
    and tostring(run.status or "") == "running"
    and not run_lease_expired(run)
end

function M.live_run_active(identity_or_role, proposal_id, dedup_key)
  local role
  role, proposal_id, dedup_key = identity_parts(identity_or_role, proposal_id, dedup_key)
  if role == nil or proposal_id == nil or dedup_key == nil then
    return false
  end
  -- Observational precheck only: concurrent first dispatches can race here. The
  -- atomic one-live-run invariant belongs to the substrate live_run_key admission
  -- follow-on; this wrapper closes redrive/redelivery forks by using one identity
  -- for both the guard and the spawn opts.
  if type(fkst) ~= "table" or type(fkst.codex_runs) ~= "function" then
    return false
  end
  local ok, status = pcall(fkst.codex_runs)
  if not ok or type(status) ~= "table" or type(status.running) ~= "table" then
    return false
  end
  for _, run in ipairs(status.running) do
    if run_matches(run, role, proposal_id, dedup_key) then
      return true
    end
  end
  return false
end

function M.dispatch(identity, opts)
  if type(identity) ~= "table" then
    error("workflow_internal.codex: dispatch-identity-invalid: dispatch identity must be a convergence identity")
  end
  local role, proposal_id, dedup_key = identity_parts(identity)
  if role == nil or proposal_id == nil or dedup_key == nil then
    error("workflow_internal.codex: dispatch-identity-incomplete: dispatch identity is incomplete")
  end
  if M.live_run_active(identity) then
    return {
      deferred = true,
      reason = "live-run-active",
      identity = identity,
    }
  end
  local dispatch_opts = copy_opts(opts)
  dispatch_opts.timeout = resolved_role_timeout(role, dispatch_opts)
  with_repository_context(dispatch_opts)
  local sync = dispatch_opts.sync == true
  dispatch_opts.sync = nil
  dispatch_opts.role = role
  dispatch_opts.proposal_id = proposal_id
  dispatch_opts.dedup_key = dedup_key
  if sync then
    return spawn_codex_sync(dispatch_opts)
  end
  return spawn_codex(dispatch_opts)
end

local repository_roots_env = "FKST_CODEX_REPOSITORY_ROOTS"

local function repository_roots_env_command(name)
  if name ~= repository_roots_env then
    error("workflow_internal.codex: repository-roots-env-name-invalid: invalid repository-roots env name")
  end
  return 'printf %s "$' .. name .. '"'
end

local read_repository_roots_env = workflow_env.read_env(repository_roots_env_command)

local function parse_repository_roots(raw)
  local value = tostring(raw or "")
  if value:find("\r", 1, true) ~= nil then
    error("workflow_internal.codex: repository-roots-carriage-return: carriage returns are forbidden")
  end
  local roots = {}
  local seen = {}
  for line in (value .. "\n"):gmatch("(.-)\n") do
    local root = trim(line)
    if root ~= "" then
      if root:sub(1, 1) ~= "/" or root:find("%c") ~= nil then
        error("workflow_internal.codex: repository-root-invalid: expected absolute single-line path")
      end
      if not seen[root] then
        seen[root] = true
        table.insert(roots, root)
      end
    end
  end
  return roots
end


with_repository_context = function(opts)
  if opts.prompt == nil then
    return opts
  end
  local roots = parse_repository_roots(read_repository_roots_env(repository_roots_env))
  local lines = { "Repository locations resolved by the launcher:" }
  local worktree = trim(opts.worktree)
  if worktree ~= "" then
    if worktree:find("%c") ~= nil then
      error("workflow_internal.codex: worktree-invalid: expected single-line path")
    end
    table.insert(lines, "- active worktree: " .. worktree)
  end
  for _, root in ipairs(roots) do
    table.insert(lines, "- repository root: " .. root)
  end
  if #roots == 0 then
    table.insert(lines, "- repository roots: none provided; report the missing context instead of searching the filesystem")
  end
  table.insert(lines, "Repository locations are authoritative and already provided.")
  table.insert(lines, "Do not run `find`, `fd`, `locate`, or recursive directory walks to discover repository locations.")
  opts.prompt = table.concat(lines, "\n") .. "\n\n" .. tostring(opts.prompt)
  return opts
end

return M
