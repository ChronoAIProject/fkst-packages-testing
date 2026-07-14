local contract = require("contract.testing_execution")

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
  local screenshot_count = 0
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
      if assertion_result.screenshot_artifact ~= nil then
        screenshot_count = screenshot_count + 1
        if not under_artifact_root(request.artifact_root, assertion_result.screenshot_artifact.path) then
          error(
            "testing-runtime: receipt-screenshot-root-mismatch: step " .. tostring(index)
              .. " assertion " .. tostring(assertion_index)
          )
        end
      end
    end
    if action.action == "safe-mutation-fixture" and action_receipt.fixture_receipt_path == nil then
      error("testing-runtime: fixture-receipt-missing: " .. tostring(action.case_id))
    end
  end
  if request.redaction_selectors ~= nil and receipt.status == "failed" and screenshot_count ~= 1 then
    error("testing-runtime: failure-screenshot-missing: configured failed execution requires one screenshot artifact")
  end
  if request.redaction_selectors == nil and screenshot_count ~= 0 then
    error("testing-runtime: failure-screenshot-unexpected: receipt references an unconfigured screenshot artifact")
  end
  return receipt
end

function R.status(receipt)
  contract.validate_execution_receipt(receipt)
  return receipt.status, receipt.classification
end

return R
