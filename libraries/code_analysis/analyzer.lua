local strings = require("contract.strings")

local A = {}

local max_files = 64
local max_file_bytes = 65536
local max_facts = 512
local max_path = 512

local function fail(code, message)
  error("code-analysis: " .. code .. ": " .. message)
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function safe_repository_root(value)
  return strings.is_path_safe_key(value, max_path) and value:sub(1, 1) ~= "/" and value:sub(-1) ~= "/"
end

local function default_list_files(repository_root)
  local command = "find " .. shell_quote(repository_root) .. " -type f -name '*.lua' -print"
  local handle = io.popen(command)
  if handle == nil then fail("repository-read-failed", "could not enumerate repository files") end
  local files = {}
  for path in handle:lines() do table.insert(files, path) end
  local ok = handle:close()
  if ok ~= true and ok ~= 0 then fail("repository-read-failed", "repository enumeration failed") end
  table.sort(files)
  return files
end

local function default_read(path)
  local handle, err = io.open(path, "rb")
  if handle == nil then fail("repository-read-failed", err or ("could not read " .. path)) end
  local body = handle:read("*a")
  handle:close()
  return body
end

local function relative_path(repository_root, path)
  local prefix = repository_root:gsub("/+$", "") .. "/"
  if path:sub(1, #prefix) ~= prefix then fail("repository-path-escape", "enumerated file left repository scope") end
  local relative = path:sub(#prefix + 1)
  if not strings.is_path_safe_key(relative, max_path) then fail("repository-path-invalid", "source path is unsafe") end
  return relative
end

local function long_bracket_end(text, start)
  local equals = text:sub(start):match("^%[(=*)%[")
  if equals == nil then return nil end
  local close = "]" .. equals .. "]"
  local finish = text:find(close, start + #equals + 2, true)
  return finish and (finish + #close) or (#text + 1)
end

local function tokenize(text)
  local tokens = {}
  local index, line, column = 1, 1, 1

  local function advance(limit)
    while index < limit do
      if text:sub(index, index) == "\n" then
        line, column = line + 1, 1
      else
        column = column + 1
      end
      index = index + 1
    end
  end

  while index <= #text do
    local char = text:sub(index, index)
    local next_char = text:sub(index + 1, index + 1)
    if char:match("%s") then
      advance(index + 1)
    elseif char == "-" and next_char == "-" then
      local long_end = long_bracket_end(text, index + 2)
      if long_end ~= nil then
        advance(long_end)
      else
        local newline = text:find("\n", index + 2, true) or (#text + 1)
        advance(newline)
      end
    elseif char == "'" or char == '"' then
      local quote = char
      advance(index + 1)
      while index <= #text do
        local item = text:sub(index, index)
        if item == "\\" then
          advance(math.min(index + 2, #text + 1))
        elseif item == quote then
          advance(index + 1)
          break
        else
          advance(index + 1)
        end
      end
    elseif char == "[" and long_bracket_end(text, index) ~= nil then
      advance(long_bracket_end(text, index))
    elseif char:match("[%a_]") then
      local token_line, token_column = line, column
      local finish = index + 1
      while text:sub(finish, finish):match("[%w_]") do finish = finish + 1 end
      table.insert(tokens, {
        kind = "identifier",
        value = text:sub(index, finish - 1),
        line = token_line,
        column = token_column,
      })
      advance(finish)
    else
      table.insert(tokens, { kind = "symbol", value = char, line = line, column = column })
      advance(index + 1)
    end
  end
  return tokens
end

local function function_facts(path, text)
  local tokens = tokenize(text)
  local facts = {}
  for index, token in ipairs(tokens) do
    if token.value == "function" then
      local name_token = tokens[index + 1]
      if name_token ~= nil and name_token.kind == "identifier" then
        local name = name_token.value
        local cursor = index + 2
        while tokens[cursor] ~= nil
          and (tokens[cursor].value == "." or tokens[cursor].value == ":")
          and tokens[cursor + 1] ~= nil
          and tokens[cursor + 1].kind == "identifier" do
          name = name .. tokens[cursor].value .. tokens[cursor + 1].value
          cursor = cursor + 2
        end
        if tokens[cursor] ~= nil and tokens[cursor].value == "(" then
          table.insert(facts, {
            id = "function-" .. strings.decimal_checksum(path .. ":" .. tostring(name_token.line) .. ":" .. name),
            kind = "function",
            name = name,
            source = { path = path, line = name_token.line, column = name_token.column },
          })
        end
      end
    end
  end
  return facts
end

function A.analyze(repository_root, artifact_pointer, opts)
  opts = opts or {}
  if not safe_repository_root(repository_root) then fail("repository-root-invalid", "repository_root must be a safe relative path") end
  local list_files = opts.list_files or default_list_files
  local read = opts.read_source or default_read
  local paths = list_files(repository_root)
  if type(paths) ~= "table" or #paths > max_files then fail("analysis-bounds-exceeded", "repository has too many Lua files") end
  table.sort(paths)

  local facts, file_count = {}, 0
  for _, path in ipairs(paths) do
    local relative = relative_path(repository_root, path)
    local body = read(path)
    if type(body) ~= "string" then fail("repository-read-failed", "source reader returned a non-string body") end
    if #body > max_file_bytes then fail("analysis-bounds-exceeded", "Lua source file exceeds the byte limit") end
    file_count = file_count + 1
    table.insert(facts, {
      id = "file-" .. strings.decimal_checksum(relative),
      kind = "file",
      name = relative,
      source = { path = relative, line = 1, column = 1 },
    })
    for _, fact in ipairs(function_facts(relative, body)) do table.insert(facts, fact) end
    if #facts > max_facts then fail("analysis-bounds-exceeded", "repository has too many code facts") end
  end

  for index, fact in ipairs(facts) do fact.pointer = artifact_pointer .. "#/facts/" .. tostring(index) end
  return {
    schema = "testing.code-analysis.v1",
    artifact_kind = "code-analysis",
    version = 1,
    artifact_pointer = artifact_pointer,
    scope = { kind = "repository-tree", repository_root = repository_root },
    facts = facts,
    fact_count = #facts,
    file_count = file_count,
  }
end

return A
