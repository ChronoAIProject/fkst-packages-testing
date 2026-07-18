local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "test-publication.publication_request" },
  produces = {},
  fanout = { "test-publication.publication_request" },
  stall_window = "5m",
  retry = false,
}

local function accept(event)
  local source = ((event or {}).payload or {}).source_ref
  return type(source) == "table"
    and source.kind == "artifact"
    and tostring(source.ref or ""):sub(-31) == "/environment-receipt-ready.json"
end

local function done(_event)
  return false
end

local function act(event)
  local result = core.acknowledge_testing_terminal(event.payload or {})
  log.info("environment-factory dept=acknowledge tag=" .. (result.acknowledged and "ACK" or "IGNORED"))
end

local M = saga.department(spec, { accept = accept, done = done, act = act, name = "acknowledge" })
M.pipeline = _G.pipeline
return M
