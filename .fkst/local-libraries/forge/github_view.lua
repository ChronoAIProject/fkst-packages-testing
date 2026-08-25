local M = {}

function M.parse_view_updated_at(stdout)
  local ok, decoded = pcall(json.decode, stdout or "")
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  local updated_at = decoded.updatedAt or decoded.updated_at
  if updated_at == nil or tostring(updated_at) == "" then
    return nil
  end
  return tostring(updated_at)
end

function M.parse_updated_at_stdout(stdout)
  local text = tostring(stdout or "")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    return nil
  end
  return text
end

function M.json_string(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\b", "\\b")
  text = text:gsub("\f", "\\f")
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  text = text:gsub("[%z\1-\31]", function(char)
    return string.format("\\u%04X", string.byte(char))
  end)
  return '"' .. text .. '"'
end

function M.json_value(value)
  if value == nil then
    return "null"
  end
  if type(value) == "boolean" then
    return value and "true" or "false"
  end
  if type(value) == "number" then
    return tostring(value)
  end
  return M.json_string(value)
end

function M.rest_state(value)
  if value == nil then
    return nil
  end
  return tostring(value):upper()
end

function M.rest_pr_state(pr)
  if type(pr) ~= "table" then
    return nil
  end
  local merged_at = pr.merged_at
  if pr.merged == true or (type(merged_at) == "string" and merged_at ~= "") then
    return "MERGED"
  end
  return M.rest_state(pr.state)
end

function M.append_comments(target, value)
  if type(value) ~= "table" then
    return
  end
  if type(value.comments) == "table" then
    M.append_comments(target, value.comments)
    return
  end
  if value.id ~= nil or value.body ~= nil or value.user ~= nil or value.author ~= nil then
    table.insert(target, value)
    return
  end
  for _, item in ipairs(value) do
    M.append_comments(target, item)
  end
end

function M.decode_comments_json(stdout, error_context)
  local source = stdout
  if source == nil or source == "" then
    source = "[]"
  end
  local ok, decoded = pcall(json.decode, source)
  if ok and type(decoded) == "table" then
    return decoded
  end
  error(tostring(error_context or "github_view: REST") .. " response is not valid JSON")
end

function M.labels_json(labels)
  local parts = {}
  for _, label in ipairs(labels or {}) do
    if type(label) == "table" then
      table.insert(parts, '{"name":' .. M.json_value(label.name) .. "}")
    elseif label ~= nil then
      table.insert(parts, '{"name":' .. M.json_value(label) .. "}")
    end
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

function M.label_names(labels_json)
  local labels = {}
  for _, label in ipairs(labels_json or {}) do
    if type(label) == "table" and label.name ~= nil then
      table.insert(labels, tostring(label.name))
    elseif type(label) == "string" then
      table.insert(labels, label)
    end
  end
  return labels
end

function M.assignees_json(assignees)
  local parts = {}
  for _, assignee in ipairs(assignees or {}) do
    if type(assignee) == "table" then
      table.insert(parts, '{"login":' .. M.json_value(assignee.login) .. "}")
    elseif assignee ~= nil then
      table.insert(parts, '{"login":' .. M.json_value(assignee) .. "}")
    end
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

function M.repo_name_with_owner(repo)
  if type(repo) ~= "table" then
    return nil
  end
  if repo.full_name ~= nil and tostring(repo.full_name) ~= "" then
    return tostring(repo.full_name)
  end
  if repo.nameWithOwner ~= nil and tostring(repo.nameWithOwner) ~= "" then
    return tostring(repo.nameWithOwner)
  end
  if type(repo.owner) == "table" and repo.owner.login ~= nil and repo.name ~= nil then
    return tostring(repo.owner.login) .. "/" .. tostring(repo.name)
  end
  return nil
end

function M.repo_owner_login(repo)
  if type(repo) == "table" and type(repo.owner) == "table" and repo.owner.login ~= nil then
    return tostring(repo.owner.login)
  end
  local name_with_owner = M.repo_name_with_owner(repo)
  return name_with_owner and name_with_owner:match("^([^/]+)/") or nil
end

function M.decode_pr_view(value)
  if type(value) == "table" then
    return value
  end
  return json.decode(value or "{}")
end

local function pr_repository_name_with_owner(head_repository, head_repository_owner)
  if type(head_repository) == "string" then
    return head_repository
  end
  if type(head_repository) ~= "table" then
    return nil
  end
  if head_repository.nameWithOwner ~= nil and head_repository.nameWithOwner ~= "" then
    return tostring(head_repository.nameWithOwner)
  end
  if head_repository.name_with_owner ~= nil and head_repository.name_with_owner ~= "" then
    return tostring(head_repository.name_with_owner)
  end
  if head_repository.full_name ~= nil and head_repository.full_name ~= "" then
    return tostring(head_repository.full_name)
  end
  local name = head_repository.name
  local owner = nil
  if type(head_repository.owner) == "table" and head_repository.owner.login ~= nil then
    owner = head_repository.owner.login
  elseif type(head_repository_owner) == "table" and head_repository_owner.login ~= nil then
    owner = head_repository_owner.login
  elseif type(head_repository_owner) == "string" then
    owner = head_repository_owner
  end
  if owner ~= nil and name ~= nil then
    return tostring(owner) .. "/" .. tostring(name)
  end
  return nil
end

local function pr_comments(comments_json)
  local comments = {}
  for _, comment in ipairs(comments_json or {}) do
    if type(comment) == "table" and comment.body ~= nil then
      local author_login = nil
      if type(comment.author) == "table" and comment.author.login ~= nil then
        author_login = tostring(comment.author.login)
      elseif type(comment.user) == "table" and comment.user.login ~= nil then
        author_login = tostring(comment.user.login)
      elseif comment.author_login ~= nil then
        author_login = tostring(comment.author_login)
      end
      table.insert(comments, {
        id = comment.id,
        body = tostring(comment.body),
        author_login = author_login,
        created_at = comment.createdAt or comment.created_at,
      })
    elseif type(comment) == "string" then
      table.insert(comments, {
        body = comment,
        author_login = "fkst-test-bot",
      })
    end
  end
  return comments
end

local function status_rollup_entries(value)
  if type(value) ~= "table" then
    return {}
  end
  if type(value.nodes) == "table" then
    return value.nodes
  end
  return value
end

function M.parse_pr_view_merge(value)
  local decoded = M.decode_pr_view(value)
  local is_cross_repository = decoded.isCrossRepository
  if is_cross_repository == nil then
    is_cross_repository = decoded.is_cross_repository
  end
  local is_draft = decoded.isDraft
  if is_draft == nil then
    is_draft = decoded.is_draft
  end
  return {
    head_ref_name = decoded.headRefName or decoded.head_ref_name,
    head_sha = decoded.headRefOid or decoded.head_ref_oid,
    base_ref_name = decoded.baseRefName or decoded.base_ref_name,
    state = decoded.state,
    merged_at = decoded.mergedAt or decoded.merged_at,
    comments = pr_comments(decoded.comments),
    head_repository = pr_repository_name_with_owner(
      decoded.headRepository or decoded.head_repository,
      decoded.headRepositoryOwner or decoded.head_repository_owner
    ),
    is_cross_repository = is_cross_repository,
    is_draft = is_draft,
    mergeable = decoded.mergeable,
    merge_state_status = decoded.mergeStateStatus or decoded.merge_state_status,
    status_check_rollup = status_rollup_entries(decoded.statusCheckRollup or decoded.status_check_rollup),
  }, decoded
end

return M
