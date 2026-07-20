local saga = require("workflow.saga")

local spec = {
  consumes = { "qa_publication_tick" },
  produces = { "qa_checkpoint_request", "qa_finalize_request", "github_comment_written" },
  stall_window = "30s",
  retry = false,
}

local function done(_event)
  return false
end

local function act(_event)
  return
end

return saga.department(spec, { done = done, act = act, name = "seam" })
