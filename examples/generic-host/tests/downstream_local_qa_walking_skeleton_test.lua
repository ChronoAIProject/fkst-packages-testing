local durable = require("host_durable_workflow_qa")
local lifecycle = require("test_support.host_workflow_qa_supervisor")
local support = require("test_support.canonical_workflow_qa")
local fixture = require("host_canonical_workflow_qa_support")
local t = fkst.test

local function assert_digest_bound(context, path)
  local artifact = context.store:load(path)
  t.is_true(type(artifact) == "table")
  t.is_true(type(artifact.digest) == "string" and artifact.digest:match("^[0-9a-f]+$") ~= nil)
  t.eq(#artifact.digest, 64)
  t.eq(context.store:digest(path), artifact.digest)
  return artifact.value
end

return {
  test_inventory_initial_state_traverses_real_local_qa_workflow = function()
    local owner = support.new({
      scenario = "downstream-inventory",
      durable = true,
      prepare_execution_grant_pending = false,
      publication_channel = "filesystem-dry-run-v1",
    })
    local ok, err = pcall(function()
      t.eq(#owner.commit_sha, 40)
      t.is_true(owner.commit_sha:match("^[0-9a-f]+$") ~= nil)
      t.eq(owner.request.repository.commit_sha, owner.commit_sha)

      local context = durable.load(owner.project_root, owner.durable_root, owner.run_id)
      for _, name in ipairs({
        "load_artifact", "write_artifact", "artifact_digest", "claim_preauthorization",
        "grant_values", "record_terminal",
      }) do
        t.eq(type(context.generic_host_runtime[name]), "function")
      end
      context.after_environment_ready = function(active)
        local resolved = fixture.require_exec({ "git", "rev-parse", "HEAD" }, active.workspace_root)
          :match("([0-9a-f]+)")
        t.eq(resolved, active.commit_sha)
        t.is_true(active.workspace_root ~= active.fixture_source_root)
        t.eq(fixture.read_file(active.workspace_root .. "/source-only-uncommitted.txt"), nil)

        local state_path = active.workspace_root .. "/state/inventory.json"
        local before = fixture.read_file(state_path)
        local missing = fixture.http_request({
          method = "GET",
          url = active.origin .. "/inventory/UNKNOWN",
        }, 10)
        t.eq(missing.status, 404)
        t.eq(fixture.read_file(state_path), before)
      end

      lifecycle.run(context, context.project_root)

      t.eq(context.local_qa_department_calls.intake, 1)
      t.eq(context.local_qa_department_calls.execution_grant, 1)
      t.eq(context.local_qa_department_calls.terminal, 1)

      local catalog = assert_digest_bound(context, context.request.structured_execution.case_catalog_ref)
      t.eq(#catalog.cases, 1)
      t.eq(catalog.cases[1].design_case_id, "inventory:initial-state")
      t.eq(catalog.cases[1].case_id, "inventory-initial-state")
      t.eq(catalog.cases[1].request.url, context.origin .. "/inventory/SKU-001")

      local plan = assert_digest_bound(context, context.request.structured_execution.structured_plan_ref)
      t.eq(#plan.cases, 1)
      t.eq(plan.cases[1].case_id, "inventory-initial-state")

      local target_effects = context.records:list("testing-runner/target-effects")
      t.eq(#target_effects, 1)
      local target = target_effects[1].value
      t.eq(target.binding.case_id, "inventory-initial-state")
      t.eq(target.binding.request.method, "GET")
      t.eq(target.binding.request.url, context.origin .. "/inventory/SKU-001")
      t.eq(target.result.status, 200)
      t.eq(target.result.headers["content-type"], "application/json")
      t.eq(target.result.body, "{\"sku\":\"SKU-001\",\"on_hand\":5,\"reserved\":0,\"available\":5}\n")
      local observed = json.decode(target.result.body)
      t.eq(observed.sku, "SKU-001")
      t.eq(observed.on_hand, 5)
      t.eq(observed.reserved, 0)
      t.eq(observed.available, 5)

      local execution_root = context.request.structured_execution.artifact_root
      local execution = assert_digest_bound(context, execution_root .. "/execution.json")
      t.eq(execution.status, "passed")
      t.eq(execution.case_count, 1)
      t.eq(execution.passed_count, 1)
      local case_results = assert_digest_bound(context, execution_root .. "/case-results.json")
      t.eq(#case_results.cases, 1)
      t.eq(case_results.cases[1].case_id, "inventory-initial-state")
      local response_evidence = assert_digest_bound(context, case_results.cases[1].evidence_ref)
      t.eq(response_evidence.status_code, 200)
      t.eq(response_evidence.body_excerpt, target.result.body)

      local terminal_records = context.records:list("generic-host/terminal")
      t.eq(#terminal_records, 1)
      local terminal = terminal_records[1].value
      t.eq(terminal.status, "passed")
      t.eq(terminal.counts.planned, 1)
      t.eq(terminal.counts.executed, 1)
      t.eq(terminal.counts.passed, 1)
      for _, name in ipairs({ "failed", "skipped", "error", "blocked" }) do
        t.eq(terminal.counts[name], 0)
      end

      local aggregate = assert_digest_bound(context, context.request.publication.aggregate_report_ref)
      t.eq(aggregate.status, "passed")
      t.eq(aggregate.counts.passed, 1)
      local publication = assert_digest_bound(context, terminal.aggregate_publication_receipt_ref)
      t.eq(publication.schema, "test-publication.qa-publication-receipt.v2")
      t.eq(publication.status, "published")
      t.eq(publication.channel, "filesystem-dry-run-v1")
      for _, effect in ipairs(context.records:list("test-publication/effects")) do
        t.eq(effect.value.binding.channel, "filesystem-dry-run-v1")
        t.eq(effect.value.result.remote_url, nil)
      end

      local cleanup = assert_digest_bound(context, terminal.cleanup_receipt_ref)
      t.eq(cleanup.status, "complete")
      t.eq(#cleanup.remaining_resources, 0)
      t.eq(fixture.read_file(context.workspace_root .. "/state/inventory.json"), nil)
      local workspace_absent = os.execute("test ! -e " .. string.format("%q", context.workspace_root))
      t.is_true(workspace_absent == true or workspace_absent == 0)
      local listener_closed = pcall(fixture.http_request, {
        method = "GET", url = context.origin .. "/inventory/SKU-001",
      }, 1)
      t.eq(listener_closed, false)
    end)
    owner:cleanup()
    if not ok then error(err, 0) end
  end,
}
