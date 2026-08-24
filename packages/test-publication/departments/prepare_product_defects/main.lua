local defect_publication = require("defect_publication")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "defect_preparation_request" },
  published_seam = { "defect_preparation_request" },
  produces = { "defect_publication_request" },
  stall_window = "10m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  defect_publication.validate_preparation_request(payload)
  local prepared = defect_publication.prepare_defects(
    payload,
    event.test_ports or defect_publication.production_ports()
  )
  log.info("test-publication dept=prepare_product_defects tag=PREPARED replayed=" .. tostring(prepared.replayed))
  raise("defect_publication_request", prepared.defect_request)
end

return saga.department(spec, {
  done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "test-publication.prepare_product_defects",
})
