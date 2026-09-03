local qa_publication = require("qa_publication")
local canonical_validator = require("canonical_results")
local manifest_contract = require("contract.testing_evidence_manifest")
local results_compat = require("contract.testing_results_compat")
local structured_contract = require("contract.structured_execution")
local t = fkst.test

local commit_sha = string.rep("1", 40)
local plan_sha = string.rep("b", 64)
local results_sha = string.rep("c", 64)
local environment_sha = string.rep("d", 64)
local readiness_sha = string.rep("5", 64)
local cleanup_sha = string.rep("e", 64)
local report_sha = string.rep("f", 64)
local terminal_sha = string.rep("6", 64)
local catalog_sha = string.rep("7", 64)
local module_plan_sha = string.rep("8", 64)
local result_set_artifact_sha = string.rep("a", 64)
local manifest_artifact_sha = string.rep("2", 64)

local function portable_sha256(bytes)
  local function quote(value) return string.format("%q", value) end
  local input, output = os.tmpname(), os.tmpname()
  local handle = assert(io.open(input, "wb")); handle:write(bytes); handle:close()
  for _, command in ipairs({ "shasum -a 256", "sha256sum", "openssl dgst -sha256" }) do
    os.execute(command .. " " .. quote(input) .. " > " .. quote(output) .. " 2>/dev/null")
    local digest_file = io.open(output, "r")
    local line = digest_file and digest_file:read("*l") or ""
    if digest_file then digest_file:close() end
    for candidate in tostring(line):gmatch("[0-9A-Fa-f]+") do
      if #candidate == 64 then
        os.remove(input); os.remove(output)
        return candidate:lower()
      end
    end
  end
  os.remove(input); os.remove(output)
  error("no SHA-256 command is available")
end

local function request(channel)
  local root = ".testing/runs/qa-run-final"
  local value = {
    schema = "test-publication.qa-finalize.request.v2",
    repository = { slug = "owner/repo", commit_sha = commit_sha },
    run_id = "qa-run-final", issue_number = 107,
    artifact_root = root,
    ledger_ref = root .. "/run-ledger.json",
    terminal_summary_ref = root .. "/terminal-summary.json", terminal_summary_sha256 = terminal_sha,
    case_results_ref = root .. "/case-results.json", case_results_sha256 = results_sha,
    environment_receipt_ref = root .. "/environment-receipt-ready.json",
    environment_receipt_sha256 = environment_sha,
    browser_readiness_ref = root .. "/browser-readiness.json",
    browser_readiness_sha256 = readiness_sha,
    cleanup_receipt_ref = root .. "/cleanup-receipt-complete.json",
    cleanup_receipt_sha256 = cleanup_sha,
    aggregate_report_ref = root .. "/aggregate-report.json",
    trace_id = "trace-qa-run-final", dedup_key = "dedup-qa-run-final",
  }
  value["test_" .. "plan_ref"] = root .. "/test-plan.json"
  value["test_" .. "plan_sha256"] = plan_sha
  value.channel = channel
  return value
end

local function canonical_request(channel)
  local value = request(channel)
  value.case_result_set_ref = value.artifact_root .. "/case-result-set.json"
  value.case_result_set_artifact_sha256 = result_set_artifact_sha
  value.evidence_manifest_ref = value.artifact_root .. "/evidence-manifest.json"
  value.evidence_manifest_artifact_sha256 = manifest_artifact_sha
  return value
end

local function repository()
  return { slug = "owner/repo", url = "https://github.com/owner/repo.git", commit_sha = commit_sha }
end

local function readiness(root, run_id, trace_id, dedup_key)
  local operation_state_ref = { kind = "artifact", ref = root .. "/operation-state.json" }
  local correlation = {
    schema = "environment-factory.browser-readiness-correlation.v1",
    attempt_id = "readiness-attempt-1",
    operation_id = run_id,
    operation_state_ref = operation_state_ref,
    readiness_attempt_ref = { kind = "artifact", ref = root .. "/browser-readiness-attempt.json" },
    readiness_attempt_sha256 = string.rep("a", 64),
    base_url = "http://127.0.0.1:4173/health",
    sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
    trace_id = trace_id,
    dedup_key = dedup_key,
  }
  return {
    schema = "browser-readiness.result.v1",
    status = "ready",
    sessions = {
      { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
      { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } }, cdp_url = "http://127.0.0.1:9222" },
    },
    source_ref = operation_state_ref,
    request_context = { dry_run = false },
    correlation = correlation,
  }
end

local function environment_receipt(value, status)
  local root = value.artifact_root
  local receipt = {
    schema = "environment-factory.receipt.v2",
    operation_id = value.run_id,
    status = status or "ready",
    profile_revision = "qa-profile-v1",
    profile_sha256 = string.rep("9", 64),
    repository = { url = repository().url, commit_sha = commit_sha },
    workspace_ref = { kind = "workspace", ref = "qa-run-final-workspace" },
    base_url = "http://127.0.0.1:4173/health",
    runtime_ports = { { name = "application", port = 4173 } },
    sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
    artifact_root = root,
    diagnostic_refs = {},
    cleanup_ref = { kind = "runtime-cleanup", ref = "qa-run-final-cleanup" },
    cleanup_status = "pending",
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
  }
  if receipt.status == "ready" then
    receipt.browser_readiness = readiness(root, value.run_id, value.trace_id, value.dedup_key)
  else
    receipt.failure_class = "provisioning-failed"
    receipt.cleanup_status = "complete"
    receipt.cleanup_receipt_ref = { kind = "artifact", ref = value.cleanup_receipt_ref }
  end
  return receipt
end

local function cleanup_receipt(value)
  return {
    schema = "environment-factory.cleanup-receipt.v1",
    operation_id = value.run_id,
    status = "complete",
    attempted_resources = {
      { resource_id = "workspace", resource_kind = "workspace", status = "cleaned",
        diagnostic_ref = { kind = "artifact", ref = value.artifact_root .. "/diagnostics/cleanup-workspace.json" } },
    },
    verified_removals = { "workspace" },
    remaining_resources = {},
    artifact_root = value.artifact_root,
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
  }
end

local function workflow_readiness(value)
  local result = readiness(value.artifact_root, value.run_id, value.trace_id, value.dedup_key)
  result.source_ref = { kind = "workflow-qa", ref = value.run_id }
  return result
end

local function plan(value)
  return {
    schema = "testing-structured-plan.v2",
    execution_mode = "structured-api-cli",
    repository = { url = repository().url, commit_sha = commit_sha },
    environment_receipt_sha256 = environment_sha,
    browser_readiness_sha256 = readiness_sha,
    case_catalog_sha256 = catalog_sha,
    module_plan_sha256 = module_plan_sha,
    cases = {
      { case_id = "health", kind = "http", request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} }, timeout_seconds = 10, assertions = { { type = "status-code", expected = 200 } } },
      { case_id = "version", kind = "cli", argv = { "fixture", "--version" }, timeout_seconds = 10, assertions = { { type = "exit-code", expected = 0 } } },
    },
    residual_risk_case_ids = {},
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
  }
end

local function counts()
  return { planned = 2, executed = 2, passed = 1, failed = 1, skipped = 0, error = 0, blocked = 0 }
end

local function terminal_summary(value, status, terminal_counts)
  return {
    schema = "workflow-qa.terminal-summary.v2",
    status = status or "failed",
    repository = repository(),
    run_id = value.run_id,
    phase = "cleanup-pending",
    counts = terminal_counts or counts(),
    environment_receipt_ref = value.environment_receipt_ref,
    cleanup_receipt_ref = value.cleanup_receipt_ref,
    browser_readiness_ref = value.browser_readiness_ref,
    browser_readiness_sha256 = value.browser_readiness_sha256,
    structured_plan_ref = value.test_plan_ref,
    case_results_ref = value.case_results_ref,
    case_result_set_ref = value.case_result_set_ref,
    evidence_manifest_ref = value.evidence_manifest_ref,
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
  }
end

local function result_artifact_root(value)
  local canonical = type(value.case_result_set_ref) == "string"
    and value.case_result_set_ref:match("^(.*)/case%-result%-set%.json$") or nil
  if canonical ~= nil then return canonical end
  return type(value.case_results_ref) == "string"
    and value.case_results_ref:match("^(.*)/case%-results%.json$") or nil
end

local function legacy_results(value)
  local root = result_artifact_root(value)
  return {
    schema = "testing-structured-case-results.v1",
    plan_sha256 = plan_sha,
    cases = {
      {
        case_id = "health", kind = "http", status = "passed", classification = "passed",
        assertions = { { type = "status-code", passed = true } },
        evidence_ref = root .. "/evidence/health.json",
      },
      {
        case_id = "version", kind = "cli", status = "failed", classification = "product-defect",
        assertions = { { type = "exit-code", passed = false } },
        evidence_ref = root .. "/evidence/version.json",
      },
    },
  }
end

local function canonical_results(value)
  local source = repository().url .. "\n" .. commit_sha
  local root = result_artifact_root(value)
  local function metadata(case_id, evidence_id, sha256)
    local ref = root .. "/evidence/" .. case_id .. ".json"
    return {
      case_id = case_id,
      timing = {
        started_at = "2026-08-14T00:00:00Z",
        completed_at = "2026-08-14T00:00:01Z",
        duration_ms = 1000,
      },
      evidence = {
        evidence_id = evidence_id,
        role = "sanitized-json",
        sha256 = sha256,
        media_type = "application/json",
        size_bytes = 128,
        producer = "testing-runner",
        producer_version = "v1",
        created_at = "2026-08-14T00:00:01Z",
        sensitivity = "internal",
        redaction_classification = "none",
        policy_version = "v1",
        policy_status = "approved",
        provenance = { source_kind = "artifact", source_ref = ref, source_sha256 = sha256 },
      },
    }
  end
  return results_compat.canonicalize_v1(legacy_results(value), {
    artifact_root = root,
    plan_sha256 = plan_sha,
    plan = plan(value),
    repository = {
      id = commit_sha,
      source_ref = { kind = "git", ref = repository().url .. "@" .. commit_sha },
      source_sha256 = portable_sha256(source),
    },
    run_id = value.run_id,
    plan_ref = { kind = "artifact", ref = root .. "/test-plan.json" },
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
    case_metadata = {
      metadata("health", "evidence-health", string.rep("3", 64)),
      metadata("version", "evidence-version", string.rep("4", 64)),
    },
    sha256_bytes = portable_sha256,
  })
end

local function runtime(mutate, supplied, options)
  local value = supplied or request()
  options = options or {}
  local state
  local artifacts = {
    [value.terminal_summary_ref] = { digest = terminal_sha, value = terminal_summary(value) },
    [value.environment_receipt_ref] = { digest = environment_sha, value = environment_receipt(value) },
    [value.cleanup_receipt_ref] = { digest = cleanup_sha, value = cleanup_receipt(value) },
  }
  if value.browser_readiness_ref ~= nil then
    artifacts[value.browser_readiness_ref] = { digest = readiness_sha, value = workflow_readiness(value) }
  end
  if value.test_plan_ref ~= nil then
    artifacts[value.test_plan_ref] = { digest = plan_sha, value = plan(value) }
  end
  if value.case_results_ref ~= nil then
    artifacts[value.case_results_ref] = { digest = results_sha, value = legacy_results(value) }
  end
  if value.case_result_set_ref ~= nil then
    local canonical = canonical_results(value)
    canonical.result_set.evidence_manifest_artifact_sha256 = value.evidence_manifest_artifact_sha256
    canonical.result_set.evidence_manifest_ref.sha256 = value.evidence_manifest_artifact_sha256
    artifacts[value.case_result_set_ref] = {
      digest = value.case_result_set_artifact_sha256,
      value = canonical.result_set,
    }
    artifacts[value.evidence_manifest_ref] = {
      digest = value.evidence_manifest_artifact_sha256,
      value = canonical.evidence_manifest,
    }
  end
  if mutate then mutate(artifacts, value) end
  local reports = {}
  local report_writes, artifact_writes, publish_calls, artifact_loads, hash_calls = 0, 0, 0, 0, 0
  local ports = {
    load_ledger = function() return state end,
    save_ledger = function(_, next_state, expected)
      if state ~= nil and state.version ~= expected then return false end
      if state == nil and expected ~= 0 then return false end
      state = next_state return true
    end,
    load_artifact = function(path)
      artifact_loads = artifact_loads + 1
      return artifacts[path]
    end,
    write_artifact = function(path, artifact)
      artifact_writes = artifact_writes + 1
      reports[path] = artifact
      return true
    end,
    write_report = function(path, report)
      report_writes = report_writes + 1
      reports[path] = report
      artifacts[path] = { digest = report_sha, value = report }
      return { status = "written", digest = report_sha }
    end,
    publish_artifact = function(publication)
      publish_calls = publish_calls + 1
      if publication.channel == "filesystem-dry-run-v1" then
        local receipt_ref = value.artifact_root .. "/materializations/" .. publication.stage .. "-"
          .. tostring(publication.attempt) .. ".json"
        local receipt_sha256 = string.rep("4", 64)
        if not options.missing_materialization_receipt then
          artifacts[receipt_ref] = { digest = options.materialization_receipt_digest_mismatch
            and string.rep("3", 64) or receipt_sha256, value = {
            schema = "test-publication.qa-materialization-receipt.v1",
            status = "materialized", channel = "filesystem-dry-run-v1",
            run_id = publication.run_id,
            stage = options.materialization_receipt_binding_mismatch and "foreign-stage" or publication.stage,
            attempt = publication.attempt, artifact_ref = publication.artifact_ref,
            digest = publication.digest, source_commit = commit_sha, receipt_ref = receipt_ref,
            trace_id = publication.trace_id, dedup_key = publication.dedup_key,
          } }
        end
        return {
          status = "materialized", artifact_ref = publication.artifact_ref,
          digest = publication.digest, source_commit = commit_sha,
          receipt_ref = receipt_ref, receipt_sha256 = receipt_sha256,
        }
      end
      return {
        status = "published", digest = publication.digest, source_commit = commit_sha,
        remote_url = "https://github.com/owner/repo/blob/" .. commit_sha .. "/qa/" .. publication.stage .. ".json",
        receipt_ref = value.artifact_root .. "/publication/" .. publication.stage .. "-" .. tostring(publication.attempt) .. ".json",
      }
    end,
    reports = reports,
    report_writes = function() return report_writes end,
    artifact_writes = function() return artifact_writes end,
    publish_calls = function() return publish_calls end,
    artifact_loads = function() return artifact_loads end,
    hash_calls = function() return hash_calls end,
    state = function() return state end,
    artifacts = artifacts,
  }
  if value.case_result_set_ref ~= nil then
    ports.sha256_bytes = function(bytes, artifact_root)
      if artifact_root ~= result_artifact_root(value) then error("unexpected hash artifact root") end
      hash_calls = hash_calls + 1
      return portable_sha256(bytes)
    end
  end
  return ports
end

local function terminal_request()
  local value = request()
  rawset(value, "test" .. "_plan_ref", nil)
  rawset(value, "test" .. "_plan_sha256", nil)
  value.case_results_ref = nil
  value.case_results_sha256 = nil
  value.browser_readiness_ref = nil
  value.browser_readiness_sha256 = nil
  value.environment_receipt_ref = value.artifact_root .. "/environment-receipt-blocked.json"
  return value
end

local function reject_without_output(value, mutate)
  local ports = runtime(mutate, value)
  t.raises(function() qa_publication.prepare_final_report(value, ports) end)
  t.eq(ports.publish_calls(), 0)
  t.eq(ports.report_writes(), 0)
  t.eq(ports.artifact_writes(), 0)
  return ports
end

local function canonical_validation_bundle()
  local value = canonical_request()
  local ports = runtime(nil, value)
  local result_set = ports.artifacts[value.case_result_set_ref].value
  local manifest = ports.artifacts[value.evidence_manifest_ref].value
  return result_set, manifest, {
    sha256_bytes = portable_sha256,
    plan = ports.artifacts[value.test_plan_ref].value,
    repository = result_set.cases[1].repository,
    artifact_root = result_artifact_root(value),
    run_id = value.run_id,
    plan_ref = result_set.plan_ref,
    plan_sha256 = result_set.plan_sha256,
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
    evidence_manifest_ref = value.evidence_manifest_ref,
    evidence_manifest_artifact_sha256 = value.evidence_manifest_artifact_sha256,
  }
end

return {
  test_canonical_validator_rejects_incomplete_and_foreign_context = function()
    local result_set, manifest, options = canonical_validation_bundle()
    t.raises(function() canonical_validator.validate(result_set, manifest) end)
    result_set, manifest, options = canonical_validation_bundle()
    options.artifact_root = ".testing/runs/foreign/execution"
    t.raises(function() canonical_validator.validate(result_set, manifest, options) end)
  end,

  test_canonical_validator_rejects_persisted_manifest_binding_variants = function()
    local mutations = {
      function(result_set) result_set.evidence_manifest_artifact_sha256 = string.rep("0", 64) end,
      function(result_set) result_set.evidence_manifest_ref.ref = ".testing/runs/qa-run-final/execution/other.json" end,
      function(result_set) result_set.evidence_manifest_ref.sha256 = string.rep("0", 64) end,
    }
    for _, mutate in ipairs(mutations) do
      local result_set, manifest, options = canonical_validation_bundle()
      mutate(result_set)
      t.raises(function() canonical_validator.validate(result_set, manifest, options) end)
    end
  end,

  test_canonical_validator_rejects_repository_and_ambiguous_case_evidence = function()
    local result_set, manifest, options = canonical_validation_bundle()
    options.repository = { id = "foreign", source_ref = options.repository.source_ref,
      source_sha256 = options.repository.source_sha256 }
    t.raises(function() canonical_validator.validate(result_set, manifest, options) end)

    result_set, manifest, options = canonical_validation_bundle()
    table.insert(result_set.cases[1].evidence_refs, result_set.cases[1].evidence_refs[1])
    t.raises(function() canonical_validator.validate(result_set, manifest, options) end)
  end,

  test_canonical_finalization_validates_projects_and_publishes_both_views = function()
    local value = canonical_request()
    local ports = runtime(nil, value)
    local prepared = qa_publication.prepare_final_report(value, ports)

    t.eq(prepared.status, "pending")
    t.eq(prepared.report.case_result_set_ref, value.case_result_set_ref)
    t.eq(prepared.report.case_result_set_artifact_sha256, value.case_result_set_artifact_sha256)
    t.eq(prepared.report.evidence_manifest_ref, value.evidence_manifest_ref)
    t.eq(prepared.report.evidence_manifest_artifact_sha256, value.evidence_manifest_artifact_sha256)
    t.is_true(prepared.report.artifact_links.case_result_set ~= nil)
    t.is_true(prepared.report.artifact_links.evidence_manifest ~= nil)
    t.is_true(ports.hash_calls() > 0)
  end,

  test_canonical_lost_finalization_does_not_require_legacy_projection = function()
    local value = canonical_request()
    value.case_results_ref = nil
    value.case_results_sha256 = nil
    local ports = runtime(function(artifacts)
      local summary = artifacts[value.terminal_summary_ref].value
      summary.status = "blocked"
      summary.case_results_ref = nil
      summary.counts = { planned=2,executed=2,passed=0,failed=0,skipped=0,error=2,blocked=0 }
      local result_set = artifacts[value.case_result_set_ref].value
      for _, case_result in ipairs(result_set.cases) do
        case_result.execution_status = "lost"
        case_result.classification = "lost"
        case_result.non_execution_reason = "runner-disconnected"
        case_result.error = nil
        for _, assertion in ipairs(case_result.assertions) do
          assertion.status = "skipped"
          assertion.classification = "skipped"
        end
      end
    end, value)

    local prepared = qa_publication.prepare_final_report(value, ports)
    t.eq(prepared.report.status, "blocked")
    t.eq(prepared.report.counts.error, 2)
    t.eq(prepared.report.artifact_links.case_results, nil)
    t.is_true(prepared.report.artifact_links.case_result_set ~= nil)
    t.is_true(prepared.report.artifact_links.evidence_manifest ~= nil)
  end,

  test_canonical_finalization_accepts_execution_subroot_artifacts = function()
    local value = canonical_request()
    local execution_root = value.artifact_root .. "/execution"
    rawset(value, "test" .. "_plan_ref", execution_root .. "/test-plan.json")
    value.case_results_ref = execution_root .. "/case-results.json"
    value.case_result_set_ref = execution_root .. "/case-result-set.json"
    value.evidence_manifest_ref = execution_root .. "/evidence-manifest.json"
    local ports = runtime(nil, value)

    local prepared = qa_publication.prepare_final_report(value, ports)
    t.eq(prepared.status, "pending")
    t.eq(prepared.report.case_result_set_ref, value.case_result_set_ref)
    t.eq(prepared.report.evidence_manifest_ref, value.evidence_manifest_ref)
    t.is_true(ports.hash_calls() > 0)
  end,

  test_legacy_finalization_remains_valid_without_sha256_port = function()
    local value = request()
    local ports = runtime(nil, value)
    t.eq(ports.sha256_bytes, nil)

    local prepared = qa_publication.prepare_final_report(value, ports)
    t.eq(prepared.status, "pending")
    t.eq(prepared.report.case_result_set_ref, nil)
    t.eq(prepared.report.evidence_manifest_ref, nil)
    t.eq(prepared.report.artifact_links.case_result_set, nil)
  end,

  test_canonical_quartet_requires_complete_exact_lowercase_bindings = function()
    for _, mutate in ipairs({
      function(value) value.case_result_set_artifact_sha256 = nil end,
      function(value) value.case_result_set_ref = value.artifact_root .. "/other-result-set.json" end,
      function(value) value.evidence_manifest_artifact_sha256 = string.rep("A", 64) end,
    }) do
      local value = canonical_request()
      mutate(value)
      local ports = reject_without_output(value)
      t.eq(ports.artifact_loads(), 0)
    end
  end,

  test_canonical_persisted_digest_mismatch_rejects_before_output = function()
    local value = canonical_request()
    reject_without_output(value, function(artifacts)
      artifacts[value.case_result_set_ref].digest = string.rep("0", 64)
    end)
  end,

  test_canonical_digest_mismatch_and_foreign_set_reject_before_output = function()
    for _, mutate in ipairs({
      function(artifacts, value)
        artifacts[value.evidence_manifest_ref].value.canonical_sha256 = string.rep("0", 64)
      end,
      function(artifacts, value)
        artifacts[value.case_result_set_ref].value.run_id = "foreign-run"
      end,
      function(artifacts, value)
        artifacts[value.case_result_set_ref].value.evidence_manifest_ref.ref = value.artifact_root
          .. "/other-evidence-manifest.json"
      end,
    }) do
      local value = canonical_request()
      reject_without_output(value, mutate)
    end
  end,

  test_canonical_publication_rejects_extra_manifest_entry = function()
    local value = canonical_request()
    reject_without_output(value, function(artifacts)
      local manifest = artifacts[value.evidence_manifest_ref].value
      local extra = {}
      for key, item in pairs(manifest.entries[1]) do extra[key] = item end
      extra.evidence_id = "evidence-extra"
      table.insert(manifest.entries, extra)
      manifest.canonical_sha256 = manifest_contract.sha256(manifest, portable_sha256, {
        artifact_root = result_artifact_root(value),
      })
      artifacts[value.case_result_set_ref].value.evidence_manifest_sha256 = manifest.canonical_sha256
    end)
  end,

  test_canonical_browser_legacy_projection_rejects_before_output = function()
    local value = canonical_request()
    local ports = runtime(function(artifacts)
      local plan_value = artifacts[value.test_plan_ref].value
      plan_value.execution_mode = "agentic-browser"
      plan_value.cases = { {
        case_id = "health", kind = "browser", goal = "Authenticate the existing user.",
        success_conditions = { "All deterministic login signals are verified." },
        completion_assertions = {
          { assertion_id = "callback-observed", type = "browser-callback-observed", required = true, completion_field = "callback_observed" },
          { assertion_id = "process-exit-zero", type = "browser-process-exit-zero", required = true, completion_field = "process_exit_zero" },
          { assertion_id = "whoami-succeeded", type = "browser-whoami-succeeded", required = true, completion_field = "whoami_succeeded" },
          { assertion_id = "status-authenticated", type = "browser-status-authenticated", required = true, completion_field = "status_authenticated" },
        },
      } }
      local result_set = artifacts[value.case_result_set_ref].value
      result_set.cases = { result_set.cases[1] }
      local case_result = result_set.cases[1]
      case_result.execution_mode = "browser"
      local assertion_template = structured_contract.copy(case_result.assertions[1])
      case_result.assertions = {}
      for index, authority in ipairs(plan_value.cases[1].completion_assertions) do
        local assertion = structured_contract.copy(assertion_template)
        assertion.assertion_id = authority.assertion_id
        assertion.type = authority.type
        case_result.assertions[index] = assertion
      end
      local manifest = artifacts[value.evidence_manifest_ref].value
      manifest.entries = { manifest.entries[1] }
      manifest.canonical_sha256 = manifest_contract.sha256(manifest, portable_sha256, {
        artifact_root = result_artifact_root(value),
      })
      result_set.evidence_manifest_sha256 = manifest.canonical_sha256
      artifacts[value.case_results_ref].value = {
        schema = results_compat.schema,
        plan_sha256 = value.test_plan_sha256,
        cases = { {
          case_id = "health", kind = "browser", status = "passed", classification = "passed",
          assertions = {
            { type = "browser-callback-observed", passed = true },
            { type = "browser-process-exit-zero", passed = true },
            { type = "browser-whoami-succeeded", passed = true },
            { type = "browser-status-authenticated", passed = true },
          },
          evidence_ref = value.artifact_root .. "/evidence/health-other.json",
        } },
      }
      local terminal = artifacts[value.terminal_summary_ref].value
      terminal.counts = { planned=1,executed=1,passed=1,failed=0,skipped=0,error=0,blocked=0 }
    end, value)
    local ok, failure = pcall(qa_publication.prepare_final_report, value, ports)
    t.eq(ok, false)
    if tostring(failure):find("unsupported-projection", 1, true) == nil then error(tostring(failure)) end
    t.eq(ports.publish_calls(), 0)
    t.eq(ports.report_writes(), 0)
  end,

  test_canonical_and_legacy_disagreement_rejects_before_output = function()
    local value = canonical_request()
    reject_without_output(value, function(artifacts)
      artifacts[value.case_results_ref].value.cases[1].evidence_ref = value.artifact_root
        .. "/evidence/health-other.json"
    end)
  end,

  test_canonical_terminal_summary_bindings_reject_before_output = function()
    for _, mutate in ipairs({
      function(summary) summary.evidence_manifest_ref = nil end,
      function(summary) summary.case_result_set_ref = ".testing/runs/foreign/case-result-set.json" end,
      function(summary, value) summary.case_result_set_ref = value.artifact_root .. "/other-case-result-set.json" end,
    }) do
      local value = canonical_request()
      reject_without_output(value, function(artifacts)
        mutate(artifacts[value.terminal_summary_ref].value, value)
      end)
    end
  end,

  test_completed_canonical_replay_rejects_changed_report_identity_without_provider_calls = function()
    local value = canonical_request()
    local ports = runtime(nil, value)
    qa_publication.prepare_final_report(value, ports)
    ports.reports[value.aggregate_report_ref].case_result_set_ref = value.artifact_root .. "/other-case-result-set.json"
    t.raises(function() qa_publication.prepare_final_report(value, ports) end)
  end,

  test_completed_canonical_replay_rejects_changed_quartet_without_provider_calls = function()
    local value = canonical_request()
    local ports = runtime(nil, value)
    qa_publication.prepare_final_report(value, ports)
    local loads, hashes = ports.artifact_loads(), ports.hash_calls()
    local publishes, reports, artifacts = ports.publish_calls(), ports.report_writes(), ports.artifact_writes()

    local changed = canonical_request()
    changed.evidence_manifest_artifact_sha256 = string.rep("9", 64)
    t.raises(function() qa_publication.prepare_final_report(changed, ports) end)
    t.eq(ports.artifact_loads(), loads)
    t.eq(ports.hash_calls(), hashes)
    t.eq(ports.publish_calls(), publishes)
    t.eq(ports.report_writes(), reports)
    t.eq(ports.artifact_writes(), artifacts)
  end,

  test_finalize_validation_and_bound_artifacts_fail_closed = function()
    local invalid_schema = request()
    invalid_schema.schema = "unknown"
    t.raises(function() qa_publication.prepare_final_report(invalid_schema, runtime()) end)

    local partial = request()
    partial.case_results_sha256 = nil
    t.raises(function() qa_publication.prepare_final_report(partial, runtime()) end)

    local unsafe_pointer = request()
    unsafe_pointer.terminal_summary_ref = ".testing/runs/foreign/terminal-summary.json"
    t.raises(function() qa_publication.prepare_final_report(unsafe_pointer, runtime()) end)

    for _, mutate in ipairs({
      function(value) value.case_results_ref = ".testing/runs/foreign/case-results.json" end,
      function(value) value.case_results_ref = nil; value.case_results_sha256 = nil end,
      function(value) value["test_" .. "plan_ref"] = nil; value.test_plan_sha256 = nil end,
    }) do
      local value = request()
      mutate(value)
      t.raises(function() qa_publication.prepare_final_report(value, runtime()) end)
    end

    local digest_mismatch = runtime(function(artifacts, value)
      artifacts[value.terminal_summary_ref].digest = string.rep("0", 64)
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), digest_mismatch) end)
  end,

  test_reconcile_rejects_plan_identity_mismatch_after_validation = function()
    local ports = runtime(function(artifacts, value)
      artifacts[value.test_plan_ref].value.repository.commit_sha = string.rep("2", 40)
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), ports) end)
  end,

  test_malformed_plan_result_and_environment_fail_closed = function()
    local malformed_plan = runtime(function(artifacts, value)
      artifacts[value.test_plan_ref].value.schema = "unknown"
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), malformed_plan) end)

    local foreign_result = runtime(function(artifacts, value)
      artifacts[value.case_results_ref].value.cases[1].case_id = "foreign"
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), foreign_result) end)

    local missing_browser_gate = runtime(function(artifacts, value)
      artifacts[value.environment_receipt_ref].value.browser_readiness = nil
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), missing_browser_gate) end)

    local foreign_environment = runtime(function(artifacts, value)
      artifacts[value.environment_receipt_ref].value.repository.commit_sha = string.rep("2", 40)
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), foreign_environment) end)
  end,

  test_final_report_rejects_malformed_environment_receipt = function()
    local ports = runtime(function(artifacts, value)
      artifacts[value.environment_receipt_ref].value = {}
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), ports) end)
  end,

  test_final_report_rejects_malformed_cleanup_receipt = function()
    local ports = runtime(function(artifacts, value)
      artifacts[value.cleanup_receipt_ref].value.schema = "unknown"
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), ports) end)
  end,

  test_full_finalization_rejects_valid_non_ready_environment = function()
    local ports = runtime(function(artifacts, value)
      artifacts[value.environment_receipt_ref].value = environment_receipt(value, "blocked")
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), ports) end)
  end,

  test_terminal_finalization_rejects_inconsistent_cleanup_binding = function()
    local value = terminal_request()
    local ports = runtime(function(artifacts)
      local environment = environment_receipt(value, "blocked")
      environment.cleanup_receipt_ref.ref = value.artifact_root
        .. "/foreign/cleanup-receipt-complete.json"
      artifacts[value.environment_receipt_ref].value = environment
    end, value)
    t.raises(function() qa_publication.prepare_final_report(value, ports) end)
  end,

  test_final_report_reconciles_terminal_cases_and_verified_cleanup = function()
    local ports = runtime()
    local prepared = qa_publication.prepare_final_report(request(), ports)

    t.eq(prepared.status, "pending")
    t.eq(prepared.report.schema, "test-publication.qa-aggregate-report.v1")
    t.eq(prepared.report.finalization_kind, "full")
    t.eq(prepared.report.status, "failed")
    t.eq(prepared.report.counts.planned, 2)
    t.eq(prepared.report.counts.executed, 2)
    t.eq(prepared.report.counts.passed, 1)
    t.eq(prepared.report.counts.failed, 1)
    t.eq(prepared.report.cleanup_receipt_ref, request().cleanup_receipt_ref)
    t.eq(prepared.comment_request.handoff.stage, "aggregate-report")

    local explicit_value = request("github-comment-v1")
    local explicit = qa_publication.prepare_final_report(explicit_value, runtime(nil, explicit_value))
    t.eq(explicit.status, "pending")
    t.eq(explicit.report.channel, nil)
    t.eq(explicit.report.github_publication_occurred, nil)
    t.is_true(explicit.report.artifact_links.terminal_summary:find("https://github.com/", 1, true) ~= nil)
  end,

  test_filesystem_finalization_materializes_local_links_and_receipt_without_github = function()
    local value = request("filesystem-dry-run-v1")
    local ports = runtime(nil, value)
    local prepared = qa_publication.prepare_final_report(value, ports)

    t.eq(prepared.status, "published")
    t.eq(prepared.comment_request, nil)
    t.eq(prepared.receipt.channel, "filesystem-dry-run-v1")
    t.eq(prepared.receipt.github_publication_occurred, false)
    t.eq(prepared.report.channel, "filesystem-dry-run-v1")
    t.eq(prepared.report.github_publication_occurred, false)
    for _, link in pairs(prepared.report.artifact_links) do
      t.is_true(link:sub(1, #value.artifact_root + 1) == value.artifact_root .. "/")
      t.eq(link:find("github.com", 1, true), nil)
    end
    t.eq(ports.report_writes(), 1)

    local replay = qa_publication.prepare_final_report(value, ports)
    t.eq(replay.replayed, true)
    t.eq(replay.status, "published")
    t.eq(replay.comment_request, nil)
    t.eq(replay.receipt.receipt_ref, prepared.receipt.receipt_ref)
    t.eq(ports.report_writes(), 1)
  end,

  test_filesystem_finalization_rejects_missing_or_mismatched_materialization_receipt = function()
    for _, options in ipairs({
      { missing_materialization_receipt = true },
      { materialization_receipt_digest_mismatch = true },
      { materialization_receipt_binding_mismatch = true },
    }) do
      local value = request("filesystem-dry-run-v1")
      local ports = runtime(nil, value, options)
      t.raises(function() qa_publication.prepare_final_report(value, ports) end)
      t.eq(ports.report_writes(), 0)
    end
  end,

  test_terminal_summary_variant_writes_and_publishes_real_aggregate_report = function()
    local value = terminal_request()
    local blocked_counts = { planned = 0, executed = 0, passed = 0, failed = 0, skipped = 0, error = 0, blocked = 1 }
    local ports = runtime(function(artifacts)
      artifacts[value.terminal_summary_ref].value = terminal_summary(value, "blocked", blocked_counts)
      artifacts[value.terminal_summary_ref].value.structured_plan_ref = value.artifact_root .. "/partial-plan.json"
      artifacts[value.environment_receipt_ref].value = environment_receipt(value, "blocked")
    end, value)
    local prepared = qa_publication.prepare_final_report(value, ports)

    t.eq(prepared.status, "pending")
    t.eq(prepared.report.finalization_kind, "terminal-summary")
    t.eq(prepared.report.status, "blocked")
    t.eq(prepared.report.counts.blocked, 1)
    t.eq(prepared.report.artifact_links.test_plan, nil)
    t.is_true(prepared.report.artifact_links.terminal_summary ~= nil)
    t.eq(prepared.comment_request.handoff.stage, "aggregate-report")
    t.eq(ports.report_writes(), 1)
  end,

  test_final_report_replay_reuses_existing_report_without_second_write = function()
    local ports = runtime()
    local first = qa_publication.prepare_final_report(request(), ports)
    qa_publication.acknowledge_comment({
      schema = "github-proxy.comment-written.v1", comment_id = "501",
      request_dedup_key = first.comment_request.dedup_key,
      handoff = first.comment_request.handoff,
    }, ports)

    local replay = qa_publication.prepare_final_report(request(), ports)
    t.eq(replay.replayed, true)
    t.eq(replay.status, "published")
    t.eq(replay.comment_request, nil)
    t.eq(replay.report.schema, "test-publication.qa-aggregate-report.v1")
    t.eq(ports.report_writes(), 1)
  end,

  test_final_report_replay_rejects_foreign_ledger_changed_pointer_and_changed_report = function()
    local foreign = runtime()
    qa_publication.prepare_final_report(request(), foreign)
    foreign.state().run_id = "foreign"
    t.raises(function() qa_publication.prepare_final_report(request(), foreign) end)

    local moved = runtime()
    qa_publication.prepare_final_report(request(), moved)
    moved.state().checkpoints["aggregate-report/1"].artifact_ref = request().artifact_root .. "/other.json"
    t.raises(function() qa_publication.prepare_final_report(request(), moved) end)

    local changed = runtime()
    qa_publication.prepare_final_report(request(), changed)
    changed.artifacts[request().aggregate_report_ref].value.trace_id = "foreign"
    t.raises(function() qa_publication.prepare_final_report(request(), changed) end)
  end,

  test_final_report_rejects_planned_case_without_terminal_disposition = function()
    local ports = runtime(function(artifacts, value)
      table.remove(artifacts[value.case_results_ref].value.cases, 2)
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), ports) end)
  end,

  test_final_report_consumes_optional_defect_publication_receipt = function()
    local value = request()
    value.defect_publication_receipt_ref = value.artifact_root .. "/defect-publication-receipt.json"
    value.defect_publication_receipt_sha256 = string.rep("9", 64)
    local ports = runtime(function(artifacts)
      artifacts[value.defect_publication_receipt_ref] = { digest = value.defect_publication_receipt_sha256, value = {
        schema = "test-publication.defect-publication-receipt.v1",
        cases = {
          { case_id = "version", status = "created", issue_url = "https://github.com/owner/repo/issues/501" },
          { case_id = "health", status = "summary-only" },
        },
      } }
    end, value)
    local prepared = qa_publication.prepare_final_report(value, ports)
    t.eq(prepared.report.defect_issue_links[1], "https://github.com/owner/repo/issues/501")
  end,

  test_final_report_rejects_malformed_defect_receipt_and_report_write_failure = function()
    local value = request()
    value.defect_publication_receipt_ref = value.artifact_root .. "/defect-publication-receipt.json"
    value.defect_publication_receipt_sha256 = string.rep("9", 64)
    local malformed = runtime(function(artifacts)
      artifacts[value.defect_publication_receipt_ref] = {
        digest = value.defect_publication_receipt_sha256,
        value = { schema = "unknown", cases = {} },
      }
    end, value)
    t.raises(function() qa_publication.prepare_final_report(value, malformed) end)

    local write_failure = runtime()
    write_failure.write_report = function() return { status = "blocked" } end
    t.raises(function() qa_publication.prepare_final_report(request(), write_failure) end)
  end,

  test_final_report_rejects_unverified_cleanup = function()
    local ports = runtime(function(artifacts, value)
      artifacts[value.cleanup_receipt_ref].value.status = "incomplete"
      artifacts[value.cleanup_receipt_ref].value.attempted_resources[1].status = "remaining"
      artifacts[value.cleanup_receipt_ref].value.verified_removals = {}
      artifacts[value.cleanup_receipt_ref].value.remaining_resources = {
        { resource_id = "workspace", resource_kind = "workspace", cleanup_ref = { kind = "runtime-cleanup", ref = "remaining-workspace" } },
      }
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), ports) end)
  end,

  test_finalize_request_and_terminal_artifacts_reject_mutation_matrix = function()
    local request_mutations = {
      function(value) value.browser_readiness_ref = "foreign" end,
      function(value) value.browser_readiness_sha256 = nil end,
      function(value) value.test_plan_ref = ".testing/runs/foreign/test-plan.json" end,
      function(value) value.case_results_ref = nil end,
      function(value) value.browser_readiness_ref = nil value.browser_readiness_sha256 = nil end,
      function(value)
        value.defect_publication_receipt_ref = value.artifact_root .. "/defect-receipt.json"
      end,
    }
    for _, mutate in ipairs(request_mutations) do
      local value = request()
      local ports = runtime(nil, value)
      mutate(value)
      t.raises(function() qa_publication.prepare_final_report(value, ports) end)
    end

    local artifact_mutations = {
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.counts.failed = -1 end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.run_id = "foreign" end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.structured_plan_ref = "foreign" end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.browser_readiness_sha256 = nil end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.case_results_ref = value.artifact_root .. "/other.json" end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.interruption = "stopped" end,
      function(artifacts, value) artifacts[value.browser_readiness_ref].value.source_ref.ref = "foreign" end,
      function(artifacts, value) artifacts[value.test_plan_ref].value.cases[2].case_id = "health" end,
      function(artifacts, value) artifacts[value.case_results_ref].value.plan_sha256 = string.rep("0", 64) end,
      function(artifacts, value) artifacts[value.case_results_ref].value.cases[1].evidence_ref = "foreign" end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.counts.failed = 0 end,
    }
    for _, mutate in ipairs(artifact_mutations) do
      local ports = runtime(mutate)
      t.raises(function() qa_publication.prepare_final_report(request(), ports) end)
    end
  end,
}
