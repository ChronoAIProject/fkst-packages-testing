local M = {}

local strings = require("contract.strings")
local testing_contract = require("contract.testing")
local ai_orchestration = require("ai_orchestration")

local statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  degraded = true,
  mixed = true,
}

function M.validate_module_start(payload)
  if type(payload) ~= "table" then
    error("testing-pipeline: malformed-request: payload must be a table")
  end
  if payload.schema ~= "testing-pipeline.module-start.v1" then
    error("testing-pipeline: unknown-schema: expected testing-pipeline.module-start.v1")
  end
  if not strings.is_bounded_string(payload.module, 256) then
    error("testing-pipeline: malformed-request: module is required")
  end
  if payload.artifact_root ~= nil and not strings.is_artifact_root(payload.artifact_root) then
    error("testing-pipeline: malformed-request: artifact_root must be a safe .testing/runs/... path")
  end
  return payload
end

function M.module_loop_request(payload)
  payload = M.validate_module_start(payload)
  local src = testing_contract.copy_source_ref(payload.source_ref, "testing-pipeline", payload.module)
  return {
    schema = "module-test-loop.start.v1",
    module = payload.module,
    config = payload.config,
    e2e_driver = payload.e2e_driver,
    no_browser = payload.no_browser,
    dry_run = payload.dry_run,
    dry_run_github = payload.dry_run_github,
    backend = payload.backend,
    native_argv = payload.native_argv,
    ui_loop = payload.ui_loop,
    module_discovery = payload.module_discovery,
    cdp_execution = payload.cdp_execution,
    preflight_result = payload.preflight_result,
    artifact_root = payload.artifact_root,
    source_ref = src,
    trace_id = testing_contract.trace_id(payload.trace_id, src, payload.artifact_root),
    dedup_key = testing_contract.dedup_key(payload.dedup_key, {
      "testing-pipeline",
      "module",
      payload.module,
      src.kind,
      src.ref,
      payload.artifact_root or "artifact",
    }),
  }
end

function M.requires_ai_consensus(payload)
  payload = M.validate_module_start(payload)
  local cdp = payload.cdp_execution
  local generation = type(cdp) == "table" and cdp.ai_generation or nil
  return type(generation) == "table" and generation.mode == "autonomous-reviewed"
end

local function artifact_root_for(payload)
  local root = payload.artifact_root or (".testing/runs/" .. strings.sanitize_key(payload.module, 180))
  if not strings.is_artifact_root(root) then
    error("testing-pipeline: malformed-ai-consensus: artifact_root must be safe")
  end
  return root
end

local function stripped_url(value)
  if type(value) ~= "string" then return "not-recorded" end
  local text = value:gsub("[#?].*$", "")
  if #text > 512 then text = text:sub(1, 512) end
  return text
end

local function copy_angles(value)
  if value == nil then return nil end
  if type(value) ~= "table" or #value == 0 or #value > 4 then
    error("testing-pipeline: malformed-ai-consensus: consensus_angles must be a bounded dense list")
  end
  local out = {}
  for index, item in ipairs(value) do
    if not strings.is_bounded_string(item, 200) then
      error("testing-pipeline: malformed-ai-consensus: consensus_angles contains unsupported item")
    end
    out[index] = item
  end
  return out
end

function M.ai_generation_proposal(payload)
  payload = M.validate_module_start(payload)
  local cdp = type(payload.cdp_execution) == "table" and payload.cdp_execution or {}
  local generation = type(cdp.ai_generation) == "table" and cdp.ai_generation or {}
  local root = artifact_root_for(payload)
  local src = testing_contract.copy_source_ref(payload.source_ref, "testing-pipeline", payload.module)
  local context_path = root .. "/ai-context-manifest.json"
  local generated_path = root .. "/generated-test-cases.json"
  local gate_path = root .. "/generated-case-gate.json"
  local seed = table.concat({ tostring(payload.module), src.kind, src.ref, root, tostring(payload.dedup_key or "") }, ":")
  local body = table.concat({
    "Generate bounded local UI test case candidates for the sanitized FKST testing context.",
    "Use only same-origin local scope, allowed FKST action enums, and pointer evidence.",
    "Return advice only; FKST deterministic schemas and safety gates decide executability.",
    "Module: " .. tostring(payload.module),
    "Base URL: " .. stripped_url(type(payload.ui_loop) == "table" and payload.ui_loop.base_url or nil),
    "Context manifest: " .. context_path,
    "Generated cases artifact: " .. generated_path,
    "Deterministic gate artifact: " .. gate_path,
    "Reply with concise candidate case IDs and action enums only; do not include sensitive browser data, transcripts, screenshots, or storage contents.",
  }, "\n")
  local proposal = {
    schema = "consensus.proposal.v1",
    proposal_id = "testing-ai/generation/" .. strings.decimal_checksum(seed),
    title = "Generate FKST UI test case candidates",
    body = body,
    context = "artifact_root=" .. root .. " context_manifest_path=" .. context_path .. " generated_cases_path=" .. generated_path,
    dedup_key = testing_contract.dedup_key(generation.dedup_key or payload.dedup_key, {
      "testing-pipeline",
      "ai-generation",
      payload.module,
      src.kind,
      src.ref,
      root,
    }),
    source_ref = {
      kind = "testing-ai-generation",
      ref = context_path,
    },
    verdict_mode = "converge",
  }
  proposal.angles = copy_angles(generation.consensus_angles)
  return proposal
end

function M.start_ai_orchestration(payload, io)
  M.validate_module_start(payload)
  return ai_orchestration.start(payload, io)
end

function M.handle_ai_consensus_reached(payload, io)
  return ai_orchestration.handle_consensus_reached(payload, io)
end

function M.handle_ai_consensus_converge(payload, io)
  return ai_orchestration.handle_consensus_converge(payload, io)
end

function M.is_testing_ai_consensus(payload)
  return ai_orchestration.is_testing_ai_consensus(payload)
end

function M.validate_testing_result(result)
  if type(result) ~= "table" then
    error("testing-pipeline: malformed-result: result must be a table")
  end
  if result.schema ~= "testing-runner.result.v1" then
    error("testing-pipeline: unknown-result-schema: expected testing-runner.result.v1")
  end
  return result
end

function M.validate_artifact_summary(summary)
  if type(summary) ~= "table" then
    error("testing-pipeline: malformed-summary: summary must be a table")
  end
  if summary.schema ~= "test-artifacts.summary.v1" then
    error("testing-pipeline: unknown-summary-schema: expected test-artifacts.summary.v1")
  end
  if not statuses[summary.status] then
    error("testing-pipeline: malformed-summary: unknown status")
  end
  if not strings.is_artifact_root(summary.artifact_root) then
    error("testing-pipeline: malformed-summary: artifact_root must be a safe .testing/runs/... path")
  end
  return summary
end

local function add_error(errors, id, message)
  table.insert(errors, { id = id, message = message })
end

local function expect_equal(errors, id, actual, expected)
  if actual == expected then return end
  add_error(errors, id, "pipeline transition expected " .. tostring(expected) .. " but got " .. tostring(actual))
end

function M.saga_conformance_errors()
  local ok, request = pcall(M.module_loop_request, {
    schema = "testing-pipeline.module-start.v1",
    module = "conformance-module",
    backend = "fkst-native",
    no_browser = true,
    dry_run = false,
    native_argv = { "conformance-module-check" },
    preflight_result = { status = "ready" },
    artifact_root = ".testing/runs/conformance-module",
    source_ref = { kind = "host-module", ref = "conformance-module" },
    trace_id = "trace-conformance-module",
    dedup_key = "conformance-module-run",
  })
  local errors = {}
  if not ok then
    add_error(errors, "testing-pipeline.saga.module-loop-request", tostring(request))
    return errors
  end
  expect_equal(errors, "testing-pipeline.saga.schema", request.schema, "module-test-loop.start.v1")
  expect_equal(errors, "testing-pipeline.saga.module", request.module, "conformance-module")
  expect_equal(errors, "testing-pipeline.saga.backend", request.backend, "fkst-native")
  expect_equal(errors, "testing-pipeline.saga.no-browser", request.no_browser, true)
  expect_equal(errors, "testing-pipeline.saga.dry-run", request.dry_run, false)
  expect_equal(errors, "testing-pipeline.saga.native-argv", request.native_argv and request.native_argv[1], "conformance-module-check")
  expect_equal(errors, "testing-pipeline.saga.artifact-root", request.artifact_root, ".testing/runs/conformance-module")
  expect_equal(errors, "testing-pipeline.saga.source-kind", request.source_ref and request.source_ref.kind, "host-module")
  expect_equal(errors, "testing-pipeline.saga.source-ref", request.source_ref and request.source_ref.ref, "conformance-module")
  expect_equal(errors, "testing-pipeline.saga.trace-id", request.trace_id, "trace-conformance-module")
  expect_equal(errors, "testing-pipeline.saga.dedup-key", request.dedup_key, "conformance-module-run")
  return errors
end

return M
