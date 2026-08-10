local design_loop = require("module_ai_design_loop")

local M = {}

local function within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function read_artifact_json(path, opts)
  local reader = opts and opts.artifact_reader
  local body
  if reader ~= nil then
    body = reader(path)
  elseif type(file) == "table" and type(file.read) == "function" then
    body = file.read(path)
  else
    local handle, err = io.open(path, "r")
    if handle == nil then error(err or "testing-runner: ai-artifact-missing") end
    body = handle:read("*a")
    handle:close()
  end
  if type(body) ~= "string" or body == "" then
    error("testing-runner: ai-artifact-missing: artifact body is empty")
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    error("testing-runner: ai-artifact-decoder-unavailable: json.decode is required")
  end
  return json.decode(body)
end

function M.load(payload, artifact_root, opts)
  local transport = design_loop.transport(payload)
  if transport.request ~= nil then
    error("testing-runner: ai-design-loop-incomplete: request must be replaced by reviewed state")
  end
  local state_ref = transport.state_ref
  if state_ref == nil then return nil end
  if type(artifact_root) ~= "string" or not within(state_ref.artifact_pointer, artifact_root) then
    error("testing-runner: ai-artifact-mismatch: design loop run binding")
  end
  local state = design_loop.validate_state(read_artifact_json(state_ref.artifact_pointer, opts))
  if design_loop.document_digest(state) ~= state_ref.artifact_digest then
    error("testing-runner: ai-artifact-mismatch: design loop state digest")
  end
  if not within(state.artifact_root, artifact_root) or state.paths.state ~= state_ref.artifact_pointer then
    error("testing-runner: ai-artifact-mismatch: design loop run binding")
  end
  local expected_paths = design_loop.paths(state.artifact_root)
  for key, expected in pairs(expected_paths) do
    if state.paths[key] ~= expected then
      error("testing-runner: ai-artifact-mismatch: design loop path binding")
    end
  end
  local expected_dedup_key = type(payload.dedup_key) == "string"
    and payload.dedup_key:gsub("/attempt/%d+$", "") or payload.dedup_key
  if payload.trace_id ~= nil and state.trace_id ~= payload.trace_id
    or expected_dedup_key ~= nil and state.dedup_key ~= expected_dedup_key then
    error("testing-runner: ai-artifact-mismatch: design loop identity binding")
  end
  local artifacts = state.current_artifacts
  local closure = type(artifacts) == "table" and artifacts.closure or nil
  local coverage = type(artifacts) == "table" and artifacts.coverage_matrix or nil
  local round_plan = type(artifacts) == "table" and artifacts.round_plan or nil
  if closure == nil or coverage == nil or round_plan == nil then
    error("testing-runner: ai-artifact-incomplete: design loop closure")
  end
  if closure.status ~= "reviewed-complete" then
    error("testing-runner: ai-artifact-incomplete: design loop closure is not reviewed-complete")
  end
  if closure.trace_id ~= state.trace_id or closure.dedup_key ~= state.dedup_key
    or closure.round_count ~= state.round or closure.final_round_digest ~= round_plan.round_digest
    or closure.coverage_matrix_pointer ~= state.paths.coverage_matrix
    or closure.coverage_matrix_digest ~= design_loop.document_digest(coverage) then
    error("testing-runner: ai-artifact-mismatch: design loop closure binding")
  end
  return state
end

return M
