local contract = require("contract.testing_execution")
local action_capabilities = require("contract.testing_action_capabilities")

local R = {}

local function under_artifact_root(root, pointer)
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  return type(pointer) == "string" and pointer:sub(1, #prefix) == prefix
end

function R.validate(request, receipt)
  contract.validate_execution_request(request)
  contract.validate_execution_receipt(receipt)
  if receipt.module ~= request.module then
    error("testing-runtime: receipt-module-mismatch: expected " .. tostring(request.module))
  end
  if receipt.request_sha256 ~= request.plan_sha256 then
    error("testing-runtime: receipt-digest-mismatch: execution receipt is stale or foreign")
  end
  if receipt.action_count ~= #request.actions then
    error("testing-runtime: receipt-count-mismatch: request and receipt action counts differ")
  end
  for index, action_receipt in ipairs(receipt.actions) do
    local action = request.actions[index]
    if action_receipt.step ~= action.step
      or action_receipt.case_id ~= action.case_id
      or action_receipt.action ~= action.action then
      error("testing-runtime: receipt-action-mismatch: step " .. tostring(index))
    end
    if not under_artifact_root(request.artifact_root, action_receipt.evidence_pointer) then
      error("testing-runtime: receipt-evidence-root-mismatch: step " .. tostring(index))
    end
    if #action_receipt.assertion_results ~= #action.assertions then
      error("testing-runtime: receipt-assertion-count-mismatch: step " .. tostring(index))
    end
    for assertion_index, assertion_result in ipairs(action_receipt.assertion_results) do
      if assertion_result.type ~= action.assertions[assertion_index].type then
        error(
          "testing-runtime: receipt-assertion-mismatch: step " .. tostring(index)
            .. " assertion " .. tostring(assertion_index)
        )
      end
      if not under_artifact_root(request.artifact_root, assertion_result.evidence_pointer) then
        error(
          "testing-runtime: receipt-assertion-evidence-root-mismatch: step " .. tostring(index)
            .. " assertion " .. tostring(assertion_index)
        )
      end
    end
    if action.action == "safe-mutation-fixture" and action_receipt.fixture_receipt_path == nil then
      error("testing-runtime: fixture-receipt-missing: " .. tostring(action.case_id))
    end
    local capability = action_capabilities.get(action.action)
    if capability ~= nil then
      local resolved = action_capabilities.validate_resolved_target(action_receipt.resolved_target)
      local observed = action_capabilities.validate_observed_post_action_state(action_receipt.observed_post_action_state)
      if resolved.selector ~= action.target.selector then
        error("testing-runtime: receipt-target-mismatch: step " .. tostring(index))
      end
      if observed.target.selector ~= action.expected.target.selector then
        error("testing-runtime: receipt-observation-mismatch: step " .. tostring(index))
      end
    end
  end
  return receipt
end

function R.status(receipt)
  contract.validate_execution_receipt(receipt)
  return receipt.status, receipt.classification
end

return R
