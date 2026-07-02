local E = {}

local strings = require("contract.strings")
local testing_contract = require("contract.testing")

local max_string = 512
local max_items = 64

local function has_no_control(value)
  return type(value) == "string" and value:find("[%z\1-\31]") == nil
end

function E.text(value, fallback, limit)
  if type(value) == "string" then
    local text = strings.trim(value)
    if text ~= "" and #text <= (limit or max_string) and has_no_control(text) then
      return text
    end
  end
  return fallback
end

function E.dense_list(value)
  if type(value) ~= "table" then return false end
  local count, max_index = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return false end
    count = count + 1
    if key > max_index then max_index = key end
  end
  return count == max_index
end

local function pick_module(list, module)
  if not E.dense_list(list) then return nil end
  for _, item in ipairs(list) do
    if type(item) == "table" and (item.module or item.name or item.id) == module then return item end
  end
  if #list == 1 and type(list[1]) == "table" then return list[1] end
  return nil
end

function E.from_payload(payload)
  if type(payload) ~= "table" then return nil end
  if type(payload.module_evidence) == "table" then return payload.module_evidence end
  if type(payload.discovered_module) == "table" then return payload.discovered_module end
  if type(payload.discovered_modules) == "table" then
    return pick_module(payload.discovered_modules, payload.module)
  end
  local discovery = payload.discovery or payload.discovery_result
  if type(discovery) ~= "table" then return nil end
  if discovery.entry ~= nil or discovery.features ~= nil or discovery.interactions ~= nil then return discovery end
  return pick_module(discovery.modules or discovery.discovered_modules, payload.module)
end

function E.has_payload(payload)
  return type(E.from_payload(payload)) == "table"
end

function E.artifact_root(payload, request)
  local root = payload.artifact_root or (request and request.artifact_root)
  if root == nil then
    local key = request and (request.dedup_key or request.module) or payload.module
    root = ".testing/runs/" .. testing_contract.safe_key(key, "module")
  end
  if not strings.is_artifact_root(root) then
    error("testing-pipeline: malformed-plan: artifact_root must be a safe .testing/runs/... path")
  end
  return root
end

function E.entry(evidence, module)
  local raw = type(evidence.entry) == "table" and evidence.entry or {}
  local target = raw.url or raw.route or raw.path or raw.href
    or evidence.url or evidence.route or evidence.path or evidence.base_url
  if type(evidence.entry) == "string" then target = evidence.entry end
  local loaded = raw.loaded
  if loaded == nil then loaded = evidence.page_loaded or evidence.loaded end
  return {
    id = "entry",
    label = E.text(raw.title or raw.name or evidence.title or evidence.page_title, module .. " entry"),
    target = E.text(target, nil),
    loaded = loaded == true and true or loaded == false and false or nil,
  }
end

function E.append_items(out, value, default_kind)
  if value == nil then return end
  if not E.dense_list(value) then
    error("testing-pipeline: malformed-plan: evidence lists must be dense arrays")
  end
  for _, item in ipairs(value) do
    if #out >= max_items then break end
    if type(item) == "string" then
      table.insert(out, { label = E.text(item, default_kind), kind = default_kind, visible = true })
    elseif type(item) == "table" then
      table.insert(out, {
        label = E.text(item.label or item.name or item.text or item.title, default_kind),
        kind = E.text(item.kind or item.type or item.action, default_kind, 80),
        target = E.text(item.target or item.url or item.route or item.selector, nil),
        visible = item.visible ~= false,
      })
    else
      error("testing-pipeline: malformed-plan: evidence list entries must be strings or tables")
    end
  end
end

function E.visible_elements(evidence)
  local items = {}
  E.append_items(items, evidence.visible_elements or evidence.elements, "visible-element")
  return items
end

function E.signal(value)
  if value == nil then return nil end
  if type(value) == "string" then return E.text(value, "observed", 80) end
  if type(value) ~= "table" then return nil end
  if type(value.clean) == "boolean" then return value.clean and "clean" or "issues-observed" end
  return E.text(value.status or value.state or value.summary, "observed", 80)
end

return E
