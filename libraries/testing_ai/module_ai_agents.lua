local strings = require("contract.strings")

local A = {}

A.agent_generation_schema = "testing-runner.ai-agent-generation.v1"
A.agent_review_schema = "testing-runner.generated-case-agent-review.v1"

local max_string = 512
local max_id = 180
local max_cases = 32
local max_agent_seats = 16
local max_review_decisions = 32

local agent_generation_fields = {
  artifact_kind = true,
  artifact_root = true,
  context_manifest_path = true,
  generated_cases_path = true,
  status = true,
  mode = true,
  proposal_id = true,
  consensus_proposal_ref = true,
  generation_digest = true,
  generated_case_count = true,
  seat_count = true,
  seat_names = true,
  schema = true,
}

local agent_review_fields = {
  approved_case_count = true,
  approved_case_ids = true,
  artifact_kind = true,
  artifact_root = true,
  blocked_case_count = true,
  context_manifest_path = true,
  decision_digest = true,
  generated_case_agent_review_path = true,
  generated_case_gate_path = true,
  generated_cases_path = true,
  mode = true,
  proposal_id = true,
  consensus_proposal_ref = true,
  rejected_case_count = true,
  review_decisions = true,
  schema = true,
  seat_count = true,
  seat_names = true,
  status = true,
}

local review_decision_fields = {
  case_id = true,
  status = true,
  classification = true,
  reason = true,
}

local forbidden_terms = {
  "raw_dom",
  "screenshot_body",
  "model_transcript",
  "browser_" .. "storage",
  "local" .. "storage",
  "session" .. "storage",
  "coo" .. "kie",
  "to" .. "ken",
  "pass" .. "word",
  "credential",
  "raw_prompt",
  "raw_response",
  "raw_report",
}

local function bounded_text(value, limit)
  return type(value) == "string" and value ~= "" and #value <= (limit or max_string) and value:find("[%z\1-\31]") == nil
end

local function dense_count(value)
  if type(value) ~= "table" then return nil end
  local count = #value
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key or key > count then return nil end
  end
  return count
end

local function validate_fields(value, allowed, context)
  for key, _ in pairs(value or {}) do
    if allowed[key] ~= true then error(context .. ": unsupported field") end
  end
end

local function safe_artifact_pointer(value)
  return bounded_text(value, max_string) and strings.is_path_safe_key(value, max_string) and value:sub(1, 14) == ".testing/runs/"
end

local function copy_string_list(value, fallback, context, limit)
  local source = value or fallback or {}
  local count = dense_count(source)
  if count == nil or count > (limit or max_agent_seats) then error(context .. " must be a bounded dense list") end
  local out = {}
  for index = 1, count do
    local item = source[index]
    if not bounded_text(item, max_string) then error(context .. " contains unsupported item") end
    out[index] = item
  end
  return out
end

local function safe_key(value, fallback)
  local fallback_text = fallback or "testing"
  local text = tostring(value or fallback_text):gsub("[^%w%._%-%/]", "-")
  local parts = {}
  for part in text:gmatch("[^/]+") do
    if part == "." or part == ".." then part = "-" end
    table.insert(parts, part)
  end
  text = table.concat(parts, "/"):gsub("^/+", ""):gsub("/+$", "")
  if text == "" then text = fallback_text end
  if #text > max_id then text = text:sub(1, max_id):gsub("/+$", "") end
  return text ~= "" and text or fallback_text
end

local function forbidden_term(value)
  if type(value) == "string" then
    local text = value:lower()
    for _, term in ipairs(forbidden_terms) do
      if text:find(term, 1, true) ~= nil then return term end
    end
  elseif type(value) == "table" then
    for key, item in pairs(value) do
      local found = forbidden_term(key) or forbidden_term(item)
      if found ~= nil then return found end
    end
  end
  return nil
end

local function set_from_list(value)
  local set = {}
  for _, item in ipairs(value or {}) do set[item] = true end
  return set
end

local function proposal_id(context, purpose)
  return safe_key("testing-ai/" .. tostring(purpose) .. "/" .. tostring((context or {}).input_digest or "context"), "testing-ai")
end

local function proposal_dedup(context, request, purpose)
  local seed = tostring((context or {}).input_digest or "context")
    .. ":" .. tostring((request or {}).dedup_key or "")
    .. ":" .. tostring(purpose)
    .. ":" .. tostring((request or {}).mode or "disabled")
  return safe_key("testing-ai/" .. tostring(purpose) .. "/" .. strings.decimal_checksum(seed), "testing-ai")
end

local function proposal_source_ref(context, purpose)
  return {
    kind = "testing-ai-" .. tostring(purpose),
    ref = safe_key((context or {}).context_manifest_path or (context or {}).artifact_root or "context", "context"),
  }
end

local function apply_consensus_angles(proposal, request)
  if type(request) == "table" and request.consensus_angles ~= nil then
    proposal.angles = copy_string_list(request.consensus_angles, nil, "testing-runner: malformed-request: ai_generation.consensus_angles", 4)
  end
  return proposal
end

local function module_summary_lines(context)
  local lines = {}
  for _, module in ipairs((context or {}).modules or {}) do
    table.insert(lines, "- " .. tostring(module.id) .. " entry_url=" .. tostring(module.entry_url or "not-recorded") .. " route=" .. tostring(module.route or "not-recorded") .. " label=" .. tostring(module.visible_label or module.name or "not-recorded"))
    if #lines >= 16 then break end
  end
  if #lines == 0 then lines[1] = "- no modules in sanitized context" end
  return lines
end

function A.build_generation_proposal(context, request)
  local body = {
    "Generate bounded local UI test case candidates for the sanitized FKST testing context.",
    "Use only same-origin local scope, allowed FKST action enums, and pointer evidence.",
    "Return advice only; FKST deterministic schemas and safety gates decide executability.",
    "Context manifest: " .. tostring((context or {}).context_manifest_path or "not-recorded"),
    "Generated cases artifact: " .. tostring((context or {}).generated_cases_path or "not-recorded"),
    "Module count: " .. tostring((context or {}).module_count or 0),
    "Sanitized modules:",
  }
  for _, line in ipairs(module_summary_lines(context)) do table.insert(body, line) end
  table.insert(body, "Reply with concise candidate case IDs and action enums only; do not include sensitive browser data, transcripts, screenshots, or storage contents.")
  return apply_consensus_angles({
    schema = "consensus.proposal.v1",
    proposal_id = proposal_id(context, "generation"),
    title = "Generate FKST UI test case candidates",
    body = table.concat(body, "\n"),
    context = "artifact_root=" .. tostring((context or {}).artifact_root or "not-recorded")
      .. " context_manifest_path=" .. tostring((context or {}).context_manifest_path or "not-recorded")
      .. " generated_cases_path=" .. tostring((context or {}).generated_cases_path or "not-recorded"),
    dedup_key = proposal_dedup(context, request, "generation"),
    source_ref = proposal_source_ref(context, "generation"),
    verdict_mode = "converge",
  }, request)
end

function A.build_review_proposal(context, generated, gate, request)
  local body = {
    "Review FKST generated UI test cases after deterministic schema and safety gating.",
    "Approve only if executable generated cases should be eligible for deterministic CDP execution.",
    "Reject if any executable case should not run; convergence means no generated case executes.",
    "Context manifest: " .. tostring((context or {}).context_manifest_path or "not-recorded"),
    "Generated cases artifact: " .. tostring((generated or {}).generated_cases_path or (context or {}).generated_cases_path or "not-recorded"),
    "Gate artifact: " .. tostring((gate or {}).generated_case_gate_path or (context or {}).generated_case_gate_path or "not-recorded"),
    "Gate status: " .. tostring((gate or {}).status or "not-reviewed"),
    "Executable generated cases: " .. tostring((gate or {}).executable_count or 0),
    "Rejected generated cases: " .. tostring((gate or {}).rejected_count or 0),
  }
  for _, decision in ipairs((gate or {}).decisions or {}) do
    table.insert(body, "- " .. tostring(decision.case_id or "case") .. " status=" .. tostring(decision.review_status or "unknown") .. " classification=" .. tostring(decision.classification or "unknown"))
    if #body >= 28 then break end
  end
  return apply_consensus_angles({
    schema = "consensus.proposal.v1",
    proposal_id = proposal_id(context, "review"),
    title = "Review FKST generated test cases",
    body = table.concat(body, "\n"),
    context = "artifact_root=" .. tostring((context or {}).artifact_root or "not-recorded")
      .. " generated_case_gate_path=" .. tostring((gate or {}).generated_case_gate_path or (context or {}).generated_case_gate_path or "not-recorded"),
    dedup_key = proposal_dedup(context, request, "review"),
    source_ref = proposal_source_ref(context, "review"),
    verdict_mode = "gate",
  }, request)
end

local function seat_names_from_result(agent_result)
  local names, seen = {}, {}
  for _, item in ipairs((agent_result or {}).angle_results or (agent_result or {}).angle_digests or {}) do
    local angle = type(item) == "table" and item.angle or nil
    if bounded_text(angle, 80) and seen[angle] ~= true then
      table.insert(names, angle)
      seen[angle] = true
    end
    if #names >= max_agent_seats then break end
  end
  return #names > 0 and names or nil
end

local function decision_digest(prefix, context, agent_result, status)
  local seed = tostring(prefix) .. ":" .. tostring((context or {}).input_digest or "context")
    .. ":" .. tostring((agent_result or {}).proposal_id or "proposal")
    .. ":" .. tostring((agent_result or {}).decision or status or "unknown")
    .. ":" .. tostring(#((agent_result or {}).angle_results or (agent_result or {}).angle_digests or {}))
  return prefix .. "-" .. strings.decimal_checksum(seed)
end

local function agent_status(agent_result, approved_status)
  if type(agent_result) ~= "table" then return "unavailable" end
  if agent_result.schema == "consensus.consensus_converge.v1" then return "converged" end
  if agent_result.schema ~= "consensus.consensus_reached.v1" then return "unavailable" end
  if agent_result.decision == "approve" then return approved_status end
  if agent_result.decision == "reject" then return "rejected" end
  return "unavailable"
end

function A.generation_from_agent_results(context, agent_result)
  local status = agent_status(agent_result, "approved")
  if status == "rejected" then status = "blocked" end
  local seats = seat_names_from_result(agent_result)
  return {
    schema = A.agent_generation_schema,
    artifact_kind = "ai-agent-generation",
    artifact_root = context.artifact_root,
    context_manifest_path = context.context_manifest_path,
    generated_cases_path = context.generated_cases_path,
    status = status,
    mode = context.generation_mode or "disabled",
    proposal_id = (agent_result or {}).proposal_id,
    consensus_proposal_ref = proposal_id(context, "generation"),
    generation_digest = decision_digest("agent-gen", context, agent_result, status),
    generated_case_count = type((agent_result or {}).generated_case_count) == "number" and agent_result.generated_case_count or 0,
    seat_count = seats and #seats or 0,
    seat_names = seats,
  }
end

function A.validate_agent_generation(value)
  if value == nil then return nil end
  if type(value) ~= "table" then error("testing-runner: malformed-agent-generation: payload must be a table") end
  validate_fields(value, agent_generation_fields, "testing-runner: malformed-agent-generation")
  if value.schema ~= A.agent_generation_schema then error("testing-runner: unknown-agent-generation-schema: expected " .. A.agent_generation_schema) end
  if not strings.is_artifact_root(value.artifact_root) then error("testing-runner: malformed-agent-generation: artifact_root must be safe") end
  if not safe_artifact_pointer(value.context_manifest_path) or not safe_artifact_pointer(value.generated_cases_path) then error("testing-runner: malformed-agent-generation: artifact pointers must be safe") end
  if value.status ~= "approved" and value.status ~= "blocked" and value.status ~= "degraded" and value.status ~= "converged" and value.status ~= "unavailable" then error("testing-runner: malformed-agent-generation: status is invalid") end
  if type(value.generated_case_count) ~= "number" or value.generated_case_count < 0 or value.generated_case_count > max_cases or math.floor(value.generated_case_count) ~= value.generated_case_count then error("testing-runner: malformed-agent-generation: generated_case_count must be bounded") end
  if value.seat_count ~= nil and (type(value.seat_count) ~= "number" or value.seat_count < 0 or value.seat_count > max_agent_seats or math.floor(value.seat_count) ~= value.seat_count) then error("testing-runner: malformed-agent-generation: seat_count must be bounded") end
  copy_string_list(value.seat_names, {}, "testing-runner: malformed-agent-artifact: seat_names", max_agent_seats)
  if forbidden_term(value) ~= nil then error("testing-runner: malformed-agent-generation: contains forbidden payload term") end
  return value
end

local function executable_case_ids(gate)
  local ids = {}
  for _, case in ipairs((gate or {}).cases or {}) do
    if case.review_status == "executable" then table.insert(ids, case.id) end
  end
  return ids
end

function A.review_from_agent_results(context, gate, agent_result)
  local status = agent_status(agent_result, "approved")
  local seats = seat_names_from_result(agent_result)
  local approved_ids = status == "approved" and executable_case_ids(gate) or {}
  local decisions, approved_set = {}, set_from_list(approved_ids)
  for _, decision in ipairs((gate or {}).decisions or {}) do
    local case_id = decision.case_id or "generated-case"
    local approved = approved_set[case_id] == true
    table.insert(decisions, {
      case_id = case_id,
      status = approved and "approved" or "blocked",
      classification = approved and "agent-approved" or (status == "rejected" and "agent-rejected" or "agent-unavailable"),
      reason = approved and "agent review approved deterministic executable case" or "agent review did not approve generated case execution",
    })
    if #decisions >= max_review_decisions then break end
  end
  return {
    schema = A.agent_review_schema,
    artifact_kind = "generated-case-agent-review",
    artifact_root = context.artifact_root,
    context_manifest_path = context.context_manifest_path,
    generated_cases_path = context.generated_cases_path,
    generated_case_gate_path = context.generated_case_gate_path,
    generated_case_agent_review_path = context.generated_case_agent_review_path,
    status = status,
    mode = context.generation_mode or "disabled",
    proposal_id = (agent_result or {}).proposal_id,
    consensus_proposal_ref = proposal_id(context, "review"),
    decision_digest = decision_digest("agent-review", context, agent_result, status),
    approved_case_ids = approved_ids,
    approved_case_count = #approved_ids,
    rejected_case_count = status == "rejected" and ((gate or {}).executable_count or 0) or 0,
    blocked_case_count = status ~= "approved" and ((gate or {}).executable_count or 0) or 0,
    seat_count = seats and #seats or 0,
    seat_names = seats,
    review_decisions = decisions,
  }
end

function A.validate_agent_review(value)
  if value == nil then return nil end
  if type(value) ~= "table" then error("testing-runner: malformed-agent-review: payload must be a table") end
  validate_fields(value, agent_review_fields, "testing-runner: malformed-agent-review")
  if value.schema ~= A.agent_review_schema then error("testing-runner: unknown-agent-review-schema: expected " .. A.agent_review_schema) end
  if not strings.is_artifact_root(value.artifact_root) then error("testing-runner: malformed-agent-review: artifact_root must be safe") end
  if not safe_artifact_pointer(value.context_manifest_path) then error("testing-runner: malformed-agent-review: context_manifest_path must be safe") end
  if not safe_artifact_pointer(value.generated_cases_path) or not safe_artifact_pointer(value.generated_case_gate_path) then error("testing-runner: malformed-agent-review: generated case pointers must be safe") end
  if value.generated_case_agent_review_path ~= nil and not safe_artifact_pointer(value.generated_case_agent_review_path) then error("testing-runner: malformed-agent-review: review path must be safe") end
  if value.status ~= "approved" and value.status ~= "rejected" and value.status ~= "converged" and value.status ~= "unavailable" then error("testing-runner: malformed-agent-review: status is invalid") end
  local ids = copy_string_list(value.approved_case_ids, {}, "testing-runner: malformed-agent-review: approved_case_ids", max_cases)
  if type(value.approved_case_count) ~= "number" or value.approved_case_count ~= #ids then error("testing-runner: malformed-agent-review: approved_case_count must match approved ids") end
  for _, key in ipairs({ "rejected_case_count", "blocked_case_count", "seat_count" }) do
    local limit = key == "seat_count" and max_agent_seats or max_cases
    local count = value[key] or 0
    if type(count) ~= "number" or count < 0 or count > limit or math.floor(count) ~= count then error("testing-runner: malformed-agent-review: count field is invalid") end
  end
  copy_string_list(value.seat_names, {}, "testing-runner: malformed-agent-artifact: seat_names", max_agent_seats)
  local decision_count = dense_count(value.review_decisions or {})
  if decision_count == nil or decision_count > max_review_decisions then error("testing-runner: malformed-agent-review: review_decisions must be bounded") end
  for _, decision in ipairs(value.review_decisions or {}) do
    if type(decision) ~= "table" then error("testing-runner: malformed-agent-review: review decision must be a table") end
    validate_fields(decision, review_decision_fields, "testing-runner: malformed-agent-review: review decision")
    if not bounded_text(decision.case_id, max_id) or not bounded_text(decision.status, 80) or not bounded_text(decision.classification, 80) then error("testing-runner: malformed-agent-review: review decision fields are required") end
    if decision.reason ~= nil and not bounded_text(decision.reason, max_string) then error("testing-runner: malformed-agent-review: review decision reason must be bounded") end
  end
  if forbidden_term(value) ~= nil then error("testing-runner: malformed-agent-review: contains forbidden payload term") end
  return value
end

function A.agent_review_allows_merge(review, case)
  if review == nil then return true end
  A.validate_agent_review(review)
  if review.status ~= "approved" then return false end
  return set_from_list(review.approved_case_ids or {})[(case or {}).id] == true
end

return A
