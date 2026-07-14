local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "publication_request" },
  produces = { "dry_run_receipt" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local request = event.payload or {}
  if not core.is_artifact_only_dry_run(request) then return end
  local receipt = core.persist_dry_run(request)
  log.info("test-publication dept=dry_run tag=PERSISTED publication_key=" .. tostring(receipt.publication_key))
  raise("dry_run_receipt", receipt)
end

local M = saga.department(spec, { done = done, act = act, name = "dry_run" })
M.pipeline = _G.pipeline
return M
