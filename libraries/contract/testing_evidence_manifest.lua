-- contract.testing_evidence_manifest: canonical, pointer-only evidence manifests.
local error_facts = require("contract.error_facts")
local strings = require("contract.strings")
local time = require("contract.time")

local M = {}
M.schema = "testing-evidence-manifest.v1"
M.canonicalization = "fkst-testing-evidence-manifest-canonical-json.v1"
M.roles = { ["runner-log"] = true, screenshot = true, ["sanitized-json"] = true }
M.media_types = { ["text/plain"] = true, ["image/png"] = true, ["application/json"] = true }
M.role_media = { ["runner-log"] = { ["text/plain"] = true }, screenshot = { ["image/png"] = true }, ["sanitized-json"] = { ["application/json"] = true } }
M.sensitivities = { public = true, internal = true, restricted = true }
M.policy_statuses = { approved = true, redacted = true, withheld = true }
M.max_entries = 256

local function fail(classification, message)
  error(error_facts.error_message("contract.testing-evidence-manifest", classification, message))
end
local function bounded(value, field, limit)
  if type(value) ~= "string" or value == "" or #value > (limit or 512) or value:find("[%z\1-\31]") ~= nil then fail("malformed-field", field .. " must be a bounded string") end
  return value
end
local function fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, "must be a table") end
  for key in pairs(value) do if allowed[key] ~= true then fail("malformed-" .. context, "unsupported field " .. tostring(key)) end end
end
local function list(value, field, limit, required)
  if type(value) ~= "table" then fail("malformed-list", field .. " must be a list") end
  local highest, count = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then fail("malformed-list", field .. " must be dense") end
    highest, count = math.max(highest, key), count + 1
  end
  if count ~= highest or count > limit or (required and count == 0) then fail("malformed-list", field .. " has an invalid size") end
  return value
end
local function digest(value, field)
  if type(value) ~= "string" or not value:match("^[0-9a-f][0-9a-f]*$") or #value ~= 64 then fail("malformed-digest", field .. " must be lowercase SHA-256") end
  return value
end
local function reference(value, field)
  fields(value, { kind = true, ref = true }, field)
  bounded(value.kind, field .. ".kind", 96); bounded(value.ref, field .. ".ref", 4096)
end
local function same_reference(left, right)
  return left.kind == right.kind and left.ref == right.ref
end
local function artifact_root(context)
  if context == nil then return nil end
  fields(context, { artifact_root=true }, "context")
  if not strings.is_artifact_descendant(context.artifact_root .. "/artifact", context.artifact_root) then fail("invalid-context", "artifact_root must be a safe .testing/runs/... root") end
  return context.artifact_root
end
local function relative_run_pointer(value, run_id, field, root)
  reference(value, field)
  if root ~= nil then
    if value.kind ~= "artifact" or not strings.is_artifact_descendant(value.ref, root) then fail("cross-run-pointer", field .. " is outside the artifact root") end
    return
  end
  if value.kind ~= "artifact" or value.ref:sub(1, 1) == "/" or value.ref:match("^[A-Za-z]:") or value.ref:find("..", 1, true) then fail("invalid-pointer", field .. " must be a relative artifact pointer") end
  if not value.ref:find("/" .. run_id .. "/", 1, true) and value.ref:sub(-#run_id - 1) ~= "/" .. run_id then fail("cross-run-pointer", field .. " is outside the manifest run") end
end
local function canonical_json(value, omit_canonical_sha256)
  local kind = type(value)
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then if value ~= math.floor(value) then fail("canonicalization", "only integers are supported") end; return tostring(value) end
  if kind == "string" then return strings.json_string(value) end
  if kind ~= "table" then fail("canonicalization", "unsupported value type " .. kind) end
  local numeric, keys = 0, {}
  for key in pairs(value) do if type(key) == "number" then numeric = numeric + 1 else table.insert(keys, key) end end
  if numeric > 0 or next(value) == nil then local parts = {}; for _, item in ipairs(value) do table.insert(parts, canonical_json(item, false)) end; return "[" .. table.concat(parts, ",") .. "]" end
  table.sort(keys); local parts = {}
  for _, key in ipairs(keys) do if not omit_canonical_sha256 or key ~= "canonical_sha256" then table.insert(parts, strings.json_string(key) .. ":" .. canonical_json(value[key], false)) end end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function validate_entry(entry, run_id, case_ids, assertion_ids, seen, enforce_result_refs, root)
  fields(entry, { evidence_id=true, case_id=true, assertion_id=true, role=true, artifact_ref=true, sha256=true, media_type=true, size_bytes=true, producer=true, producer_version=true, created_at=true, sensitivity=true, redaction_classification=true, policy_version=true, policy_status=true, provenance=true }, "manifest-entry")
  bounded(entry.evidence_id, "entry.evidence_id", 180); bounded(entry.case_id, "entry.case_id", 180)
  if seen[entry.evidence_id] then fail("duplicate-evidence-id", entry.evidence_id) end; seen[entry.evidence_id] = entry
  if enforce_result_refs and not case_ids[entry.case_id] then fail("foreign-case", entry.case_id) end
  if entry.assertion_id ~= nil then
    bounded(entry.assertion_id, "entry.assertion_id", 180)
    if enforce_result_refs and (not assertion_ids[entry.case_id] or not assertion_ids[entry.case_id][entry.assertion_id]) then fail("foreign-assertion", entry.assertion_id) end
  end
  bounded(entry.role, "entry.role", 64); if not M.roles[entry.role] then fail("unsupported-role", entry.role) end
  relative_run_pointer(entry.artifact_ref, run_id, "entry.artifact_ref", root); digest(entry.sha256, "entry.sha256")
  bounded(entry.media_type, "entry.media_type", 120); if not M.media_types[entry.media_type] or not M.role_media[entry.role][entry.media_type] then fail("unsupported-media", entry.media_type) end
  if type(entry.size_bytes) ~= "number" or entry.size_bytes ~= math.floor(entry.size_bytes) or entry.size_bytes < 0 or entry.size_bytes > 1000000000 then fail("malformed-field", "entry.size_bytes must be a bounded byte count") end
  bounded(entry.producer, "entry.producer", 180); bounded(entry.producer_version, "entry.producer_version", 96); bounded(entry.created_at, "entry.created_at", 40)
  if time.iso_timestamp_epoch_seconds(entry.created_at) == nil then fail("malformed-time", "entry.created_at must be a UTC ISO timestamp") end
  bounded(entry.sensitivity, "entry.sensitivity", 32); if not M.sensitivities[entry.sensitivity] then fail("unsupported-sensitivity", entry.sensitivity) end
  bounded(entry.redaction_classification, "entry.redaction_classification", 64); bounded(entry.policy_version, "entry.policy_version", 96); bounded(entry.policy_status, "entry.policy_status", 32); if not M.policy_statuses[entry.policy_status] then fail("unsupported-policy-status", entry.policy_status) end
  fields(entry.provenance, { source_kind=true, source_ref=true, source_sha256=true }, "provenance"); bounded(entry.provenance.source_kind, "entry.provenance.source_kind", 96); bounded(entry.provenance.source_ref, "entry.provenance.source_ref", 4096); digest(entry.provenance.source_sha256, "entry.provenance.source_sha256")
  if entry.provenance.source_kind == "artifact" and (entry.provenance.source_ref ~= entry.artifact_ref.ref or entry.provenance.source_sha256 ~= entry.sha256 or (root ~= nil and not strings.is_artifact_descendant(entry.provenance.source_ref, root))) then fail("foreign-provenance", "artifact provenance must identify the entry artifact and digest") end
end

function M.validate(value, result_set, sha256_fn, context)
  local root = artifact_root(context)
  fields(value, { schema=true, manifest_id=true, canonicalization=true, canonical_sha256=true, repository=true, run_id=true, plan_ref=true, plan_sha256=true, entries=true }, "manifest")
  if value.schema ~= M.schema then fail("unknown-schema", "manifest schema") end
  bounded(value.manifest_id, "manifest_id", 180); if value.canonicalization ~= M.canonicalization then fail("unknown-canonicalization", "manifest canonicalization") end
  digest(value.canonical_sha256, "canonical_sha256"); fields(value.repository, { id=true, source_ref=true, source_sha256=true }, "repository"); bounded(value.repository.id, "repository.id", 180); reference(value.repository.source_ref, "repository.source_ref"); digest(value.repository.source_sha256, "repository.source_sha256")
  bounded(value.run_id, "run_id", 180); reference(value.plan_ref, "plan_ref"); digest(value.plan_sha256, "plan_sha256"); list(value.entries, "entries", M.max_entries, true)
  if root ~= nil and (value.plan_ref.kind ~= "artifact" or value.plan_ref.ref ~= root .. "/test-plan.json") then fail("cross-run-pointer", "manifest plan_ref is outside the artifact root") end
  local case_ids, assertion_ids = {}, {}
  if result_set ~= nil then
    if value.run_id ~= result_set.run_id or value.plan_sha256 ~= result_set.plan_sha256 or not same_reference(value.plan_ref, result_set.plan_ref) then fail("foreign-result-set", "manifest identity does not match result set") end
    if root ~= nil and (result_set.plan_ref.kind ~= "artifact" or result_set.plan_ref.ref ~= root .. "/test-plan.json" or result_set.plan_ref.sha256 ~= nil) then fail("foreign-result-set", "result set plan_ref is outside the artifact root") end
    if root ~= nil and (result_set.evidence_manifest_ref.kind ~= "artifact" or result_set.evidence_manifest_ref.ref ~= root .. "/evidence-manifest.json") then fail("foreign-result-set", "result set manifest reference is outside the artifact root") end
    for _, case in ipairs(result_set.cases) do
      case_ids[case.case_id] = true
      assertion_ids[case.case_id] = {}
      for _, assertion in ipairs(case.assertions) do assertion_ids[case.case_id][assertion.assertion_id] = true end
      if case.repository.id ~= value.repository.id or case.repository.source_sha256 ~= value.repository.source_sha256 or not same_reference(case.repository.source_ref, value.repository.source_ref) then fail("foreign-repository", case.case_id) end
    end
  end
  local seen = {}; for _, entry in ipairs(value.entries) do validate_entry(entry, value.run_id, case_ids, assertion_ids, seen, result_set ~= nil, root) end
  if result_set ~= nil then
    local referenced = {}
    local function check_refs(refs, owner, case_id, assertion_id)
      if type(refs) ~= "table" then fail("malformed-evidence-refs", owner .. " must be a list") end
      for _, ref in ipairs(refs) do
        reference(ref, owner .. ".evidence_ref")
        local entry = ref.kind == "evidence" and seen[ref.ref] or nil
        if entry == nil then fail("missing-entry", owner .. " references an unknown evidence entry") end
        if entry.case_id ~= case_id then fail("foreign-case", owner .. " references evidence from another case") end
        if assertion_id ~= nil and entry.assertion_id ~= nil and entry.assertion_id ~= assertion_id then
          fail("foreign-assertion", owner .. " references evidence from another assertion")
        end
        referenced[ref.ref] = true
      end
    end
    for _, case in ipairs(result_set.cases) do
      check_refs(case.evidence_refs, "case " .. case.case_id, case.case_id)
      for _, observation in ipairs(case.observations) do
        check_refs(observation.evidence_refs, "observation " .. observation.observation_id, case.case_id)
      end
      for _, assertion in ipairs(case.assertions) do
        check_refs(assertion.evidence_refs, "assertion " .. assertion.assertion_id,
          case.case_id, assertion.assertion_id)
      end
    end
  end
  if sha256_fn ~= nil then if type(sha256_fn) ~= "function" then fail("missing-sha256", "SHA-256 function must be callable") end; local ok, computed = pcall(sha256_fn, canonical_json(value, true)); if not ok then fail("sha256-failed", "SHA-256 function failed") end; if computed ~= value.canonical_sha256 then fail("digest-mismatch", "canonical manifest digest does not match") end end
  return value
end
function M.canonicalize(value, context) M.validate(value, nil, nil, context); return canonical_json(value, true) end
function M.serialize(value, context) M.validate(value, nil, nil, context); return canonical_json(value, false) end
function M.sha256(value, sha256_fn, context) if type(sha256_fn) ~= "function" then fail("missing-sha256", "a host-supplied SHA-256 function is required") end; M.validate(value, nil, nil, context); local ok, result = pcall(sha256_fn, canonical_json(value, true)); if not ok then fail("sha256-failed", "the host SHA-256 function failed") end; digest(result, "sha256 result"); return result end
return M
