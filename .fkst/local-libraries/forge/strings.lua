-- forge.strings: GitHub/Git-shaped string helpers for forge adapters and callers.
local contract_strings = require("contract.strings")

local S = {}

function S.canonical_login(login)
  if login == nil then
    return nil
  end
  local value = contract_strings.trim(login):lower()
  if value:sub(1, 4) == "app/" then
    local slug = value:match("^app/([^/]+)$")
    if slug == nil or slug:sub(-5) == "[bot]" then
      return nil
    end
    value = slug
  elseif value:find("/", 1, true) ~= nil then
    return nil
  else
    value = value:gsub("%[bot%]$", "")
  end
  if value == "" then
    return nil
  end
  return value
end

function S.is_canonical_login(login)
  return type(login) == "string" and S.canonical_login(login) == login
end

function S.split_repo(repo)
  local owner, name = tostring(repo or ""):match("^([^/]+)/([^/]+)$")
  if owner == nil or owner == "" or name == nil or name == "" then
    return nil, nil
  end
  return owner, name
end

function S.is_bounded_repo(repo, limit)
  if not contract_strings.is_bounded_string(repo, limit) or S.split_repo(repo) == nil then
    return false
  end
  return repo:find("^[%w._-]+/[%w._-]+$") ~= nil
end

local function is_repo_segment(value)
  return type(value) == "string" and value ~= "" and value:find("/", 1, true) == nil
end

function S.join_repo(owner, name)
  if not is_repo_segment(owner) or not is_repo_segment(name) then
    return nil
  end
  return owner .. "/" .. name
end

function S.comment_body(comment)
  if type(comment) == "table" then
    return tostring(comment.body or "")
  end
  return tostring(comment or "")
end

function S.count(s, sub)
  local haystack = tostring(s or "")
  local needle = tostring(sub or "")
  if needle == "" then
    return 0
  end

  local total = 0
  local pos = 1
  while true do
    local start_pos, end_pos = haystack:find(needle, pos, true)
    if start_pos == nil then
      return total
    end
    total = total + 1
    pos = end_pos + 1
  end
end

function S.is_git_ref_safe(value)
  local max_branch_len = 160
  if not contract_strings.is_bounded_string(value, max_branch_len) then
    return false
  end
  local text = tostring(value)
  if text:sub(1, 1) == "-" or text:sub(1, 1) == "/" then
    return false
  end
  if text:find("%.%.", 1, true) ~= nil
    or text:find("//", 1, true) ~= nil
    or text:find("@{", 1, true) ~= nil
    or text:sub(-1) == "/"
    or text:sub(-1) == "."
    or text:sub(-5) == ".lock" then
    return false
  end
  if text:find("[%s~^:?%[%]\\*]") ~= nil then
    return false
  end
  for segment in text:gmatch("[^/]+") do
    if segment == "." or segment == ".." or segment:sub(1, 1) == "." then
      return false
    end
  end
  return text:find("^[%w%._%-%/]+$") ~= nil
end

return S
