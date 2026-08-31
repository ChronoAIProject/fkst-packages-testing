-- contract.testing_design: immutable, pointer-only test-design analysis contracts.
local error_facts = require("contract.error_facts")
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
  pql_input_set = "pql.testing-design-input-set.v1",
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
  error(error_facts.error_message("contract.testing-design", classification, message))
end

local function only_fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, context .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then fail("malformed-" .. context, "unsupported field " .. tostring(key)) end
  end
end

local function bounded(value, limit)
  return strings.is_bounded_string(value, limit or max_string)
    and value:find("[%z\1-\31\127]") == nil
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

local function validate_pql_identity(value, field)
  if not bounded(value, max_id) then fail("malformed-identity", field .. " must be bounded") end
end

local function validate_pql_pointer(value, field)
  validate_source(value, field)
end

local function validate_pql_artifact_pointer(value, field)
  validate_pql_pointer(value, field)
  if value.kind ~= "artifact" then
    fail("malformed-pql-envelope", field .. ".kind must be artifact")
  end
  local normalized = value.ref:gsub("\\", "/")
  if normalized == ".." or normalized:match("^%.%./") ~= nil
    or normalized:match("/%.%./") ~= nil or normalized:match("/%.%.$") ~= nil then
    fail("malformed-pql-envelope", field .. ".ref must not contain traversal segments")
  end
end

local function validate_pql_requirement_ref(value, field)
  validate_pql_pointer(value, field)
end

local function validate_pql_digest(value, field)
  require_sha256(value, field)
end

local function validate_pql_subject(value, field)
  only_fields(value, {
    consumer = true,
    repository_url = true,
    repository_commit_sha = true,
    project_pack_snapshot_ref = true,
    project_pack_snapshot_sha256 = true,
    asset_id = true,
    asset_version = true,
    asset_sha256 = true,
  }, field)
  if value.consumer ~= "testing-design" then fail("foreign-pql-binding", field .. ".consumer is invalid") end
  validate_repository_url(value.repository_url)
  require_commit(value.repository_commit_sha, field .. ".repository_commit_sha")
  validate_pql_artifact_pointer(value.project_pack_snapshot_ref, field .. ".project_pack_snapshot_ref")
  validate_pql_digest(value.project_pack_snapshot_sha256, field .. ".project_pack_snapshot_sha256")
  validate_pql_identity(value.asset_id, field .. ".asset_id")
  validate_pql_identity(value.asset_version, field .. ".asset_version")
  validate_pql_digest(value.asset_sha256, field .. ".asset_sha256")
end

local function validate_pql_requirement_refs(value, field)
  if not dense_list(value, 32) or #value == 0 then fail("malformed-pql-envelope", field .. " must be a non-empty dense list") end
  for index, item in ipairs(value) do
    only_fields(item, { kind = true, ref = true }, field .. "[" .. index .. "]")
    validate_pql_requirement_ref(item, field .. "[" .. index .. "]")
  end
end

local function validate_pql_asset(value, index)
  local field = "pql_input_set.approved_assets[" .. index .. "]"
  only_fields(value, {
    asset_id = true, asset_version = true, asset_kind = true, artifact_pointer = true,
    artifact_digest = true, media_type = true, requirement_refs = true,
    review_decision = true, promotion_receipt = true, approval_subject = true,
  }, field)
  validate_pql_identity(value.asset_id, field .. ".asset_id")
  validate_pql_identity(value.asset_version, field .. ".asset_version")
  if value.asset_kind ~= "test-case" then fail("unsupported-pql-asset", field .. ".asset_kind is unsupported") end
  validate_pql_artifact_pointer(value.artifact_pointer, field .. ".artifact_pointer")
  validate_pql_digest(value.artifact_digest, field .. ".artifact_digest")
  if value.media_type ~= "text/plain; charset=utf-8" then fail("unsupported-pql-asset", field .. ".media_type is unsupported") end
  validate_pql_requirement_refs(value.requirement_refs, field .. ".requirement_refs")
  for _, relation in ipairs({ "review_decision", "promotion_receipt" }) do
    only_fields(value[relation], { ref = true, sha256 = true }, field .. "." .. relation)
    validate_pql_artifact_pointer(value[relation].ref, field .. "." .. relation .. ".ref")
    validate_pql_digest(value[relation].sha256, field .. "." .. relation .. ".sha256")
  end
  validate_pql_subject(value.approval_subject, field .. ".approval_subject")
end

function D.validate_pql_input_set(value, request)
  only_fields(value, {
    schema = true, producer = true, asset_set_id = true, repository = true,
    project_pack_snapshot = true, approved_assets = true, created_at = true,
    trace_id = true, dedup_key = true,
  }, "pql-input-set")
  if value.schema ~= D.schemas.pql_input_set then fail("unknown-schema", "pql input set schema is invalid") end
  only_fields(value.producer, { name = true, version = true }, "pql-input-set.producer")
  if value.producer.name ~= "product-quality-loop" or value.producer.version ~= "pql.testing-design-fixture.v1" then
    fail("unsupported-pql-producer", "pql input set producer is unsupported")
  end
  validate_pql_identity(value.asset_set_id, "pql_input_set.asset_set_id")
  only_fields(value.repository, { url = true, commit_sha = true }, "pql-input-set.repository")
  validate_repository_url(value.repository.url)
  require_commit(value.repository.commit_sha, "pql_input_set.repository.commit_sha")
  if request ~= nil then
    if value.repository.url ~= request.repository.url or value.repository.commit_sha ~= request.repository.commit_sha then
      fail("foreign-pql-binding", "pql input set repository differs from request")
    end
    if value.trace_id ~= request.trace_id or value.dedup_key ~= request.dedup_key then
      fail("foreign-pql-binding", "pql input set identity differs from request")
    end
  end
  only_fields(value.project_pack_snapshot, { ref = true, sha256 = true }, "pql-input-set.project-pack-snapshot")
  validate_pql_artifact_pointer(value.project_pack_snapshot.ref, "pql_input_set.project_pack_snapshot.ref")
  validate_pql_digest(value.project_pack_snapshot.sha256, "pql_input_set.project_pack_snapshot.sha256")
  if not dense_list(value.approved_assets, 16) or #value.approved_assets == 0 then
    fail("malformed-pql-envelope", "pql_input_set.approved_assets must contain 1 to 16 assets")
  end
  local identities = {}
  for index, asset in ipairs(value.approved_assets) do
    validate_pql_asset(asset, index)
    local identity = asset.asset_id .. "\0" .. asset.asset_version
    if identities[identity] then fail("duplicate-pql-asset", "pql asset identity is duplicated") end
    identities[identity] = true
  end
  if type(value.created_at) ~= "string" then
    fail("malformed-identity", "pql_input_set.created_at must be an RFC 3339 UTC timestamp")
  end
  local year, month, day, hour, minute, second = value.created_at:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  local month_days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if year == nil then
    fail("malformed-identity", "pql_input_set.created_at must be an RFC 3339 UTC timestamp")
  end
  local leap = tonumber(year) % 4 == 0 and (tonumber(year) % 100 ~= 0 or tonumber(year) % 400 == 0)
  if tonumber(month) < 1 or tonumber(month) > 12 or tonumber(day) < 1
    or tonumber(day) > month_days[tonumber(month)] + ((tonumber(month) == 2 and leap) and 1 or 0)
    or tonumber(hour) > 23 or tonumber(minute) > 59 or tonumber(second) > 59 then
    fail("malformed-identity", "pql_input_set.created_at must be an RFC 3339 UTC timestamp")
  end
  validate_pql_identity(value.trace_id, "pql_input_set.trace_id")
  validate_pql_identity(value.dedup_key, "pql_input_set.dedup_key")
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
    pql_input_set = true,
    artifact_root = true,
    source_ref = true,
    trace_id = true,
    dedup_key = true,
  }, "request")
  if value.schema ~= D.schemas.request then fail("unknown-schema", "expected " .. D.schemas.request) end
  D.validate_repository(value.repository)
  if not dense_list(value.inputs, D.max_inputs) then fail("malformed-inputs", "inputs must be a bounded dense list") end
  for _, input in ipairs(value.inputs) do D.validate_input(input) end
  if value.pql_input_set ~= nil then D.validate_pql_input_set(value.pql_input_set, value) end
  if #value.inputs + (value.pql_input_set and #value.pql_input_set.approved_assets or 0) > D.max_inputs then
    fail("malformed-inputs", "inputs and pql_input_set exceed the maximum input count")
  end
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
