local json_codec = require("testing_runtime.json")
local canonical = require("host_canonical_workflow_qa")
local support = require("host_canonical_workflow_qa_support")
local supervisor = require("test_support.host_workflow_qa_supervisor")
local t = fkst.test

local root = ".testing/runs/pql-home-title"

return {
  test_compiles_promoted_pql_browser_case_through_canonical_module_publication = function()
    local context = canonical.new({ scenario = "pql-home-title" })
    local ok, failure = pcall(function()
      local lifecycle = supervisor.prepare(context, support.project_root)
      t.is_true(lifecycle.prepared)
      t.eq(context.testing_design_invocations, 1)
      t.eq(context.pql_lineage.asset_id, "TCA-HOME-TITLE")
      t.eq(context.pql_lineage.asset_version, "1")
      t.eq(context.pql_lineage.asset_ref.ref, "TCA-HOME-TITLE@1")
      t.eq(context.pql_lineage.requirement_refs[1].ref, "REQ-HOME-TITLE")
      t.eq(context.pql_lineage.design_case_id, "TCA-HOME-TITLE@1")

      local state = context.workflow_state
      local module_plan_ref = state.artifacts.module_plan_ref
      local published = assert(context.store:load(module_plan_ref))
      local module_plan = published.value
      local module_case = module_plan.modules[1].cases[1]
      t.eq(module_case.id, "TCA-HOME-TITLE@1")
      t.eq(module_case.review_status, "executable")
      t.is_true(support.equal(module_plan.testing_design_context, context.pql_lineage.context))
      t.eq(published.raw, json_codec.encode(module_plan) .. "\n")
      t.eq(published.digest, support.sha256_bytes(published.raw))
      t.eq(context.store:write_count(module_plan_ref), 1)

      local catalog_ref = context.request.structured_execution.case_catalog_ref
      local catalog_artifact = assert(context.store:load(catalog_ref))
      local catalog = catalog_artifact.value
      t.eq(#catalog.cases, 1)
      t.eq(catalog.cases[1].design_case_id, "TCA-HOME-TITLE@1")
      t.eq(catalog.cases[1].case_id, "home-title")

      local plan_ref = state.artifacts.structured_plan_ref
      local plan_artifact = assert(context.store:load(plan_ref))
      local plan = plan_artifact.value
      t.eq(plan.schema, "testing-structured-plan.v2")
      t.eq(plan.execution_mode, "agentic-browser")
      t.eq(plan.module_plan_sha256, published.digest)
      t.eq(plan.case_catalog_sha256, catalog_artifact.digest)
      t.eq(plan.environment_receipt_sha256, context.store:digest(state.environment_receipt_ref))
      t.eq(plan.browser_readiness_sha256, context.store:digest(state.artifacts.browser_readiness_ref))
      t.eq(#plan.cases, 1)
      t.eq(plan.cases[1].case_id, "home-title")
      t.eq(plan.cases[1].design_case_id, nil)
      t.eq(#plan.cases[1].completion_assertions, 4)
      t.eq(plan_artifact.raw, json_codec.encode(plan) .. "\n")
      t.eq(plan_artifact.digest, support.sha256_bytes(plan_artifact.raw))

      local replay = supervisor.prepare(context, support.project_root)
      t.is_true(replay.prepared)
      t.eq(context.store:digest(plan_ref), plan_artifact.digest)
      t.eq(context.store:write_count(plan_ref), 1)
      t.eq(next(context.target_effects), nil)
    end)
    context:cleanup()
    if not ok then error(failure, 0) end
  end,
}
