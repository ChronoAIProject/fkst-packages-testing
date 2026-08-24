local M = {}
local forge_strings = require("forge.strings")
local stdout_policy = require("forge.github.stdout_policy")

local function graphql_argv(query, fields)
  local argv = { "gh", "api", "graphql", "-f", "query=" .. tostring(query) }
  for key, value in pairs(fields or {}) do
    table.insert(argv, "-f")
    table.insert(argv, tostring(key) .. "=" .. tostring(value))
  end
  return argv
end

local function graphql_repo_parts(repo)
  local owner, name = forge_strings.split_repo(repo)
  for _, segment in ipairs({ owner, name }) do
    if segment == nil or segment == "." or segment == ".."
      or segment:find("^[%w%._%-]+$") == nil then
      error("forge: github-repository-invalid: forge.github.graphql: invalid repository")
    end
  end
  return owner, name
end

local function sorted_issue_numbers(numbers)
  if type(numbers) ~= "table" then
    error("forge: github-issue-number-list-type-invalid: forge.github.graphql: issue numbers must be a table")
  end
  local seen = {}
  local result = {}
  for _, value in ipairs(numbers) do
    local number = tonumber(value)
    if number == nil or number < 1 or number > 2147483647 or number ~= math.floor(number) then
      error("forge: github-issue-number-invalid: forge.github.graphql: issue number must be a positive integer")
    end
    if not seen[number] then
      seen[number] = true
      table.insert(result, number)
    end
  end
  table.sort(result)
  if #result == 0 then
    error("forge: github-issue-number-list-empty: forge.github.graphql: at least one issue number is required")
  end
  return result
end

function M.install(handle)
  function handle.graphql(query, fields, timeout)
    return handle._exec(graphql_argv(query, fields), timeout, "gh GraphQL", stdout_policy.content_json("graphql"))
  end

  function handle.issue_list_updated_at(repo, numbers, timeout)
    local owner, name = graphql_repo_parts(repo)
    local selections = {}
    for _, number in ipairs(sorted_issue_numbers(numbers)) do
      table.insert(selections, "i" .. tostring(number) .. ":issue(number:" .. tostring(number) .. "){number updatedAt}")
    end
    local query = "query{repository(owner:\"" .. owner .. "\",name:\"" .. name .. "\"){"
      .. table.concat(selections) .. "}}"
    return handle.graphql(query, nil, timeout)
  end
end

return M
