local defect_publication = require("defect_publication")
local manifest_contract = require("contract.testing_evidence_manifest")
local results_compat = require("contract.testing_results_compat")
local structured_contract = require("contract.structured_execution")
local t = fkst.test

local commit_sha = string.rep("1", 40)
local plan_sha = string.rep("a", 64)
local results_sha = string.rep("b", 64)
local drafts_sha = string.rep("c", 64)
local result_set_artifact_sha = string.rep("7", 64)
local manifest_artifact_sha = string.rep("8", 64)

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

local function request()
  local root = ".testing/runs/run-99"
  return {
    schema = "test-publication.defect-publication.request.v1",
    publication = {
      schema = "test-publication.publication-request.v1",
      publication_kind = "testing-summary", channel = "testing", severity = "failure",
      subject = "Testing failed: structured-execution", status = "failed", job = "structured-execution",
      artifact_root = root, metadata_path = root .. "/metadata.json",
      test_plan_path = root .. "/test-plan.json", case_results_path = root .. "/case-results.json",
      execution_path = root .. "/execution.json", source_ref = { kind = "workflow-qa", ref = "run-99" },
      trace_id = "trace-defect-publication", dedup_key = "publication-defect-run",
    },
    repository = { slug = "owner/repo", commit_sha = commit_sha },
    plan_sha256 = plan_sha,
    case_results_ref = root .. "/case-results.json", case_results_sha256 = results_sha,
    issue_drafts_ref = root .. "/defect-issue-drafts.json", issue_drafts_sha256 = drafts_sha,
    ledger_ref = root .. "/defect-publication-ledger.json",
    receipt_ref = root .. "/defect-publication-receipt.json",
    trace_id = "trace-defect-publication", dedup_key = "dedup-defect-publication",
  }
end

local function canonical_request()
  local value = request()
  local root = value.publication.artifact_root
  value.publication.case_result_set_path = root .. "/case-result-set.json"
  value.publication.case_result_set_artifact_sha256 = result_set_artifact_sha
  value.publication.evidence_manifest_path = root .. "/evidence-manifest.json"
  value.publication.evidence_manifest_artifact_sha256 = manifest_artifact_sha
  value.case_result_set_ref = value.publication.case_result_set_path
  value.case_result_set_artifact_sha256 = result_set_artifact_sha
  value.evidence_manifest_ref = value.publication.evidence_manifest_path
  value.evidence_manifest_artifact_sha256 = manifest_artifact_sha
  return value
end

local function preparation_request(source)
  local value = source or request()
  value.publication.dedup_key = value.dedup_key
  value.publication.publication_dry_run = true
  local prepared = {
    schema = "test-publication.defect-preparation.request.v1",
    publication = value.publication,
    repository = value.repository,
    run_id = "run-99",
    plan_ref = value.publication.test_plan_path,
    plan_sha256 = value.plan_sha256,
    case_results_ref = value.case_results_ref,
    case_results_sha256 = value.case_results_sha256,
    issue_drafts_ref = value.issue_drafts_ref,
    ledger_ref = value.ledger_ref,
    receipt_ref = value.receipt_ref,
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
  }
  for _, field in ipairs({
    "case_result_set_ref", "case_result_set_artifact_sha256",
    "evidence_manifest_ref", "evidence_manifest_artifact_sha256",
  }) do
    if value[field] ~= nil then prepared[field] = value[field] end
  end
  return prepared
end

local function canonical_preparation_request()
  return preparation_request(canonical_request())
end

local function structured_plan(value)
  return {
    schema = "testing-structured-plan.v2",
    execution_mode = "structured-api-cli",
    repository = { url = "https://github.com/owner/repo.git", commit_sha = commit_sha },
    environment_receipt_sha256 = string.rep("d", 64),
    browser_readiness_sha256 = string.rep("b", 64),
    case_catalog_sha256 = string.rep("e", 64),
    module_plan_sha256 = string.rep("f", 64),
    cases = {
      { case_id = "version", kind = "cli", argv = { "fixture", "--version" }, timeout_seconds = 10,
        assertions = { { type = "exit-code", expected = 0 } } },
      { case_id = "health", kind = "http", timeout_seconds = 10,
        request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} },
        assertions = { { type = "status-code", expected = 200 } } },
    },
    residual_risk_case_ids = {},
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
  }
end

local function legacy_results(value)
  local root = value.publication.artifact_root
  return {
    schema = "testing-structured-case-results.v1", plan_sha256 = plan_sha,
    cases = {
      { case_id = "version", kind = "cli", status = "failed", classification = "product-defect", assertions = { { type = "exit-code", passed = false } }, evidence_ref = root .. "/evidence/version.json" },
      { case_id = "health", kind = "http", status = "error", classification = "environment-session-issue", assertions = {}, evidence_ref = root .. "/evidence/health.json" },
    },
  }
end

local function canonical_results(value)
  local root = value.publication.artifact_root
  local repository_url = "https://github.com/owner/repo.git"
  local function metadata(case_id, evidence_id, sha256)
    local ref = root .. "/evidence/" .. case_id .. ".json"
    return {
      case_id = case_id,
      timing = {
        started_at = "2026-08-14T00:00:00Z", completed_at = "2026-08-14T00:00:01Z",
        duration_ms = 1000,
      },
      evidence = {
        evidence_id = evidence_id, role = "sanitized-json", sha256 = sha256,
        media_type = "application/json", size_bytes = 128,
        producer = "testing-runner", producer_version = "v1",
        created_at = "2026-08-14T00:00:01Z", sensitivity = "internal",
        redaction_classification = "none", policy_version = "v1", policy_status = "approved",
        provenance = { source_kind = "artifact", source_ref = ref, source_sha256 = sha256 },
      },
    }
  end
  return results_compat.canonicalize_v1(legacy_results(value), {
    artifact_root = root,
    plan_sha256 = plan_sha,
    plan = structured_plan(value),
    repository = {
      id = commit_sha,
      source_ref = { kind = "git", ref = repository_url .. "@" .. commit_sha },
      source_sha256 = portable_sha256(repository_url .. "\n" .. commit_sha),
    },
    run_id = value.run_id or value.publication.source_ref.ref,
    plan_ref = { kind = "artifact", ref = value.plan_ref or value.publication.test_plan_path },
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
    case_metadata = {
      metadata("version", "evidence-version", string.rep("3", 64)),
      metadata("health", "evidence-health", string.rep("4", 64)),
    },
    sha256_bytes = portable_sha256,
  })
end

local function runtime(options)
  options = options or {}
  local state
  local writes = {}
  local write_count = 0
  local save_count = 0
  local artifacts_enabled = true
  local value = options.canonical and canonical_request() or request()
  local artifacts = {
    [value.publication.test_plan_path] = { digest = plan_sha, value = structured_plan(value) },
    [value.case_results_ref] = { digest = results_sha, value = legacy_results(value) },
    [value.issue_drafts_ref] = { digest = drafts_sha, value = {
      schema = "test-publication.defect-issue-drafts.v1", plan_sha256 = plan_sha,
      cases = {
        { case_id = "version", title = "CLI version output differs", expected_summary = "Exit code 0", actual_summary = "Exit code 1", evidence_ref = value.publication.artifact_root .. "/evidence/version.json" },
      },
    } },
  }
  if options.canonical then
    local canonical = canonical_results(value)
    canonical.result_set.evidence_manifest_artifact_sha256 = value.evidence_manifest_artifact_sha256
    canonical.result_set.evidence_manifest_ref.sha256 = value.evidence_manifest_artifact_sha256
    artifacts[value.case_result_set_ref] = {
      digest = value.case_result_set_artifact_sha256, value = canonical.result_set,
    }
    artifacts[value.evidence_manifest_ref] = {
      digest = value.evidence_manifest_artifact_sha256, value = canonical.evidence_manifest,
    }
  end
  if options.mutate then options.mutate(artifacts, value) end
  local ports = {
    load_ledger = function() return state end,
    save_ledger = function(_, next_state, expected)
      if options.save_failure then return false end
      if state ~= nil and state.version ~= expected then return false end
      if state == nil and expected ~= 0 then return false end
      save_count = save_count + 1
      state = next_state
      return true
    end,
    load_artifact = function(path)
      if not artifacts_enabled then return nil end
      return artifacts[path]
    end,
    write_artifact = function(path, artifact)
      if options.write_failure then return false end
      write_count = write_count + 1
      writes[path] = artifact
      artifacts[path] = { digest = drafts_sha, value = artifact }
      return true
    end,
    state = function() return state end,
    write_count = function() return write_count end,
    save_count = function() return save_count end,
    disable_artifacts = function() artifacts_enabled = false end,
    artifacts = artifacts,
    writes = writes,
  }
  if options.canonical then
    ports.sha256_bytes = function(bytes, artifact_root)
      if artifact_root ~= value.publication.artifact_root then error("unexpected hash artifact root") end
      return portable_sha256(bytes)
    end
  end
  return ports
end

local function reject_canonical_before_outputs(mutate)
  local preparation_ports = runtime({
    canonical = true,
    mutate = function(artifacts, value)
      artifacts[value.issue_drafts_ref] = nil
      mutate(artifacts, value)
    end,
  })
  t.raises(function()
    defect_publication.prepare_defects(canonical_preparation_request(), preparation_ports)
  end)
  t.eq(preparation_ports.write_count(), 0)
  t.eq(preparation_ports.save_count(), 0)

  local publication_ports = runtime({ canonical = true, mutate = mutate })
  t.raises(function() defect_publication.prepare(canonical_request(), publication_ports) end)
  t.eq(publication_ports.write_count(), 0)
  t.eq(publication_ports.save_count(), 0)
end

return {
  test_canonical_preparation_materializes_manifest_bound_draft_and_one_intent = function()
    local value = canonical_preparation_request()
    local ports = runtime({
      canonical = true,
      mutate = function(artifacts) artifacts[value.issue_drafts_ref] = nil end,
    })
    local prepared = defect_publication.prepare_defects(value, ports)

    for _, field in ipairs({
      "case_result_set_ref", "case_result_set_artifact_sha256",
      "evidence_manifest_ref", "evidence_manifest_artifact_sha256",
    }) do
      t.eq(prepared.defect_request[field], value[field])
    end
    t.eq(prepared.defect_request.publication.case_result_set_path,
      value.publication.case_result_set_path)
    t.eq(prepared.defect_request.publication.evidence_manifest_path,
      value.publication.evidence_manifest_path)
    local drafts = ports.writes[value.issue_drafts_ref]
    local manifest = ports.artifacts[value.evidence_manifest_ref].value
    t.eq(#drafts.cases, 1)
    t.eq(drafts.cases[1].case_id, "version")
    t.eq(manifest.entries[1].case_id, "version")
    t.eq(drafts.cases[1].evidence_ref, manifest.entries[1].artifact_ref.ref)
    t.eq(ports.write_count(), 1)

    local publication = defect_publication.prepare(prepared.defect_request, ports)
    t.eq(#publication.issue_requests, 1)
  end,

  test_canonical_browser_projection_mismatch_rejects_before_outputs = function()
    local value = canonical_request()
    value.publication.job = "ai-browser-control"
    value.publication.execution_path = value.publication.artifact_root .. "/browser-agent-execution.json"
    local ports = runtime({ canonical = true, mutate = function(artifacts)
      local plan = artifacts[value.publication.test_plan_path].value
      plan.execution_mode = "agentic-browser"
      plan.cases = { {
        case_id="version",kind="browser",goal="Authenticate the existing user.",
        success_conditions={"All deterministic login signals are verified."},completion_assertions={
          {assertion_id="callback-observed",type="browser-callback-observed",required=true,completion_field="callback_observed"},
          {assertion_id="process-exit-zero",type="browser-process-exit-zero",required=true,completion_field="process_exit_zero"},
          {assertion_id="whoami-succeeded",type="browser-whoami-succeeded",required=true,completion_field="whoami_succeeded"},
          {assertion_id="status-authenticated",type="browser-status-authenticated",required=true,completion_field="status_authenticated"},
        },
      } }
      local result_set = artifacts[value.case_result_set_ref].value
      result_set.cases = { result_set.cases[1] }
      local case = result_set.cases[1]
      case.execution_mode = "browser"
      local template = structured_contract.copy(case.assertions[1])
      case.assertions = {}
      for index, authority in ipairs(plan.cases[1].completion_assertions) do
        local assertion = structured_contract.copy(template)
        assertion.assertion_id = authority.assertion_id; assertion.type = authority.type
        assertion.required = true; assertion.status = index == 1 and "failed" or "skipped"
        assertion.classification = index == 1 and "assertion_failure" or "skipped"
        case.assertions[index] = assertion
      end
      local manifest = artifacts[value.evidence_manifest_ref].value
      manifest.entries = { manifest.entries[1] }; manifest.entries[1].assertion_id = nil
      manifest.canonical_sha256 = manifest_contract.sha256(manifest, portable_sha256, {
        artifact_root=value.publication.artifact_root,
      })
      result_set.evidence_manifest_sha256 = manifest.canonical_sha256
      artifacts[value.case_results_ref].value = {
        schema = results_compat.schema,
        plan_sha256 = value.plan_sha256,
        cases = { {
          case_id = "version", kind = "browser", status = "failed",
          classification = "product-defect",
          assertions = {
            { type = "browser-callback-observed", passed = false },
            { type = "browser-process-exit-zero", passed = false },
            { type = "browser-whoami-succeeded", passed = false },
            { type = "browser-status-authenticated", passed = false },
          },
          evidence_ref = value.publication.artifact_root .. "/evidence/version-other.json",
        } },
      }
    end })
    local ok, failure = pcall(defect_publication.prepare, value, ports)
    t.eq(ok, false)
    if tostring(failure):find("canonical and legacy case results differ", 1, true) == nil then
      error(tostring(failure))
    end
    t.eq(ports.write_count(), 0); t.eq(ports.save_count(), 0)
  end,

  test_canonical_request_bindings_reject_before_writes = function()
    for _, mutate in ipairs({
      function(value) value.case_result_set_artifact_sha256 = nil end,
      function(value)
        value.publication.case_result_set_path = nil
        value.publication.evidence_manifest_path = nil
      end,
      function(value) value.publication.evidence_manifest_path = nil end,
      function(value) value.case_result_set_ref = value.publication.artifact_root .. "/other-result-set.json" end,
    }) do
      local value = canonical_preparation_request()
      mutate(value)
      local ports = runtime({ canonical = true })
      t.raises(function() defect_publication.prepare_defects(value, ports) end)
      t.eq(ports.write_count(), 0)
      t.eq(ports.save_count(), 0)
    end
  end,

  test_canonical_requires_hash_port_before_any_output = function()
    local preparation_ports = runtime({ canonical = true })
    preparation_ports.sha256_bytes = nil
    t.raises(function()
      defect_publication.prepare_defects(canonical_preparation_request(), preparation_ports)
    end)
    t.eq(preparation_ports.write_count(), 0)
    t.eq(preparation_ports.save_count(), 0)

    local publication_ports = runtime({ canonical = true })
    publication_ports.sha256_bytes = nil
    t.raises(function() defect_publication.prepare(canonical_request(), publication_ports) end)
    t.eq(publication_ports.write_count(), 0)
    t.eq(publication_ports.save_count(), 0)
  end,

  test_canonical_artifact_failures_reject_before_drafts_receipts_or_intents = function()
    for _, mutate in ipairs({
      function(artifacts, value)
        artifacts[value.case_result_set_ref].digest = string.rep("0", 64)
      end,
      function(artifacts, value)
        artifacts[value.evidence_manifest_ref].digest = string.rep("0", 64)
      end,
      function(artifacts, value)
        artifacts[value.evidence_manifest_ref].value.canonical_sha256 = string.rep("0", 64)
      end,
      function(artifacts, value)
        artifacts[value.case_result_set_ref].value.run_id = "foreign-run"
      end,
      function(artifacts, value)
        artifacts[value.case_result_set_ref].value.plan_ref.ref = value.publication.artifact_root .. "/foreign-plan.json"
      end,
      function(artifacts, value)
        artifacts[value.case_result_set_ref].value.trace_id = "foreign-trace"
      end,
      function(artifacts, value)
        artifacts[value.case_result_set_ref].value.evidence_manifest_ref.ref = value.publication.artifact_root
          .. "/other-evidence-manifest.json"
      end,
      function(artifacts, value)
        artifacts[value.case_results_ref].value.cases[1].evidence_ref = value.publication.artifact_root
          .. "/evidence/version-other.json"
      end,
    }) do
      reject_canonical_before_outputs(mutate)
    end
  end,

  test_canonical_ledger_replay_rejects_changed_digest_or_ref_without_outputs = function()
    local ports = runtime({ canonical = true })
    local first = defect_publication.prepare(canonical_request(), ports)
    t.eq(#first.issue_requests, 1)
    t.eq(ports.save_count(), 1)
    local version = ports.state().version

    for _, mutate in ipairs({
      function(value) value.evidence_manifest_artifact_sha256 = string.rep("9", 64) end,
      function(value)
        value.case_result_set_ref = value.publication.artifact_root .. "/other-result-set.json"
        value.publication.case_result_set_path = value.case_result_set_ref
      end,
    }) do
      local changed = canonical_request()
      mutate(changed)
      t.raises(function() defect_publication.prepare(changed, ports) end)
      t.eq(ports.write_count(), 0)
      t.eq(ports.save_count(), 1)
      t.eq(ports.state().version, version)
    end
  end,

  test_defect_preparation_precise_fail_closed_matrix = function()
    do
      local value = preparation_request()
      value.schema = "other"
      t.raises(function() defect_publication.prepare_defects(value, runtime()) end)
    end
    do
      local ports = runtime({ mutate = function(artifacts)
        artifacts[request().case_results_ref].value.cases[1].assertions[1].passed = "false"
      end })
      t.raises(function() defect_publication.prepare_defects(preparation_request(), ports) end)
    end
    do
      local value = preparation_request()
      value.run_id = ""
      t.raises(function() defect_publication.prepare_defects(value, runtime()) end)
    end
    do
      local value = preparation_request()
      value.publication.source_ref.ref = "foreign"
      t.raises(function() defect_publication.prepare_defects(value, runtime()) end)
    end
    do
      local ports = runtime({ mutate = function(artifacts)
        artifacts[request().case_results_ref].value.cases[2].kind = "cli"
      end })
      t.raises(function() defect_publication.prepare_defects(preparation_request(), ports) end)
    end
    do
      local ports = runtime({ mutate = function(artifacts)
        artifacts[request().publication.test_plan_path].value.trace_id = "foreign"
      end })
      t.raises(function() defect_publication.prepare_defects(preparation_request(), ports) end)
    end
    do
      local ports = runtime({
        write_failure = true,
        mutate = function(artifacts) artifacts[request().issue_drafts_ref] = nil end,
      })
      t.raises(function() defect_publication.prepare_defects(preparation_request(), ports) end)
    end
  end,

  test_publication_owned_preparation_materializes_bounded_drafts_and_replays = function()
    local ports = runtime({ mutate = function(artifacts)
      artifacts[request().issue_drafts_ref] = nil
    end })
    local prepared = defect_publication.prepare_defects(preparation_request(), ports)

    t.eq(prepared.replayed, false)
    t.eq(prepared.defect_request.schema, "test-publication.defect-publication.request.v1")
    t.eq(prepared.defect_request.issue_drafts_sha256, drafts_sha)
    t.eq(ports.writes[request().issue_drafts_ref].schema, "test-publication.defect-issue-drafts.v1")
    t.eq(#ports.writes[request().issue_drafts_ref].cases, 1)
    t.eq(ports.writes[request().issue_drafts_ref].cases[1].case_id, "version")
    t.is_true(ports.writes[request().issue_drafts_ref].cases[1].actual_summary:find("exit-code", 1, true) ~= nil)
    t.eq(ports.write_count(), 1)

    local replay = defect_publication.prepare_defects(preparation_request(), ports)
    t.eq(replay.replayed, true)
    t.eq(replay.issue_drafts_sha256, drafts_sha)
    t.eq(ports.write_count(), 1)

    local publication = defect_publication.prepare(prepared.defect_request, ports)
    t.eq(#publication.issue_requests, 1)
  end,

  test_defect_preparation_rejects_changed_deterministic_pointer = function()
    local ports = runtime({ mutate = function(artifacts)
      artifacts[request().issue_drafts_ref].value.cases[1].title = "foreign draft"
    end })
    t.raises(function() defect_publication.prepare_defects(preparation_request(), ports) end)
  end,

  test_product_defect_creates_one_github_intent_and_other_outcomes_stay_summary_only = function()
    local ports = runtime()
    local prepared = defect_publication.prepare(request(), ports)

    t.eq(#prepared.issue_requests, 1)
    t.eq(prepared.issue_requests[1].schema, "github-proxy.issue-create.v1")
    t.eq(prepared.issue_requests[1].repo, "owner/repo")
    t.eq(prepared.issue_requests[1].labels[1], "fkst-dev:enabled")
    t.is_true(prepared.issue_requests[1].body:find("version", 1, true) ~= nil)
    t.is_true(prepared.issue_requests[1].body:find("Exit code 0", 1, true) ~= nil)
    t.is_true(#prepared.issue_requests[1].title <= 240)
    t.is_true(#prepared.issue_requests[1].body <= 12000)
    t.is_true(#prepared.issue_requests[1].dedup_key <= 512)
    t.is_true(#prepared.issue_requests[1].source_ref.ref <= 200)
    t.eq(prepared.receipt, nil)
    t.eq(ports.state().cases.health.status, "summary-only")
    t.eq(ports.state().cases.version.status, "pending")
  end,

  test_issue_acknowledgement_writes_terminal_receipt_and_replay_is_idempotent = function()
    local ports = runtime()
    local prepared = defect_publication.prepare(request(), ports)
    local intent = prepared.issue_requests[1]
    local written = {
      schema = "github-proxy.issue-written.v1", status = "created", issue_number = 501,
      issue_url = "https://github.com/owner/repo/issues/501",
      request_dedup_key = intent.dedup_key, handoff = intent.handoff,
    }
    local acknowledged = defect_publication.acknowledge_issue(written, ports)

    t.eq(acknowledged.receipt.schema, "test-publication.defect-publication-receipt.v1")
    t.eq(acknowledged.receipt.status, "published")
    t.eq(acknowledged.receipt.cases[1].status, "created")
    t.eq(acknowledged.receipt.cases[1].issue_url, written.issue_url)
    t.eq(acknowledged.receipt.cases[2].status, "summary-only")
    t.eq(ports.write_count(), 1)

    local replay = defect_publication.acknowledge_issue(written, ports)
    t.eq(replay.replayed, true)
    t.eq(replay.receipt.receipt_ref, request().receipt_ref)
    t.eq(ports.write_count(), 1)

    local changed = {}
    for field, value in pairs(written) do changed[field] = value end
    changed.status = "deduplicated"
    t.raises(function() defect_publication.acknowledge_issue(changed, ports) end)
  end,

  test_missing_github_ack_replays_same_intent_without_receipt = function()
    local ports = runtime()
    local first = defect_publication.prepare(request(), ports)
    ports.disable_artifacts()
    local replay = defect_publication.prepare(request(), ports)

    t.eq(replay.replayed, true)
    t.eq(#replay.issue_requests, 1)
    t.eq(replay.issue_requests[1].dedup_key, first.issue_requests[1].dedup_key)
    t.eq(replay.receipt, nil)
    t.eq(ports.write_count(), 0)
  end,

  test_missing_product_defect_draft_records_blocked_receipt_without_issue = function()
    local ports = runtime({ mutate = function(artifacts)
      artifacts[request().issue_drafts_ref].value.cases = {}
    end })
    local prepared = defect_publication.prepare(request(), ports)

    t.eq(#prepared.issue_requests, 0)
    t.eq(prepared.receipt.status, "blocked")
    t.eq(prepared.receipt.cases[1].status, "blocked")
    t.eq(prepared.receipt.cases[2].status, "summary-only")
  end,

  test_malformed_or_foreign_inputs_and_partial_receipt_failure_fail_closed = function()
    local inline = request()
    inline.report_body = "not allowed"
    t.raises(function() defect_publication.prepare(inline, runtime()) end)

    local mismatched = runtime({ mutate = function(artifacts)
      artifacts[request().case_results_ref].value.plan_sha256 = string.rep("9", 64)
    end })
    t.raises(function() defect_publication.prepare(request(), mismatched) end)

    local unsafe = runtime({ mutate = function(artifacts)
      artifacts[request().issue_drafts_ref].value.cases[1].evidence_ref = "inline evidence"
    end })
    t.raises(function() defect_publication.prepare(request(), unsafe) end)

    local inline_result = runtime({ mutate = function(artifacts)
      artifacts[request().case_results_ref].value.cases[1].raw_body = "not allowed"
    end })
    t.raises(function() defect_publication.prepare(request(), inline_result) end)

    local unsafe_result = runtime({ mutate = function(artifacts)
      artifacts[request().case_results_ref].value.cases[1].status = "unknown"
    end })
    t.raises(function() defect_publication.prepare(request(), unsafe_result) end)

    local ports = runtime({ write_failure = true })
    local prepared = defect_publication.prepare(request(), ports)
    local intent = prepared.issue_requests[1]
    t.raises(function()
      defect_publication.acknowledge_issue({
        schema = "github-proxy.issue-written.v1", status = "created", issue_number = 501,
        issue_url = "https://github.com/owner/repo/issues/501",
        request_dedup_key = intent.dedup_key, handoff = intent.handoff,
      }, ports)
    end)
    t.eq(ports.state().cases.version.status, "pending")
  end,

  test_request_artifact_and_ledger_failures_are_rejected = function()
    local unknown = request()
    unknown.schema = "unknown"
    t.raises(function() defect_publication.prepare(unknown, runtime()) end)

    local repository = request()
    repository.repository.commit_sha = "mutable"
    t.raises(function() defect_publication.prepare(repository, runtime()) end)

    local publication = request()
    publication.publication.job = "module-test-loop"
    t.raises(function() defect_publication.prepare(publication, runtime()) end)

    local source_ref = request()
    source_ref.publication.source_ref.inline_body = "not allowed"
    t.raises(function() defect_publication.prepare(source_ref, runtime()) end)

    local binding = request()
    binding.receipt_ref = ".testing/runs/other/receipt.json"
    t.raises(function() defect_publication.prepare(binding, runtime()) end)

    local missing_artifact = runtime({ mutate = function(artifacts)
      artifacts[request().case_results_ref] = nil
    end })
    t.raises(function() defect_publication.prepare(request(), missing_artifact) end)

    local malformed_drafts = runtime({ mutate = function(artifacts)
      artifacts[request().issue_drafts_ref].value.schema = "unknown"
    end })
    t.raises(function() defect_publication.prepare(request(), malformed_drafts) end)

    t.raises(function() defect_publication.prepare(request(), runtime({ save_failure = true })) end)
  end,

  test_issue_acknowledgement_rejects_malformed_missing_and_mismatched_state = function()
    t.raises(function()
      defect_publication.acknowledge_issue({
        schema = "unknown", status = "created", issue_number = 501,
        issue_url = "https://github.com/owner/repo/issues/501", request_dedup_key = "dedup",
        handoff = {
          kind = "test-publication.product-defect", ledger_ref = request().ledger_ref,
          case_id = "version", request_dedup_key = "dedup",
        },
      }, runtime())
    end)

    local missing = runtime()
    t.raises(function()
      defect_publication.acknowledge_issue({
        schema = "github-proxy.issue-written.v1", status = "created", issue_number = 501,
        issue_url = "https://github.com/owner/repo/issues/501", request_dedup_key = "dedup",
        handoff = {
          kind = "test-publication.product-defect", ledger_ref = request().ledger_ref,
          case_id = "version", request_dedup_key = "dedup",
        },
      }, missing)
    end)

    local ports = runtime()
    local intent = defect_publication.prepare(request(), ports).issue_requests[1]
    t.raises(function()
      defect_publication.acknowledge_issue({
        schema = "github-proxy.issue-written.v1", status = "created", issue_number = 501,
        issue_url = "https://github.com/owner/repo/issues/501", request_dedup_key = "changed",
        handoff = {
          kind = intent.handoff.kind, ledger_ref = intent.handoff.ledger_ref,
          case_id = intent.handoff.case_id, request_dedup_key = "changed",
        },
      }, ports)
    end)
  end,

  test_production_ports_require_complete_runtime = function()
    local previous_runtime = _G.defect_publication_runtime
    local previous_cli = _G.qa_publication_runtime_cli
    _G.defect_publication_runtime = nil
    _G.qa_publication_runtime_cli = nil
    t.raises(function() defect_publication.production_ports() end)
    local ports = {}
    for _, name in ipairs({ "load_ledger", "save_ledger", "load_artifact", "write_artifact" }) do
      ports[name] = function() return true end
    end
    _G.qa_publication_runtime_cli = "configured-qa-publication-runtime.js"
    _G.defect_publication_runtime = ports
    t.eq(defect_publication.production_ports(), ports)

    _G.defect_publication_runtime = nil
    local configured = defect_publication.production_ports()
    for _, name in ipairs({ "load_ledger", "save_ledger", "load_artifact", "write_artifact" }) do
      t.eq(type(configured[name]), "function")
    end

    _G.defect_publication_runtime = previous_runtime
    _G.qa_publication_runtime_cli = previous_cli
  end,
}
