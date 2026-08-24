local gitref = require("forge.gitref")
local strings = require("contract.strings")

local K = {}

local max_key_len = 200
local max_dedup_len = 512
local max_repo_key_len = 100
local max_issue_key_len = 30

local function safe_key_segment(value, limit)
  local safe = strings.sanitize_key(value, max_key_len):sub(1, limit):gsub("/+$", "")
  if safe == "" then
    return "empty"
  end
  return safe
end

local function safe_head_segment(head_sha)
  if not gitref.is_git_sha(head_sha) then
    error("github-devloop: git-sha-invalid: invalid head sha")
  end
  return tostring(head_sha)
end

local function key(namespace, repo, pr_number, head_sha)
  local value = strings.sanitize_key(table.concat({
    "github-devloop",
    namespace,
    safe_key_segment(repo, max_repo_key_len),
    "pr",
    safe_key_segment(pr_number, max_issue_key_len),
    safe_head_segment(head_sha),
  }, "/"), false)
  if not strings.is_path_safe_key(value, max_dedup_len) then
    error("github-devloop: dedup-key-invalid: invalid dedup_key")
  end
  return value
end

function K.ci_selfheal_once_key(repo, pr_number, head_sha)
  return key("ci-selfheal", repo, pr_number, head_sha)
end

function K.ci_missing_status_first_observed_key(repo, pr_number, head_sha)
  return key("ci-missing-status-observed", repo, pr_number, head_sha)
end

return K
