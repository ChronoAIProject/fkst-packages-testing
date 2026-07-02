local W = {}

local evidence = require("planning_evidence")
local json = require("planning_json")
local projector = require("planning_projector")
local strings = require("contract.strings")

local function quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function write_file(path, body)
  if not strings.is_path_safe_key(path, 4096) then return nil, "unsafe artifact path" end
  local dir = path:match("^(.*)/[^/]+$")
  if dir == nil then return nil, "missing artifact directory" end
  local ok = os.execute("mkdir -p " .. quote(dir))
  if ok ~= true and ok ~= 0 then return nil, "failed to create artifact directory" end
  local file, err = io.open(path, "w")
  if file == nil then return nil, err or "failed to open artifact file" end
  local wrote, write_err = file:write(body)
  file:close()
  if not wrote then return nil, write_err or "failed to write artifact file" end
  return true
end

function W.pointers(payload, request)
  if not evidence.has_payload(payload) then return nil end
  local root = evidence.artifact_root(payload, request)
  return {
    schema = "testing-pipeline.planning-artifacts.v1",
    artifact_root = root,
    feature_inventory_path = root .. "/feature-inventory.json",
    test_plan_path = root .. "/test-plan.json",
  }
end

function W.write(payload, request)
  local pointers = W.pointers(payload, request)
  if pointers == nil then return nil end
  local inventory, plan = projector.project(payload, request)
  local writer = type(payload.artifact_writer) == "function" and payload.artifact_writer or write_file
  local ok, err = writer(pointers.feature_inventory_path, json.encode(inventory) .. "\n")
  if not ok then error("testing-pipeline: artifact-write-failed: " .. tostring(err)) end
  ok, err = writer(pointers.test_plan_path, json.encode(plan) .. "\n")
  if not ok then error("testing-pipeline: artifact-write-failed: " .. tostring(err)) end
  return pointers
end

return W
