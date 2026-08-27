local contract = require("contract.browser_control")
local executor_contract = require("contract.testing_package_executor")
local json_codec = require("testing_runtime.json")

local M = {}
local runtime_cli = "libraries/testing_runtime/bin/fkst-browser-control-runtime.js"

local function resolve(ports)
  if type(ports) ~= "table" then
    error("testing-runtime: browser-control-ports-unavailable: ports must be a table")
  end
  for _, name in ipairs({ "exec_argv", "read", "write", "decode" }) do
    if type(ports[name]) ~= "function" then
      error("testing-runtime: browser-control-invalid-ports: missing " .. name)
    end
  end
  return ports
end

local function paths(root, turn)
  local prefix = root .. "/browser-runtime/turn-" .. tostring(turn)
  return {
    observe_input = prefix .. "-observe-input.json",
    observation = prefix .. "-observation.json",
    capabilities = prefix .. "-capabilities.json",
    act_input = prefix .. "-act-input.json",
    step_receipt = prefix .. "-step-receipt.json",
  }
end

local function title_paths(root)
  return {
    input = root .. "/browser-runtime/title-input.json",
    receipt = root .. "/browser-runtime/title-receipt.json",
    evidence = root .. "/evidence/title.json",
  }
end

local function run(ports, argv, timeout, secret_ref)
  local result
  if secret_ref ~= nil then
    if type(ports.exec_argv_with_secret_stdin) ~= "function" then
      error("testing-runtime: secret-stdin-port-unavailable: secret stdin execution port is required")
    end
    result = ports.exec_argv_with_secret_stdin(argv, secret_ref, timeout)
  else
    result = ports.exec_argv(argv, timeout)
  end
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    error("testing-runtime: browser-control-runtime-failed: exit="
      .. tostring(type(result) == "table" and result.exit_code or -1)
      .. " stderr=" .. tostring(type(result) == "table" and result.stderr or ""))
  end
end

function M.observe(context, turn, supplied_ports)
  local ports = resolve(supplied_ports)
  local runtime_paths = paths(context.artifact_root, turn)
  local input = {
    grant = context.grant,
    cdp_url = context.cdp_url,
    turn = turn,
  }
  ports.write(runtime_paths.observe_input, json_codec.encode(input) .. "\n")
  run(ports, {
    "node", runtime_cli, "observe",
    "--input", runtime_paths.observe_input,
    "--observation", runtime_paths.observation,
    "--capabilities", runtime_paths.capabilities,
  }, 30)
  local observation = ports.decode(ports.read(runtime_paths.observation))
  contract.validate_observation(observation)
  return observation, runtime_paths
end

function M.act(context, turn, action, runtime_paths, supplied_ports)
  local ports = resolve(supplied_ports)
  contract.validate_action(action, context.grant.allowed_actions, context.grant.approved_secret_refs)
  local input = {
    grant = context.grant,
    cdp_url = context.cdp_url,
    turn = turn,
    action = action,
  }
  ports.write(runtime_paths.act_input, json_codec.encode(input) .. "\n")
  run(ports, {
    "node", runtime_cli, "act",
    "--input", runtime_paths.act_input,
    "--capabilities", runtime_paths.capabilities,
    "--receipt", runtime_paths.step_receipt,
  }, 30, action.kind == "type" and action.secret_ref or nil)
  local receipt = ports.decode(ports.read(runtime_paths.step_receipt))
  contract.validate_step_receipt(receipt, context.grant)
  return receipt
end

function M.read_title(context, request, supplied_ports)
  local ports = resolve(supplied_ports)
  if type(ports.sha256) ~= "function" then error("testing-runtime: browser-control-invalid-ports: missing sha256") end
  executor_contract.validate_browser_read_title(request)
  if type(context) ~= "table" or type(context.cdp_url) ~= "string" or type(context.target_id) ~= "string"
    or type(context.target_sha256) ~= "string" or context.artifact_root ~= ".testing/runs/dedup-walking-skeleton" then
    error("testing-runtime: browser-title-context-invalid: approved Browser binding is required")
  end
  local runtime_paths = title_paths(context.artifact_root)
  ports.write(runtime_paths.input, json_codec.encode({
    schema = "testing-runtime.browser-title-input.v1",
    cdp_url = context.cdp_url,
    target_id = context.target_id,
    target_sha256 = context.target_sha256,
    request = request,
    evidence_path = runtime_paths.evidence,
  }) .. "\n")
  run(ports, { "node", runtime_cli, "read-title", "--input", runtime_paths.input, "--receipt", runtime_paths.receipt }, 30)
  local receipt = ports.decode(ports.read(runtime_paths.receipt))
  executor_contract.validate_browser_read_title_receipt(receipt)
  local evidence_bytes = ports.read(runtime_paths.evidence)
  if type(evidence_bytes) ~= "string" or #evidence_bytes ~= receipt.evidence_size_bytes
    or ports.sha256(evidence_bytes) ~= receipt.evidence_refs[1].sha256 then
    error("testing-runtime: browser-title-evidence-invalid: persisted evidence digest or size mismatch")
  end
  return receipt, runtime_paths
end

M.paths = paths
M.title_paths = title_paths

return M
