local defect_publication = require("defect_publication")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "github_issue_written" },
  published_seam = { "github_issue_written" },
  produces = { "defect_publication_receipt", "defect_publication_terminal" },
  stall_window = "10m",
  retry = false,
}

local function accept(event)
  local handoff = ((event or {}).payload or {}).handoff
  return type(handoff) == "table" and handoff.kind == "test-publication.product-defect"
end

local function done(_event)
  return false
end

local function act(event)
  local acknowledged = defect_publication.acknowledge_issue(
    event.payload or {},
    event.test_ports or defect_publication.production_ports()
  )
  local receipt = acknowledged.receipt
  if receipt == nil then return end
  raise("defect_publication_receipt", receipt)
  raise("defect_publication_terminal", defect_publication.terminal(receipt))
  log.info("test-publication dept=acknowledge_product_defect tag=PUBLISHED status=" .. tostring(receipt.status))
end

return saga.department(spec, {
  accept = accept, done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "test-publication.acknowledge_product_defect",
})
