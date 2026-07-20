-- contract.testing_design: immutable, pointer-only test-design analysis contracts.
local source_ref = require("contract.source_ref")
local strings = require("contract.strings")

local D = {}

D.schemas = {
  request = "testing-design.analysis-request.v1",
  result = "testing-design.analysis-result.v1",
  repository_analysis = "testing-design.repository-analysis.v1",
  requirements_index = "testing-design.requirements-index.v1",
  traceability_seed = "testing-design.traceability-seed.v1",
  artifact_reference = "testing-design.artifact-reference.v1",
  context_reference = "testing-design.context-reference.v1",
}

D.analyzer_revision = "testing-design-analyzer.v1"
D.max_inputs = 16

local max_string = 512
local max_id = 180

local input_kinds = {
  requirements = true,
  design = true,
  ["api-schema"] = true,
  ["existing-tests"] = true,
}

local artifact_schemas = {
  [D.schemas.repository_analysis] = true,
  [D.schemas.requirements_index] = true,
  [D.schemas.traceability_seed] = true,
}

local function fail(classification, message)
  error("contract.testing-design: " .. classification .. ": " .. message)
end

local function only_fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, context .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then fail("malformed-" .. context, "unsupported field " .. tostring(key)) end
  end
end

local function bounded(value, limit)
  return strings.is_bounded_string(value, limit or max_string)
    and value:find("[%z\1-\31]") == nil
end

local function dense_list(value, limit)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    if key > highest then highest = key end
  end
  return count == highest and count <= limit
end

local function require_sha256(value, field)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    fail("malformed-digest", field .. " must be a lowercase SHA-256 digest")
  end
  return value
end

local function require_commit(value, field)
  if type(value) ~= "string" or #value ~= 40 or value:match("^[0-9a-f]+$") == nil then
    fail("mutable-repository", field .. " must be a full lowercase commit object ID")
  end
  return value
end

local function validate_source(value, field)
  if not source_ref.has_bounded_source_ref(value, max_string) then
    fail("malformed-pointer", field .. " must be a bounded source_ref")
  end
  if value.kind:find("[%z\1-\31]") ~= nil or value.ref:find("[%z\1-\31]") ~= nil then
    fail("malformed-pointer", field .. " contains control characters")
  end
  local lowered = value.ref:lower()
  if lowered:find("?", 1, true) ~= nil or lowered:find("#", 1, true) ~= nil
    or lowered:match("^https?://[^/]+@") ~= nil
    or lowered:find("bearer ", 1, true) ~= nil
    or lowered:find("token=", 1, true) ~= nil
    or lowered:find("password=", 1, true) ~= nil
    or lowered:find("cookie=", 1, true) ~= nil
    or lowered:find("authorization:", 1, true) ~= nil then
    fail("credential-pointer", field .. " contains credential-bearing or mutable pointer detail")
  end
  return value
end

local function copy_source(value)
  return { kind = value.kind, ref = value.ref }
end

local function validate_repository_url(value)
  if not bounded(value, 1024) or value:match("^https://") == nil then
    fail("malformed-repository", "repository.url must be a canonical credential-free HTTPS Git URL")
  end
  if value:find("@", 1, true) ~= nil or value:find("?", 1, true) ~= nil or value:find("#", 1, true) ~= nil
    or value:find("\\", 1, true) ~= nil or value:sub(-1) == "/" then
    fail("credential-repository", "repository.url contains credentials or mutable URL detail")
  end
  return value
end

function D.validate_repository(value)
  only_fields(value, {
    url = true,
    commit_sha = true,
    baseline_commit_sha = true,
    workspace_ref = true,
    approval_ref = true,
    approval_sha256 = true,
  }, "repository")
  validate_repository_url(value.url)
  require_commit(value.commit_sha, "repository.commit_sha")
  require_commit(value.baseline_commit_sha, "repository.baseline_commit_sha")
  validate_source(value.workspace_ref, "repository.workspace_ref")
  validate_source(value.approval_ref, "repository.approval_ref")
  require_sha256(value.approval_sha256, "repository.approval_sha256")
  return value
end

function D.validate_input(value)
  only_fields(value, {
    kind = true,
    source_ref = true,
    revision = true,
    content_sha256 = true,
    approval_ref = true,
    approval_sha256 = true,
  }, "input")
  if input_kinds[value.kind] ~= true then fail("unsupported-input", "input.kind is unsupported") end
  validate_source(value.source_ref, "input.source_ref")
  if not bounded(value.revision, max_id) then fail("mutable-input", "input.revision must be an immutable bounded revision") end
  require_sha256(value.content_sha256, "input.content_sha256")
  validate_source(value.approval_ref, "input.approval_ref")
  require_sha256(value.approval_sha256, "input.approval_sha256")
  return value
end

function D.validate_browser_evidence(value)
  if value == nil then return nil end
  only_fields(value, {
    artifact_pointer = true,
    artifact_digest = true,
    approval_ref = true,
    approval_sha256 = true,
  }, "browser-evidence")
  if not strings.is_artifact_root(value.artifact_pointer, 4096) then
    fail("malformed-pointer", "browser_evidence.artifact_pointer must be under .testing/runs")
  end
  require_sha256(value.artifact_digest, "browser_evidence.artifact_digest")
  validate_source(value.approval_ref, "browser_evidence.approval_ref")
  require_sha256(value.approval_sha256, "browser_evidence.approval_sha256")
  return value
end

function D.validate_request(value)
  only_fields(value, {
    schema = true,
    repository = true,
    inputs = true,
    browser_evidence = true,
    artifact_root = true,
    source_ref = true,
    trace_id = true,
    dedup_key = true,
  }, "request")
  if value.schema ~= D.schemas.request then fail("unknown-schema", "expected " .. D.schemas.request) end
  D.validate_repository(value.repository)
  if not dense_list(value.inputs, D.max_inputs) then fail("malformed-inputs", "inputs must be a bounded dense list") end
  for _, input in ipairs(value.inputs) do D.validate_input(input) end
  D.validate_browser_evidence(value.browser_evidence)
  if not strings.is_artifact_root(value.artifact_root, 4096) then
    fail("malformed-pointer", "artifact_root must be under .testing/runs")
  end
  validate_source(value.source_ref, "source_ref")
  if not bounded(value.trace_id, max_id) or not bounded(value.dedup_key, max_id) then
    fail("malformed-identity", "trace_id and dedup_key must be bounded")
  end
  return value
end

function D.artifact_paths(artifact_root)
  if not strings.is_artifact_root(artifact_root, 4096) then fail("malformed-pointer", "artifact_root is unsafe") end
  return {
    repository_analysis = artifact_root .. "/repository-analysis.v1.json",
    requirements_index = artifact_root .. "/requirements-index.v1.json",
    traceability_seed = artifact_root .. "/traceability-seed.v1.json",
  }
end

function D.validate_artifact_reference(value, expected_schema)
  only_fields(value, {
    schema = true,
    artifact_schema = true,
    artifact_pointer = true,
    artifact_digest = true,
  }, "artifact-reference")
  if value.schema ~= D.schemas.artifact_reference then fail("unknown-schema", "artifact reference schema is invalid") end
  if artifact_schemas[value.artifact_schema] ~= true or (expected_schema ~= nil and value.artifact_schema ~= expected_schema) then
    fail("artifact-schema-mismatch", "artifact reference schema is unsupported")
  end
  if not strings.is_artifact_root(value.artifact_pointer, 4096) then fail("malformed-pointer", "artifact_pointer is unsafe") end
  require_sha256(value.artifact_digest, "artifact_digest")
  return value
end

local function copy_artifact_reference(value, expected_schema)
  D.validate_artifact_reference(value, expected_schema)
  return {
    schema = value.schema,
    artifact_schema = value.artifact_schema,
    artifact_pointer = value.artifact_pointer,
    artifact_digest = value.artifact_digest,
  }
end

function D.validate_context_reference(value)
  only_fields(value, {
    schema = true,
    analysis_key = true,
    repository_analysis = true,
    requirements_index = true,
    traceability_seed = true,
  }, "context-reference")
  if value.schema ~= D.schemas.context_reference then fail("unknown-schema", "context reference schema is invalid") end
  require_sha256(value.analysis_key, "analysis_key")
  D.validate_artifact_reference(value.repository_analysis, D.schemas.repository_analysis)
  D.validate_artifact_reference(value.requirements_index, D.schemas.requirements_index)
  D.validate_artifact_reference(value.traceability_seed, D.schemas.traceability_seed)
  return value
end

function D.copy_context_reference(value)
  D.validate_context_reference(value)
  return {
    schema = value.schema,
    analysis_key = value.analysis_key,
    repository_analysis = copy_artifact_reference(value.repository_analysis, D.schemas.repository_analysis),
    requirements_index = copy_artifact_reference(value.requirements_index, D.schemas.requirements_index),
    traceability_seed = copy_artifact_reference(value.traceability_seed, D.schemas.traceability_seed),
  }
end

function D.validate_result(value)
  only_fields(value, {
    schema = true,
    status = true,
    replayed = true,
    analysis_key = true,
    context = true,
    source_ref = true,
    trace_id = true,
    dedup_key = true,
  }, "result")
  if value.schema ~= D.schemas.result then fail("unknown-schema", "result schema is invalid") end
  if value.status ~= "complete" and value.status ~= "degraded" then fail("malformed-result", "status is invalid") end
  if type(value.replayed) ~= "boolean" then fail("malformed-result", "replayed must be boolean") end
  require_sha256(value.analysis_key, "analysis_key")
  D.validate_context_reference(value.context)
  if value.context.analysis_key ~= value.analysis_key then fail("foreign-result", "context analysis_key differs") end
  validate_source(value.source_ref, "source_ref")
  if not bounded(value.trace_id, max_id) or not bounded(value.dedup_key, max_id) then
    fail("malformed-result", "trace_id and dedup_key must be bounded")
  end
  return value
end

function D.copy_source_ref(value)
  validate_source(value, "source_ref")
  return copy_source(value)
end

return D
