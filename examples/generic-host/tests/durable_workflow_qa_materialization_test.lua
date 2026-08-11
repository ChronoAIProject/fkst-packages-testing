local canonical = require("host_canonical_workflow_qa")
local durable = require("host_durable_workflow_qa")
local support = require("host_canonical_workflow_qa_support")
local t = fkst.test

local function with_inventory_context(fn)
  local context = canonical.new({ scenario = "downstream-inventory" })
  context.project_root = context.temp_root .. "/materialization-project"
  context.durable_root = context.temp_root .. "/materialization-durable"
  support.prepare_supervisor_project(context.project_root)
  local ok, err = pcall(fn, context)
  context:cleanup()
  if not ok then error(err, 0) end
end

local function design_request(context)
  return context.request.design_module_start.ai_design_loop_request
end

local function remove_artifact(context, path)
  context.store.artifacts[path] = nil
  os.remove(support.absolute(path))
end

local function assert_materialization_error(context, expected)
  local ok, err = pcall(durable.initialize, context, context.durable_root)
  t.eq(ok, false)
  t.is_true(tostring(err):find(
    "generic-host durable design input materialization failed: " .. expected, 1, true) ~= nil)
end

return {
  test_materializes_and_verifies_immutable_design_inputs = function()
    with_inventory_context(function(context)
      durable.initialize(context, context.durable_root)
      local request = design_request(context)
      for _, field in ipairs({ "coverage_scope_ref", "deterministic_cases_ref" }) do
        local path = request[field].artifact_pointer
        t.eq(support.read_file(context.project_root .. "/" .. path), context.store:load(path).raw)
      end
      t.eq(support.read_file(context.project_root .. "/" .. request.seed_cases_ref.artifact_pointer), nil)
      t.is_true(durable.load(context.project_root, context.durable_root, context.run_id) ~= nil)
    end)
  end,

  test_rejects_missing_design_inputs = function()
    for _, field in ipairs({ "coverage_scope_ref", "deterministic_cases_ref" }) do
      with_inventory_context(function(context)
        local path = design_request(context)[field].artifact_pointer
        remove_artifact(context, path)
        assert_materialization_error(context, field .. " is missing: " .. path)
      end)
    end
  end,

  test_rejects_design_input_digest_mismatch = function()
    with_inventory_context(function(context)
      local reference = design_request(context).coverage_scope_ref
      reference.artifact_digest = "design-corrupted"
      assert_materialization_error(context, "coverage_scope_ref digest mismatch: " .. reference.artifact_pointer)
    end)
  end,

  test_rejects_malformed_design_input_reference = function()
    with_inventory_context(function(context)
      design_request(context).deterministic_cases_ref = { artifact_pointer = "../unsafe.json" }
      assert_materialization_error(context, "deterministic_cases_ref reference is invalid:")
    end)
  end,

  test_supports_requests_without_ai_design_loop = function()
    with_inventory_context(function(context)
      local request = design_request(context)
      context.request.design_module_start.ai_design_loop_request = nil
      durable.initialize(context, context.durable_root)
      t.eq(support.read_file(context.project_root .. "/" .. request.coverage_scope_ref.artifact_pointer), nil)
      t.eq(support.read_file(context.project_root .. "/" .. request.deterministic_cases_ref.artifact_pointer), nil)
    end)
  end,
}
