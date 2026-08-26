local contract = require("contract.testing_package_executor")
local executor = require("testing_package_executor.executor")
local resolver = require("testing_runtime.package_resolver")

local M = {}

function M.resolve(request, host_ports) return resolver.resolve(request, host_ports) end

function M.failure_receipt(request, failure)
  return resolver.failure_receipt(request, failure)
end

local function execution_ports(host_ports)
  if type(host_ports) ~= "table" then return host_ports end
  return {
    load_completed_execution = host_ports.load_completed_execution,
    claim_execution = host_ports.claim_execution,
    check_freshness = host_ports.check_freshness,
    persist_effect_intent = host_ports.persist_effect_intent,
    browser_read_title = host_ports.browser_read_title,
    persist_effect_receipt = host_ports.persist_effect_receipt,
    write_canonical = host_ports.write_canonical,
    complete_execution = host_ports.complete_execution,
    now = host_ports.now,
    sha256 = host_ports.sha256,
  }
end

function M.execute(request, host_ports)
  local resolved = resolver.resolve(request, host_ports)
  if resolved.schema == contract.schemas.admission_conflict then return resolved end
  return executor.execute(resolved, execution_ports(host_ports))
end

return M
