local defect_publication = require("defect_publication")
local t = fkst.test

local commit_sha = string.rep("1", 40)
local plan_sha = string.rep("a", 64)
local results_sha = string.rep("b", 64)
local drafts_sha = string.rep("c", 64)

local function request()
  local root = ".testing/runs/defect-publication"
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

local function preparation_request()
  local value = request()
  value.publication.dedup_key = value.dedup_key
  value.publication.publication_dry_run = true
  return {
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

local function runtime(options)
  options = options or {}
  local state
  local writes = {}
  local write_count = 0
  local artifacts_enabled = true
  local value = request()
  local artifacts = {
    [value.publication.test_plan_path] = { digest = plan_sha, value = structured_plan(value) },
    [value.case_results_ref] = { digest = results_sha, value = {
      schema = "testing-structured-case-results.v1", plan_sha256 = plan_sha,
      cases = {
        { case_id = "version", kind = "cli", status = "failed", classification = "product-defect", assertions = { { type = "exit-code", passed = false } }, evidence_ref = value.publication.artifact_root .. "/evidence/version.json" },
        { case_id = "health", kind = "http", status = "error", classification = "environment-session-issue", assertions = {}, evidence_ref = value.publication.artifact_root .. "/evidence/health.json" },
      },
    } },
    [value.issue_drafts_ref] = { digest = drafts_sha, value = {
      schema = "test-publication.defect-issue-drafts.v1", plan_sha256 = plan_sha,
      cases = {
        { case_id = "version", title = "CLI version output differs", expected_summary = "Exit code 0", actual_summary = "Exit code 1", evidence_ref = value.publication.artifact_root .. "/evidence/version.json" },
      },
    } },
  }
  if options.mutate then options.mutate(artifacts) end
  return {
    load_ledger = function() return state end,
    save_ledger = function(_, next_state, expected)
      if options.save_failure then return false end
      if state ~= nil and state.version ~= expected then return false end
      if state == nil and expected ~= 0 then return false end
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
    disable_artifacts = function() artifacts_enabled = false end,
    writes = writes,
  }
end

return {
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
    _G.defect_publication_runtime = nil
    t.raises(function() defect_publication.production_ports() end)
    local ports = {}
    for _, name in ipairs({ "load_ledger", "save_ledger", "load_artifact", "write_artifact" }) do
      ports[name] = function() return true end
    end
    _G.defect_publication_runtime = ports
    t.eq(defect_publication.production_ports(), ports)
    _G.defect_publication_runtime = nil
  end,
}
