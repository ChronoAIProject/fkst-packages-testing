local defect_publication = require("defect_publication")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "defect_publication_request" },
  published_seam = { "defect_publication_request" },
  produces = { "github_issue_create_request", "defect_publication_receipt", "defect_publication_terminal" },
  stall_window = "10m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local prepared = defect_publication.prepare(
    event.payload or {},
    event.test_ports or defect_publication.production_ports()
  )
  for _, request in ipairs(prepared.issue_requests) do
    raise("github_issue_create_request", request)
  end
  if prepared.receipt ~= nil then
    raise("defect_publication_receipt", prepared.receipt)
    raise("defect_publication_terminal", defect_publication.terminal(prepared.receipt))
  end
  log.info("test-publication dept=publish_product_defects tag=PREPARED issues=" .. tostring(#prepared.issue_requests))
end

return saga.department(spec, { done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "test-publication.publish_product_defects" })
