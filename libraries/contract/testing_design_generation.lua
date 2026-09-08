local canonical_json = require("contract.canonical_json")
local sha256 = require("contract.sha256")

local G = {
  schemas = {
    request = "testing-design.generate-request.v1",
    candidate_set = "testing-design.candidate-test-case-set.v1",
    receipt = "testing-design.generation-receipt.v1",
    artifact_reference = "testing-design.artifact-reference.v1",
  },
}

local function fail(code, message)
  error("contract.testing_design_generation: " .. code .. ": " .. message, 0)
end

local function only_fields(value, allowed, field, code)
  if type(value) ~= "table" then fail(code or "malformed-document", field .. " must be an object") end
  for key in pairs(value) do
    if type(key) ~= "string" or not allowed[key] then fail(code or "malformed-document", field .. " contains an unknown field") end
  end
  for key in pairs(allowed) do
    if value[key] == nil then fail(code or "malformed-document", field .. "." .. key .. " is required") end
  end
end

local function dense_list(value, minimum, maximum, field, code)
  if type(value) ~= "table" then fail(code, field .. " must be an array") end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then fail(code, field .. " must be a dense array") end
    count = count + 1
  end
  if count < minimum or count > maximum then fail(code, field .. " has an invalid length") end
  for index = 1, count do if value[index] == nil then fail(code, field .. " must be a dense array") end end
  return count
end

local function bounded(value, maximum)
  return type(value) == "string" and #value >= 1 and #value <= maximum
    and value:find("[%z\1-\31\127]") == nil
end

local function require_bounded(value, maximum, field, code)
  if not bounded(value, maximum) then fail(code, field .. " must be a bounded string") end
end

local function require_sha(value, field, code)
  if type(value) ~= "string" or not value:match("^[0-9a-f]+$") or #value ~= 64 then fail(code, field .. " must be lowercase SHA-256") end
end

local function require_semver(value, field, code)
  if type(value) ~= "string" or not value:match("^%d+%.%d+%.%d+$") then fail(code, field .. " must be semantic major.minor.patch") end
end

local function safe_pointer(value, maximum)
  return bounded(value, maximum) and value:sub(1, 1) ~= "/" and not value:find("[\\%?#@]")
    and not value:match("^%.%./") and not value:match("/%.%./") and not value:match("/%.%.$")
end

local function validate_artifact(value, expected_schema, field, code)
  only_fields(value, { schema = true, artifact_schema = true, artifact_pointer = true, artifact_digest = true }, field, code)
  if value.schema ~= G.schemas.artifact_reference or value.artifact_schema ~= expected_schema then fail(code, field .. " has an invalid schema") end
  if not safe_pointer(value.artifact_pointer, 512) then fail(code, field .. ".artifact_pointer is unsafe") end
  require_sha(value.artifact_digest, field .. ".artifact_digest", code)
end

local function validate_catalog(value, field)
  only_fields(value, { catalog_id = true, catalog_version = true, catalog_digest = true }, field, "malformed-request")
  require_bounded(value.catalog_id, 180, field .. ".catalog_id", "malformed-request")
  require_semver(value.catalog_version, field .. ".catalog_version", "malformed-request")
  require_sha(value.catalog_digest, field .. ".catalog_digest", "malformed-request")
end

local function validate_prompt(value, field, code)
  only_fields(value, { template_id = true, template_version = true, template_digest = true }, field, code)
  require_bounded(value.template_id, 180, field .. ".template_id", code)
  require_semver(value.template_version, field .. ".template_version", code)
  require_sha(value.template_digest, field .. ".template_digest", code)
end

function G.canonical_bytes(value)
  return canonical_json.encode(value) .. "\n"
end

function G.canonical_digest(value)
  return sha256.hex(G.canonical_bytes(value))
end

function G.validate_request(value)
  only_fields(value, { schema = true, repository = true, analysis = true, existing_test_inventory = true, allowed_catalogs = true, prompt_template = true, policy = true, artifact_root = true, trace_id = true, dedup_key = true }, "request", "malformed-request")
  if value.schema ~= G.schemas.request then fail("unknown-schema", "request schema is invalid") end
  only_fields(value.repository, { url = true, target_commit = true, worktree = true }, "request.repository", "malformed-request")
  if not bounded(value.repository.url, 1024) or not value.repository.url:match("^https://") or value.repository.url:find("[\\%?#@]") or value.repository.url:sub(-1) == "/" then fail("malformed-request", "repository.url is unsafe") end
  if type(value.repository.target_commit) ~= "string" or #value.repository.target_commit ~= 40 or not value.repository.target_commit:match("^[0-9a-f]+$") then fail("malformed-request", "target_commit is invalid") end
  only_fields(value.repository.worktree, { kind = true, ref = true }, "request.repository.worktree", "malformed-request")
  if value.repository.worktree.kind ~= "approved-worktree" or not safe_pointer(value.repository.worktree.ref, 512) then fail("malformed-request", "worktree is invalid") end
  only_fields(value.analysis, { repository_analysis = true, requirements_index = true, traceability_seed = true }, "request.analysis", "malformed-request")
  validate_artifact(value.analysis.repository_analysis, "testing-design.repository-analysis.v1", "request.analysis.repository_analysis", "malformed-request")
  validate_artifact(value.analysis.requirements_index, "testing-design.requirements-index.v1", "request.analysis.requirements_index", "malformed-request")
  validate_artifact(value.analysis.traceability_seed, "testing-design.traceability-seed.v1", "request.analysis.traceability_seed", "malformed-request")
  validate_artifact(value.existing_test_inventory, "testing-design.existing-test-inventory.v1", "request.existing_test_inventory", "malformed-request")
  only_fields(value.allowed_catalogs, { actions = true, assertions = true }, "request.allowed_catalogs", "malformed-request")
  validate_catalog(value.allowed_catalogs.actions, "request.allowed_catalogs.actions")
  validate_catalog(value.allowed_catalogs.assertions, "request.allowed_catalogs.assertions")
  validate_prompt(value.prompt_template, "request.prompt_template", "malformed-request")
  only_fields(value.policy, { policy_id = true, max_candidates = true, max_steps_per_candidate = true, max_prompt_bytes = true, max_response_bytes = true, timeout_ms = true }, "request.policy", "malformed-request")
  if value.policy.policy_id ~= "testing-design.generation-policy.v1" then fail("malformed-request", "policy_id is invalid") end
  local limits = { max_candidates = 64, max_steps_per_candidate = 32, max_prompt_bytes = 1048576, max_response_bytes = 1048576, timeout_ms = 300000 }
  for key, maximum in pairs(limits) do if type(value.policy[key]) ~= "number" or value.policy[key] ~= math.floor(value.policy[key]) or value.policy[key] < 1 or value.policy[key] > maximum then fail("malformed-request", key .. " is invalid") end end
  if not bounded(value.artifact_root, 512) or not value.artifact_root:match("^%.testing/runs/") or value.artifact_root:sub(-1) == "/" or value.artifact_root:find("[\\%?#]") or value.artifact_root:find("%.%.") then fail("malformed-request", "artifact_root is unsafe") end
  require_bounded(value.trace_id, 180, "trace_id", "malformed-request")
  require_bounded(value.dedup_key, 180, "dedup_key", "malformed-request")
  return value
end

local function validate_trace_ref(value, field)
  only_fields(value, { kind = true, ref = true, sha256 = true }, field, "invalid-traceability")
  require_bounded(value.kind, 180, field .. ".kind", "invalid-traceability")
  require_bounded(value.ref, 180, field .. ".ref", "invalid-traceability")
  if value.ref:match("^https?://") or value.ref:find("[%?#]") or value.ref == "main" or value.ref == "master" or value.ref:match("^refs/heads/") or value.ref:match("^refs/tags/") then fail("invalid-traceability", field .. ".ref is mutable") end
  require_sha(value.sha256, field .. ".sha256", "invalid-traceability")
end

local function validate_candidate(candidate, request, index)
  local field = "candidate_set.candidates[" .. index .. "]"
  only_fields(candidate, { candidate_id = true, title = true, kind = true, status = true, preconditions = true, steps = true, evidence_requirements = true, traceability = true }, field, "malformed-candidate")
  require_bounded(candidate.candidate_id, 180, field .. ".candidate_id", "malformed-candidate")
  require_bounded(candidate.title, 300, field .. ".title", "malformed-candidate")
  if candidate.kind ~= "browser-smoke" then fail("unsupported-candidate-kind", field .. ".kind is unsupported") end
  if candidate.status ~= "candidate" then fail("unsupported-candidate-status", field .. ".status is unsupported") end
  dense_list(candidate.preconditions, 0, 16, field .. ".preconditions", "malformed-candidate")
  for item_index, item in ipairs(candidate.preconditions) do
    only_fields(item, { kind = true, ref = true }, field .. ".preconditions[" .. item_index .. "]", "malformed-candidate")
    if item.kind ~= "application-base-url" or item.ref ~= "application.base_url" then fail("malformed-candidate", "precondition is unsupported") end
  end
  dense_list(candidate.steps, 1, request.policy.max_steps_per_candidate, field .. ".steps", "malformed-candidate")
  local step_ids = {}
  for step_index, step in ipairs(candidate.steps) do
    local step_field = field .. ".steps[" .. step_index .. "]"
    only_fields(step, { step_id = true, action = true, assertion = true }, step_field, "malformed-candidate")
    require_bounded(step.step_id, 180, step_field .. ".step_id", "malformed-candidate")
    if step_ids[step.step_id] then fail("duplicate-step-id", "step_id is duplicated") end
    step_ids[step.step_id] = true
    only_fields(step.action, { catalog_id = true, catalog_version = true, action_id = true, target = true }, step_field .. ".action", "malformed-action")
    if step.action.catalog_id ~= request.allowed_catalogs.actions.catalog_id or step.action.catalog_version ~= request.allowed_catalogs.actions.catalog_version or step.action.action_id ~= "browser.navigate.v1" then fail("unsupported-action", "action is not allowlisted") end
    only_fields(step.action.target, { kind = true, ref = true }, step_field .. ".action.target", "malformed-action")
    if step.action.target.kind ~= "route" or not bounded(step.action.target.ref, 512) or step.action.target.ref:sub(1, 1) ~= "/" or step.action.target.ref:match("^//") or step.action.target.ref:find("[^%w%._~%%/%-]") then fail("malformed-action", "route target is unsafe") end
    only_fields(step.assertion, { catalog_id = true, catalog_version = true, assertion_id = true, expected = true }, step_field .. ".assertion", "malformed-assertion")
    if step.assertion.catalog_id ~= request.allowed_catalogs.assertions.catalog_id or step.assertion.catalog_version ~= request.allowed_catalogs.assertions.catalog_version or step.assertion.assertion_id ~= "browser.title.equals.v1" then fail("unsupported-assertion", "assertion is not allowlisted") end
    require_bounded(step.assertion.expected, 300, step_field .. ".assertion.expected", "malformed-assertion")
  end
  dense_list(candidate.evidence_requirements, 0, 16, field .. ".evidence_requirements", "malformed-candidate")
  for evidence_index, item in ipairs(candidate.evidence_requirements) do
    only_fields(item, { kind = true, when = true, step_id = true }, field .. ".evidence_requirements[" .. evidence_index .. "]", "malformed-candidate")
    if item.kind ~= "browser-screenshot" or item.when ~= "after-step" or not step_ids[item.step_id] then fail("foreign-step-reference", "evidence step_id is invalid") end
  end
  only_fields(candidate.traceability, { requirement_refs = true, journey_refs = true, risk_refs = true, source_refs = true, existing_test_refs = true }, field .. ".traceability", "invalid-traceability")
  local source_bindings = {}
  for _, artifact in pairs({ request.analysis.repository_analysis, request.analysis.requirements_index, request.analysis.traceability_seed, request.existing_test_inventory }) do source_bindings[artifact.artifact_pointer .. "\0" .. artifact.artifact_digest] = true end
  for _, key in ipairs({ "requirement_refs", "journey_refs", "risk_refs", "source_refs", "existing_test_refs" }) do
    local minimum = (key == "requirement_refs" or key == "source_refs") and 1 or 0
    dense_list(candidate.traceability[key], minimum, 32, field .. ".traceability." .. key, "invalid-traceability")
    for ref_index, ref in ipairs(candidate.traceability[key]) do
      validate_trace_ref(ref, field .. ".traceability." .. key .. "[" .. ref_index .. "]")
      if key == "source_refs" and not source_bindings[ref.ref .. "\0" .. ref.sha256] then fail("foreign-traceability", "source reference is not request-bound") end
      if key == "existing_test_refs" and (ref.ref ~= request.existing_test_inventory.artifact_pointer or ref.sha256 ~= request.existing_test_inventory.artifact_digest) then fail("foreign-traceability", "existing test reference is not request-bound") end
    end
  end
end

function G.validate_candidate_set(value, request)
  G.validate_request(request)
  only_fields(value, { schema = true, candidate_set_id = true, request_digest = true, status = true, candidates = true }, "candidate_set", "malformed-candidate-set")
  if value.schema ~= G.schemas.candidate_set then fail("unknown-schema", "candidate set schema is invalid") end
  if value.status ~= "candidate" then fail("unsupported-candidate-set-status", "candidate set status is unsupported") end
  require_bounded(value.candidate_set_id, 180, "candidate_set_id", "malformed-candidate-set")
  if value.request_digest ~= G.canonical_digest(request) then fail("foreign-request-digest", "request digest differs") end
  dense_list(value.candidates, 1, request.policy.max_candidates, "candidate_set.candidates", "malformed-candidate-set")
  local candidate_ids = {}
  for index, candidate in ipairs(value.candidates) do
    validate_candidate(candidate, request, index)
    if candidate_ids[candidate.candidate_id] then fail("duplicate-candidate-id", "candidate_id is duplicated") end
    candidate_ids[candidate.candidate_id] = true
  end
  return value
end

local function valid_timestamp(value)
  if type(value) ~= "string" then return false end
  local year, month, day, hour, minute, second = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not year then return false end
  year, month, day, hour, minute, second = tonumber(year), tonumber(month), tonumber(day), tonumber(hour), tonumber(minute), tonumber(second)
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0) then days[2] = 29 end
  return month >= 1 and month <= 12 and day >= 1 and day <= days[month] and hour <= 23 and minute <= 59 and second <= 59
end

function G.validate_receipt(value, request, candidate_set)
  G.validate_candidate_set(candidate_set, request)
  only_fields(value, { schema = true, outcome = true, attempt = true, request_digest = true, input_digest = true, raw_response_digest = true, validated_output_digest = true, candidate_set = true, provider = true, prompt_template = true, policy_id = true, budget = true, rejected_candidates = true, timing = true }, "receipt", "malformed-receipt")
  if value.schema ~= G.schemas.receipt then fail("unknown-schema", "receipt schema is invalid") end
  if value.outcome ~= "complete" then fail("unsupported-outcome", "receipt outcome is unsupported") end
  if type(value.attempt) ~= "number" or value.attempt ~= math.floor(value.attempt) or value.attempt < 1 or value.attempt > 8 then fail("malformed-receipt", "attempt is invalid") end
  local request_digest, output_digest = G.canonical_digest(request), G.canonical_digest(candidate_set)
  if value.request_digest ~= request_digest or value.input_digest ~= request_digest then fail("foreign-request-digest", "receipt request binding differs") end
  require_sha(value.raw_response_digest, "raw_response_digest", "malformed-receipt")
  if value.validated_output_digest ~= output_digest then fail("foreign-candidate-digest", "validated output digest differs") end
  validate_artifact(value.candidate_set, G.schemas.candidate_set, "receipt.candidate_set", "malformed-receipt")
  if value.candidate_set.artifact_digest ~= output_digest then fail("foreign-candidate-digest", "candidate artifact digest differs") end
  only_fields(value.provider, { adapter_id = true, adapter_version = true, model_id = true }, "receipt.provider", "malformed-receipt")
  require_bounded(value.provider.adapter_id, 180, "adapter_id", "malformed-receipt"); require_semver(value.provider.adapter_version, "adapter_version", "malformed-receipt"); require_bounded(value.provider.model_id, 180, "model_id", "malformed-receipt")
  validate_prompt(value.prompt_template, "receipt.prompt_template", "malformed-receipt")
  for _, key in ipairs({ "template_id", "template_version", "template_digest" }) do if value.prompt_template[key] ~= request.prompt_template[key] then fail("foreign-prompt-template", "prompt template differs") end end
  if value.policy_id ~= request.policy.policy_id then fail("foreign-policy", "policy_id differs") end
  only_fields(value.budget, { prompt_bytes = true, response_bytes = true, elapsed_ms = true }, "receipt.budget", "malformed-receipt")
  local budget_limits = { prompt_bytes = request.policy.max_prompt_bytes, response_bytes = request.policy.max_response_bytes, elapsed_ms = request.policy.timeout_ms }
  for key, maximum in pairs(budget_limits) do if type(value.budget[key]) ~= "number" or value.budget[key] ~= math.floor(value.budget[key]) or value.budget[key] < 0 or value.budget[key] > maximum then fail("budget-exceeded", key .. " exceeds request policy") end end
  only_fields(value.rejected_candidates, { total = true, reasons = true }, "receipt.rejected_candidates", "malformed-receipt")
  if type(value.rejected_candidates.total) ~= "number" or value.rejected_candidates.total ~= math.floor(value.rejected_candidates.total) or value.rejected_candidates.total < 0 or value.rejected_candidates.total > 64 then fail("malformed-receipt", "rejected total is invalid") end
  dense_list(value.rejected_candidates.reasons, 0, 64, "receipt.rejected_candidates.reasons", "malformed-receipt")
  local reason_codes, total = {}, 0
  local allowed_reasons = { ["duplicate-candidate"] = true, ["unsupported-action"] = true, ["unsupported-assertion"] = true, ["invalid-traceability"] = true, ["oversized-value"] = true, ["malformed-candidate"] = true }
  for index, reason in ipairs(value.rejected_candidates.reasons) do
    only_fields(reason, { code = true, count = true }, "receipt.rejected_candidates.reasons[" .. index .. "]", "malformed-receipt")
    if not allowed_reasons[reason.code] or reason_codes[reason.code] or type(reason.count) ~= "number" or reason.count ~= math.floor(reason.count) or reason.count < 1 or reason.count > 64 then fail("malformed-receipt", "rejection reason is invalid") end
    reason_codes[reason.code], total = true, total + reason.count
  end
  if total ~= value.rejected_candidates.total then fail("malformed-receipt", "rejection counts do not sum to total") end
  only_fields(value.timing, { started_at = true, finished_at = true, duration_ms = true }, "receipt.timing", "malformed-receipt")
  if not valid_timestamp(value.timing.started_at) or not valid_timestamp(value.timing.finished_at) or value.timing.finished_at < value.timing.started_at then fail("malformed-timing", "timing interval is invalid") end
  if value.timing.duration_ms ~= value.budget.elapsed_ms then fail("malformed-timing", "duration_ms differs from elapsed_ms") end
  return value
end

return G
