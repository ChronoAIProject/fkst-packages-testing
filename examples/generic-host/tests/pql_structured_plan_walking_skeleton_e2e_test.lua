local design_loop = require("testing_ai.module_ai_design_loop")
local json_codec = require("testing_runtime.json")
local support = require("host_canonical_workflow_qa_support")
local supervisor = require("test_support.host_workflow_qa_supervisor")
local planning = supervisor.load_package_module(support.project_root, "testing-runner", "module_planning")
local structured_planning = supervisor.load_package_module(support.project_root, "testing-runner", "structured_planning")
local testing_design = require("contract.testing_design")
local t = fkst.test

local root = ".testing/runs/pql-home-title"
local repository = { url = "https://example.invalid/project.git", commit_sha = string.rep("a", 40) }

local function copy(value)
  return support.copy(value)
end

local function reference(path, document)
  return { artifact_pointer = path, artifact_digest = design_loop.document_digest(document) }
end

local function design_state(design_case_id)
  local design_root = root .. "/module/design-loop"
  local case = {
    id = design_case_id,
    module_id = "service",
    priority = "P0",
    title = "Promoted home title design",
    objective = "Retain the promoted design identity for Host authorization.",
    case_kind = "read-only-interaction",
    actions = { { action = "open-visible-surface", target = "Home", expected = "Home remains visible" } },
    expected_observable = "The Host-authorized home behavior remains observable.",
    coverage_subject_ids = { "module-service" },
    provenance = { origin = "user-seed", source_pointer = root .. "/design/traceability-seed.v1.json" },
  }
  local documents = {
    seed_cases = { schema = design_loop.schemas.seed_cases, cases = { case } },
    coverage_scope = { schema = design_loop.schemas.coverage_scope, subjects = {
      { id = "module-service", kind = "module", priority = "P0", evidence_pointer = root .. "/design/repository-analysis.v1.json" },
    } },
    deterministic_cases = { schema = design_loop.schemas.deterministic_cases, cases = {} },
  }
  local request = {
    schema = design_loop.schemas.request,
    artifact_root = design_root,
    seed_cases_ref = reference(design_root .. "/seed-cases.json", documents.seed_cases),
    coverage_scope_ref = reference(design_root .. "/coverage-scope.json", documents.coverage_scope),
    deterministic_cases_ref = reference(design_root .. "/deterministic-cases.json", documents.deterministic_cases),
    max_rounds = 1,
    case_budget = 1,
    action_budget = 1,
    trace_id = "trace-pql-home-title",
    dedup_key = "dedup-pql-home-title",
  }
  return design_loop.start(request, documents)
end

local function inventory()
  return {
    schema = "testing-runner.module-inventory.v1",
    artifact_kind = "module-inventory",
    discovery_status = "complete",
    artifact_root = root .. "/module",
    modules = { {
      id = "service",
      name = "Service",
      entry_url = "http://127.0.0.1:4173/",
      evidence_pointer = root .. "/design/repository-analysis.v1.json",
    } },
    module_count = 1,
    limitations = {},
    coverage = "promoted-design-only",
    readiness = { status = "ready" },
  }
end

local function browser_case(design_case_id)
  return {
    design_case_id = design_case_id,
    case_id = "home-title",
    kind = "browser",
    goal = "Verify the Host-authorized home title behavior",
    success_conditions = { "The Browser case reaches the Host-defined successful completion state" },
    completion_assertions = {
      { assertion_id = "callback-observed", type = "browser-callback-observed", required = true, completion_field = "callback_observed" },
      { assertion_id = "process-exit-zero", type = "browser-process-exit-zero", required = true, completion_field = "process_exit_zero" },
      { assertion_id = "whoami-succeeded", type = "browser-whoami-succeeded", required = true, completion_field = "whoami_succeeded" },
      { assertion_id = "status-authenticated", type = "browser-status-authenticated", required = true, completion_field = "status_authenticated" },
    },
  }
end

local function environment_receipt(request)
  local environment_root = root .. "/environment"
  local operation_state_ref = { kind = "artifact", ref = environment_root .. "/operation-state.json" }
  local sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } }
  return {
    schema = "environment-factory.receipt.v2",
    operation_id = "pql-home-title",
    status = "ready",
    profile_revision = "profile-v1",
    profile_sha256 = string.rep("9", 64),
    repository = copy(request.repository),
    workspace_ref = { kind = "workspace", ref = "pql-home-title-workspace" },
    base_url = "http://127.0.0.1:4173/",
    runtime_ports = { { name = "application", port = 4173 } },
    sessions = copy(sessions),
    browser_readiness = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
        { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } }, cdp_url = "http://127.0.0.1:9222" },
      },
      source_ref = copy(operation_state_ref),
      request_context = { dry_run = false },
      correlation = {
        schema = "environment-factory.browser-readiness-correlation.v1",
        attempt_id = "attempt-1",
        operation_id = "pql-home-title",
        operation_state_ref = copy(operation_state_ref),
        readiness_attempt_ref = { kind = "artifact", ref = environment_root .. "/readiness-attempts/attempt-1.json" },
        readiness_attempt_sha256 = string.rep("8", 64),
        base_url = "http://127.0.0.1:4173/",
        sessions = copy(sessions),
        trace_id = request.trace_id,
        dedup_key = request.dedup_key,
      },
    },
    artifact_root = environment_root,
    diagnostic_refs = {},
    cleanup_ref = { kind = "environment-cleanup", ref = "pql-home-title" },
    cleanup_status = "pending",
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
end

local function compiler_request(store)
  return {
    schema = "testing-runner.structured-plan.request.v1",
    repository = copy(repository),
    module_plan_ref = root .. "/module/test-plan.json",
    module_plan_sha256 = store:digest(root .. "/module/test-plan.json"),
    case_catalog_ref = root .. "/authorization/case-catalog.json",
    case_catalog_sha256 = store:digest(root .. "/authorization/case-catalog.json"),
    environment_receipt_ref = root .. "/environment/environment-receipt-ready.json",
    environment_receipt_sha256 = store:digest(root .. "/environment/environment-receipt-ready.json"),
    browser_readiness_ref = root .. "/environment/browser-readiness.json",
    browser_readiness_sha256 = store:digest(root .. "/environment/browser-readiness.json"),
    plan_ref = root .. "/execution/structured-plan.json",
    artifact_root = root .. "/execution",
    trace_id = "trace-pql-home-title",
    dedup_key = "dedup-pql-home-title",
    source_ref = { kind = "workflow-qa", ref = "pql-home-title" },
  }
end

return {
  test_compiles_promoted_pql_browser_case_through_existing_structured_plan = function()
    local temp_root = "/tmp/fkst-pql-structured-plan"
    support.require_exec({ "rm", "-rf", temp_root, support.absolute(root) })
    local prepared = support.direct_exec({
      "node", support.project_root .. "/examples/generic-host/test_support/pql_design_runtime_fixture.js",
      support.project_root, temp_root, root .. "/design",
    })
    t.is_true(prepared.exit_code == 0, "PQL fixture preparation failed: " .. tostring(prepared.stderr))
    local runtime = support.direct_exec({
      "env", "FKST_TESTING_DESIGN_REQUEST_JSON=" .. prepared.stdout,
      "node", support.project_root .. "/packages/testing-design/bin/testing-design-runtime.js", "analyze-env",
    })
    t.eq(runtime.exit_code, 0)
    local runtime_envelope = json.decode(runtime.stdout)
    t.eq(runtime_envelope.ok, true)
    local design_result = runtime_envelope.result
    testing_design.validate_context_reference(design_result.context)
    local traceability_bytes = assert(support.read_file(
      support.absolute(design_result.context.traceability_seed.artifact_pointer)))
    t.eq(support.sha256_bytes(traceability_bytes), design_result.context.traceability_seed.artifact_digest)
    local traceability = json.decode(traceability_bytes)
    local lineage = traceability.pql_lineage.approved_assets[1]
    t.eq(lineage.asset_id, "TCA-HOME-TITLE")
    t.eq(lineage.asset_version, "1")
    t.eq(lineage.asset_ref.ref, "TCA-HOME-TITLE@1")
    t.eq(lineage.requirement_refs[1].ref, "REQ-HOME-TITLE")

    local design_case_id = lineage.asset_id .. "@" .. lineage.asset_version
    local state, closure_artifacts = design_state(design_case_id)
    t.eq(closure_artifacts.closure.status, "reviewed-complete")
    local built = planning.build(inventory(), { mutation_policy = "read-only" }, root .. "/module", {
      ai_design_loop_state = state,
      ai_design_loop_authoritative = true,
      testing_design_context = design_result.context,
    })
    local module_case = built.test_plan.modules[1].cases[1]
    t.eq(module_case.id, "TCA-HOME-TITLE@1")
    t.eq(module_case.review_status, "executable")
    t.is_true(support.equal(built.test_plan.testing_design_context, design_result.context))

    local store = support.Store.new()
    local module_plan_ref = root .. "/module/test-plan.json"
    t.is_true(store:write(module_plan_ref, built.test_plan))
    local first_module = store:load(module_plan_ref)
    local reordered_context = {
      traceability_seed = copy(design_result.context.traceability_seed),
      requirements_index = copy(design_result.context.requirements_index),
      repository_analysis = copy(design_result.context.repository_analysis),
      analysis_key = design_result.context.analysis_key,
      schema = design_result.context.schema,
    }
    local rebuilt = planning.build(inventory(), { mutation_policy = "read-only" }, root .. "/module", {
      testing_design_context = reordered_context,
      ai_design_loop_authoritative = true,
      ai_design_loop_state = copy(state),
    })
    t.is_true(store:write(module_plan_ref, rebuilt.test_plan))
    t.eq(store:write_count(module_plan_ref), 1)
    t.eq(store:load(module_plan_ref).raw, first_module.raw)
    t.eq(store:load(module_plan_ref).digest, first_module.digest)

    local catalog_ref = root .. "/authorization/case-catalog.json"
    local catalog = {
      schema = "testing-structured-case-catalog.v1",
      repository = copy(repository),
      cases = { browser_case("TCA-HOME-TITLE@1") },
      trace_id = "trace-pql-home-title",
      dedup_key = "dedup-pql-home-title",
    }
    t.is_true(store:write(catalog_ref, catalog))
    local preliminary = {
      repository = copy(repository), trace_id = "trace-pql-home-title", dedup_key = "dedup-pql-home-title",
      source_ref = { kind = "workflow-qa", ref = "pql-home-title" },
    }
    local receipt = environment_receipt(preliminary)
    local readiness = copy(receipt.browser_readiness)
    readiness.source_ref = { kind = "workflow-qa", ref = "pql-home-title" }
    t.is_true(store:write(root .. "/environment/environment-receipt-ready.json", receipt))
    t.is_true(store:write(root .. "/environment/browser-readiness.json", readiness))

    local request = compiler_request(store)
    local writes = 0
    local ports = {
      load_artifact = function(path) return store:load(path) end,
      write_artifact = function(path, value) writes = writes + 1; return store:write(path, value) end,
    }
    local result = structured_planning.compile(request, ports)
    t.eq(result.status, "compiled")
    t.eq(result.plan_ref, request.plan_ref)
    t.eq(result.plan_sha256, store:digest(request.plan_ref))
    t.eq(result.residual_risk_count, 0)
    local plan_artifact = store:load(request.plan_ref)
    local plan = plan_artifact.value
    t.eq(plan.schema, "testing-structured-plan.v2")
    t.eq(plan.execution_mode, "agentic-browser")
    t.eq(plan.module_plan_sha256, first_module.digest)
    t.eq(plan.case_catalog_sha256, request.case_catalog_sha256)
    t.eq(plan.environment_receipt_sha256, request.environment_receipt_sha256)
    t.eq(plan.browser_readiness_sha256, request.browser_readiness_sha256)
    t.eq(#plan.cases, 1)
    t.eq(plan.cases[1].case_id, "home-title")
    t.eq(plan.cases[1].design_case_id, nil)
    t.eq(#plan.cases[1].completion_assertions, 4)
    t.eq(plan_artifact.raw, json_codec.encode(plan) .. "\n")
    t.eq(plan_artifact.digest, support.sha256_bytes(plan_artifact.raw))

    local reordered_request = {
      source_ref = copy(request.source_ref),
      dedup_key = request.dedup_key,
      trace_id = request.trace_id,
      artifact_root = request.artifact_root,
      plan_ref = request.plan_ref,
      browser_readiness_sha256 = request.browser_readiness_sha256,
      browser_readiness_ref = request.browser_readiness_ref,
      environment_receipt_sha256 = request.environment_receipt_sha256,
      environment_receipt_ref = request.environment_receipt_ref,
      case_catalog_sha256 = request.case_catalog_sha256,
      case_catalog_ref = request.case_catalog_ref,
      module_plan_sha256 = request.module_plan_sha256,
      module_plan_ref = request.module_plan_ref,
      repository = copy(request.repository),
      schema = request.schema,
    }
    local replay = structured_planning.compile(reordered_request, ports)
    t.eq(replay.status, "compiled")
    t.eq(replay.plan_sha256, result.plan_sha256)
    t.eq(writes, 2)
    t.eq(store:write_count(request.plan_ref), 1)

    support.require_exec({
      "rm", "-rf",
      support.absolute(root .. "/module"),
      support.absolute(root .. "/authorization"),
      support.absolute(root .. "/environment"),
      support.absolute(root .. "/execution"),
    })
    local mismatched_store = support.Store.new()
    t.is_true(mismatched_store:write(module_plan_ref, built.test_plan))
    catalog.cases[1].design_case_id = "TCA-HOME-TITLE@2"
    t.is_true(mismatched_store:write(catalog_ref, catalog))
    t.is_true(mismatched_store:write(root .. "/environment/environment-receipt-ready.json", receipt))
    t.is_true(mismatched_store:write(root .. "/environment/browser-readiness.json", readiness))
    local mismatch_request = compiler_request(mismatched_store)
    local target_effects = 0
    local mismatch = structured_planning.compile(mismatch_request, {
      load_artifact = function(path) return mismatched_store:load(path) end,
      write_artifact = function(path, value) target_effects = target_effects + 1; return mismatched_store:write(path, value) end,
    })
    t.eq(mismatch.status, "blocked")
    t.eq(mismatched_store:load(mismatch_request.plan_ref), nil)
    t.eq(target_effects, 0)
    support.require_exec({ "rm", "-rf", temp_root, support.absolute(root) })
  end,
}
