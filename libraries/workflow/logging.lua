local error_facts = require("contract.error_facts")

local L = {}

function L.log_line(prefix, level, dept, proposal_id, tag, fields)
  local parts = {
    tostring(prefix),
    "dept=" .. tostring(dept or "unknown"),
    "proposal_id=" .. tostring(proposal_id or "unknown"),
    "tag=" .. tostring(tag or "event"),
  }
  for _, field in ipairs(fields or {}) do
    table.insert(parts, tostring(field))
  end
  log[level or "info"](table.concat(parts, " "))
end

function L.log_entry(prefix, dept, event, proposal_id, dedup_key)
  L.log_line(prefix, "info", dept, proposal_id, "ENTRY", {
    "queue=" .. tostring(event and event.queue or "unknown"),
    "payload_type=" .. type(event and event.payload),
    "version=" .. tostring(dedup_key or ""),
    "dedup_key=" .. tostring(dedup_key or ""),
  })
end

function L.payload_field(payload, key)
  if type(payload) ~= "table" then
    return nil
  end
  return payload[key]
end

local function is_engine_lock_busy(err)
  return type(err) == "userdata"
    and tostring(err):find("with_lock lock busy: ", 1, true) == 1
end

local function event_identity(event)
  local payload = type(event) == "table" and event.payload or nil
  if type(payload) ~= "table" then
    return "unknown"
  end
  return payload.proposal_id or payload.run_id or payload.trace_id or "unknown"
end

local function log_pipeline_failure(dept, event, result)
  if is_engine_lock_busy(result) then
    return
  end
  local queue = type(event) == "table" and event.queue or nil
  local fields = error_facts.error_fact_fields(error_facts.error_class_from_message(result), queue, dept, result, {
    source_ref = error_facts.event_source_ref(event),
    attempt = type(event) == "table" and event.attempt or nil,
    terminal = type(event) == "table" and event.terminal or nil,
  })
  table.insert(fields, "queue=" .. error_facts.one_line(queue))
  table.insert(fields, "error=" .. error_facts.one_line(result))
  L.log_line("fkst-testing", "error", dept, event_identity(event), "FAILURE", fields)
end

local function rethrow(result) error(result, 0) end

function L.wrap_pipeline_failure(dept, fn)
  if type(fn) ~= "function" then
    error("workflow.logging: failure-handler-invalid: wrap_pipeline_failure requires a function", 2)
  end
  return function(event)
    local ok, result = pcall(fn, event)
    if not ok then log_pipeline_failure(dept, event, result); rethrow(result) end
    return result
  end
end

return L
