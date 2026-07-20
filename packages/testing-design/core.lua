local contract = require("contract.testing_design")
local ports_module = require("ports")

local M = {}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out, key, item = {}, next(value)
  while key ~= nil do
    out[copy(key)] = copy(item)
    key, item = next(value, key)
  end
  return out
end

local function validate_outcome(value)
  if type(value) ~= "table" then error("testing-design: malformed-runtime-outcome: outcome must be a table") end
  local allowed = {
    status = true,
    replayed = true,
    analysis_key = true,
    context = true,
  }
  for key, _ in pairs(value) do
    if allowed[key] ~= true then error("testing-design: malformed-runtime-outcome: unsupported field") end
  end
  return {
    schema = contract.schemas.result,
    status = value.status,
    replayed = value.replayed,
    analysis_key = value.analysis_key,
    context = copy(value.context),
    source_ref = { kind = "testing-design-analysis", ref = value.analysis_key },
    trace_id = "pending",
    dedup_key = "pending",
  }
end

function M.analyze(request, supplied_ports)
  contract.validate_request(request)
  local result = validate_outcome(ports_module.resolve(supplied_ports).analyze(copy(request)))
  result.source_ref = contract.copy_source_ref(request.source_ref)
  result.trace_id = request.trace_id
  result.dedup_key = request.dedup_key
  return contract.validate_result(result)
end

local function fake_digest(char)
  return string.rep(char, 64)
end

local function fake_reference(schema, path, char)
  return {
    schema = contract.schemas.artifact_reference,
    artifact_schema = schema,
    artifact_pointer = path,
    artifact_digest = fake_digest(char),
  }
end

function M.saga_conformance_errors()
  local root = ".testing/runs/testing-design-conformance"
  local request = {
    schema = contract.schemas.request,
    repository = {
      url = "https://example.invalid/testing-design.git",
      commit_sha = string.rep("a", 40),
      baseline_commit_sha = string.rep("b", 40),
      workspace_ref = { kind = "workspace", ref = "/approved/testing-design" },
      approval_ref = { kind = "artifact", ref = ".testing/approvals/testing-design-repository.json" },
      approval_sha256 = fake_digest("c"),
    },
    inputs = {},
    artifact_root = root,
    source_ref = { kind = "host-run", ref = "testing-design-conformance" },
    trace_id = "trace-testing-design-conformance",
    dedup_key = "dedup-testing-design-conformance",
  }
  local key = fake_digest("d")
  local ok, result = pcall(M.analyze, request, {
    analyze = function()
      return {
        status = "degraded",
        replayed = false,
        analysis_key = key,
        context = {
          schema = contract.schemas.context_reference,
          analysis_key = key,
          repository_analysis = fake_reference(contract.schemas.repository_analysis, root .. "/repository-analysis.v1.json", "e"),
          requirements_index = fake_reference(contract.schemas.requirements_index, root .. "/requirements-index.v1.json", "f"),
          traceability_seed = fake_reference(contract.schemas.traceability_seed, root .. "/traceability-seed.v1.json", "1"),
        },
      }
    end,
  })
  if not ok then return { { id = "testing-design.saga.analyze", message = tostring(result) } } end
  return {}
end

return M
