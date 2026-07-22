local loop = require("module_ai_design_loop")
local planning = require("module_planning")
local consensus = require("testing_ai.module_ai_design_consensus")
local t = fkst.test

local root = ".testing/runs/module-a-design-loop"

local function case(id, subject_ids, origin)
  return {
    id = id,
    module_id = "dashboard",
    priority = "P1",
    title = "Verify " .. id,
    objective = "Verify evidence-backed behavior for " .. id,
    case_kind = "read-only-interaction",
    actions = {
      { action = "open-visible-surface", target = "Dashboard", expected = "Dashboard is visible" },
    },
    expected_observable = "Dashboard remains visible.",
    coverage_subject_ids = subject_ids,
    provenance = { origin = origin or "deterministic", source_pointer = root .. "/source.json" },
  }
end

local function documents()
  return {
    seed_cases = { schema = loop.schemas.seed_cases, cases = {} },
    coverage_scope = {
      schema = loop.schemas.coverage_scope,
      subjects = {
        { id = "REQ-HEALTH", kind = "requirement", priority = "P0", evidence_pointer = root .. "/requirements.json" },
        { id = "module-dashboard", kind = "module", priority = "P1", evidence_pointer = root .. "/inventory.json" },
      },
    },
    deterministic_cases = { schema = loop.schemas.deterministic_cases, cases = { case("health", { "REQ-HEALTH" }) } },
  }
end

local function reference(path, document)
  return { artifact_pointer = path, artifact_digest = loop.document_digest(document) }
end

local function request(docs)
  return {
    schema = loop.schemas.request,
    artifact_root = root,
    seed_cases_ref = reference(root .. "/seed-cases.json", docs.seed_cases),
    coverage_scope_ref = reference(root .. "/coverage-scope.json", docs.coverage_scope),
    deterministic_cases_ref = reference(root .. "/deterministic-cases.json", docs.deterministic_cases),
    max_rounds = 3,
    case_budget = 8,
    action_budget = 24,
    trace_id = "trace-design-loop",
    dedup_key = "dedup-design-loop",
  }
end

return {
  test_design_consensus_binds_prompt_author_and_round_proposal = function()
    local docs = documents()
    local design_request = request(docs)
    local _, artifacts = loop.start(design_request, docs)
    local result = {
      round = 1,
      refs = {
        state_ref = reference(root .. "/state.json", { schema = "state" }),
        coverage_matrix_ref = reference(root .. "/coverage-matrix.json", artifacts.coverage_matrix),
        round_plan_ref = reference(root .. "/round-plan.json", artifacts.round_plan),
      },
    }
    local orchestration_state = {
      artifact_root = root,
      module_start = { dedup_key = "module-design-dedup" },
    }
    local prompt = consensus.prompt_for_patch(orchestration_state, result)
    t.is_true(prompt:find(loop.schemas.patch, 1, true) ~= nil)
    t.is_true(prompt:find(result.refs.round_plan_ref.artifact_digest, 1, true) ~= nil)
    t.is_true(prompt:find(result.refs.state_ref.artifact_pointer, 1, true) ~= nil)

    t.mock_command("codex exec", { exit_code = 0, stdout = "{}", stderr = "" })
    local authored = consensus.author_patch(orchestration_state, result, "/repo")
    t.eq(authored.exit_code, 0)

    local patch_ref = reference(root .. "/supplementation-patch.json", {
      schema = loop.schemas.patch,
      round = 1,
      base_round_digest = artifacts.round_plan.round_digest,
      operations = {},
    })
    local proposal = consensus.round_proposal(orchestration_state, result, patch_ref)
    t.eq(proposal.schema, "consensus.proposal.v1")
    t.eq(proposal.source_ref.ref, root)
    t.is_true(proposal.body:find(patch_ref.artifact_pointer, 1, true) ~= nil)
  end,

  test_structured_patch_supplements_uncovered_subject_and_converges = function()
    local docs = documents()
    local state, artifacts = loop.start(request(docs), docs)
    t.eq(state.round, 1)
    t.eq(artifacts.coverage_matrix.entries[1].status, "covered")
    t.eq(artifacts.coverage_matrix.entries[2].status, "missing-evidence")

    local patch = {
      schema = loop.schemas.patch,
      round = 1,
      base_round_digest = artifacts.round_plan.round_digest,
      operations = {
        { operation = "add-case", case = case("dashboard-visible", { "module-dashboard" }, "reviewer-supplemented") },
      },
    }
    local next_state, next_artifacts = loop.apply_round(state, patch)
    t.eq(next_state.round, 2)
    t.eq(next_artifacts.coverage_matrix.entries[2].status, "covered")
    t.eq(next_artifacts.closure.status, "reviewed-complete")
    t.eq(next_artifacts.closure.round_count, 2)
  end,

  test_seed_cases_preserve_provenance_and_reviewer_patch_can_revise_deduplicate_and_downgrade = function()
    local docs = documents()
    docs.coverage_scope.subjects[3] = {
      id = "REQ-RISK", kind = "requirement", priority = "P1", evidence_pointer = root .. "/requirements.json",
    }
    docs.seed_cases.cases = {
      case("seed-dashboard", { "module-dashboard" }, "user-seed"),
      case("duplicate-dashboard", { "module-dashboard" }, "ai-generated"),
    }
    local state, artifacts = loop.start(request(docs), docs)
    t.eq(state.cases[2].provenance.origin, "user-seed")
    local patch = {
      schema = loop.schemas.patch,
      round = 1,
      base_round_digest = artifacts.round_plan.round_digest,
      operations = {
        { operation = "revise-case", case_id = "seed-dashboard", objective = "Verify the reviewed dashboard objective." },
        { operation = "remove-duplicate", case_id = "duplicate-dashboard", duplicate_of = "seed-dashboard", reason = "Same semantic objective." },
        { operation = "downgrade-case", case_id = "health", status = "not-executed-risk", reason = "Fixture evidence is unavailable." },
      },
      finalize = "accept-residual-risk",
    }
    local next_state, next_artifacts = loop.apply_round(state, patch)
    t.eq(next_state.cases[2].objective, "Verify the reviewed dashboard objective.")
    t.eq(next_state.cases[3].review_status, "duplicate")
    t.eq(next_state.cases[1].review_status, "not-executed-risk")
    t.eq(next_artifacts.closure.status, "residual-risk")
    t.eq(next_artifacts.residual_risk.high_priority_unresolved_count > 0, true)
  end,

  test_reviewer_findings_update_coverage_and_conflicts_fail_closed = function()
    local docs = documents()
    local state, artifacts = loop.start(request(docs), docs)
    local patch = {
      schema = loop.schemas.patch,
      round = 1,
      base_round_digest = artifacts.round_plan.round_digest,
      findings = {
        schema = loop.schemas.reviewer_findings,
        findings = {
          { subject_id = "module-dashboard", status = "blocked", rationale = "Browser evidence is missing." },
        },
      },
      operations = {},
      finalize = "blocked",
    }
    local _, next_artifacts = loop.apply_round(state, patch)
    t.eq(next_artifacts.coverage_matrix.entries[2].status, "blocked")
    t.eq(next_artifacts.closure.status, "blocked")

    patch.base_round_digest = artifacts.round_plan.round_digest
    patch.findings.findings[2] = {
      subject_id = "module-dashboard", status = "covered", rationale = "Conflicting reviewer claim.",
    }
    t.raises(function() loop.apply_round(state, patch) end)
  end,

  test_round_limit_emits_residual_risk_and_same_patch_replays_without_mutation = function()
    local docs = documents()
    local value = request(docs)
    value.max_rounds = 2
    local state, artifacts = loop.start(value, docs)
    local patch = {
      schema = loop.schemas.patch,
      round = 1,
      base_round_digest = artifacts.round_plan.round_digest,
      operations = {
        { operation = "request-evidence", subject_id = "module-dashboard", reason = "Need browser proof." },
      },
    }
    local next_state, next_artifacts, replayed = loop.apply_round(state, patch)
    t.eq(replayed, false)
    t.eq(next_artifacts.closure.status, "round-limit")
    t.eq(next_artifacts.residual_risk.unresolved_count, 1)
    local replay_state, replay_artifacts, was_replayed = loop.apply_round(next_state, patch)
    t.eq(was_replayed, true)
    t.eq(replay_state.current_round_digest, next_state.current_round_digest)
    t.eq(replay_artifacts.closure.status, "round-limit")
  end,

  test_stale_patch_digest_document_digest_and_finalized_mutation_fail_closed = function()
    local docs = documents()
    local value = request(docs)
    local state, artifacts = loop.start(value, docs)
    local stale = {
      schema = loop.schemas.patch,
      round = 1,
      base_round_digest = "wrong-digest",
      operations = {},
    }
    t.raises(function() loop.apply_round(state, stale) end)

    local mismatched = request(docs)
    mismatched.seed_cases_ref.artifact_digest = "wrong-digest"
    t.raises(function() loop.start(mismatched, docs) end)

    local complete = {
      schema = loop.schemas.patch,
      round = 1,
      base_round_digest = artifacts.round_plan.round_digest,
      operations = {
        { operation = "add-case", case = case("dashboard-complete", { "module-dashboard" }, "reviewer-supplemented") },
      },
    }
    local final_state = loop.apply_round(state, complete)
    local changed = {
      schema = loop.schemas.patch,
      round = 2,
      base_round_digest = final_state.current_round_digest,
      operations = {},
    }
    t.raises(function() loop.apply_round(final_state, changed) end)
  end,

  test_reviewed_cases_merge_into_existing_testing_plan_without_duplicates = function()
    local docs = documents()
    docs.seed_cases.cases = { case("seed-dashboard", { "module-dashboard" }, "user-seed") }
    local state = loop.start(request(docs), docs)
    local plan_modules = {
      { id = "dashboard", cases = { { id = "health", objective = "existing" } } },
    }
    local merged = loop.merge_into_plan(plan_modules, state)
    t.eq(merged, 1)
    t.eq(plan_modules[1].cases[2].id, "seed-dashboard")
    t.eq(plan_modules[1].cases[2].case_origin, "user-seed")
    t.eq(loop.merge_into_plan(plan_modules, state), 0)
  end,

  test_reviewed_complete_state_flows_into_testing_runner_planning = function()
    local docs = documents()
    docs.seed_cases.cases = { case("seed-dashboard", { "module-dashboard" }, "user-seed") }
    local state, artifacts = loop.start(request(docs), docs)
    t.eq(artifacts.closure.status, "reviewed-complete")
    local result = planning.build({
      modules = {
        {
          id = "dashboard",
          name = "Dashboard",
          entry_url = "http://localhost:8080/dashboard",
          evidence_pointer = root .. "/inventory.json",
        },
      },
      limitations = {},
    }, {
      mutation_policy = "read-only",
    }, root, {
      ai_design_loop_state = state,
    })
    t.eq(result.test_plan.review_gate.ai_design_case_count, 2)
    t.eq(result.test_plan.review_gate.ai_design_closure.status, "reviewed-complete")
    t.eq(result.test_plan.modules[1].cases[11].id, "health")
    t.eq(result.test_plan.modules[1].cases[12].id, "seed-dashboard")
  end,

  test_public_contract_validators_accept_emitted_artifacts = function()
    local docs = documents()
    local state, artifacts = loop.start(request(docs), docs)
    t.eq(loop.validate_seed_cases(docs.seed_cases), docs.seed_cases)
    t.eq(loop.validate_deterministic_cases(docs.deterministic_cases), docs.deterministic_cases)
    t.eq(loop.validate_coverage_scope(docs.coverage_scope), docs.coverage_scope)
    t.eq(loop.validate_coverage_matrix(artifacts.coverage_matrix), artifacts.coverage_matrix)
    t.eq(loop.validate_round_plan(artifacts.round_plan), artifacts.round_plan)
    t.eq(loop.validate_state(state), state)
  end,

  test_contract_validation_rejects_malformed_cases_budgets_and_state = function()
    local docs = documents()
    local invalid_action = documents()
    invalid_action.deterministic_cases.cases[1].actions[1].action = nil
    t.raises(function() loop.start(request(invalid_action), invalid_action) end)
    local invalid_identity = documents()
    invalid_identity.deterministic_cases.cases[1].title = nil
    t.raises(function() loop.start(request(invalid_identity), invalid_identity) end)
    local invalid_coverage = documents()
    invalid_coverage.deterministic_cases.cases[1].coverage_subject_ids = {}
    t.raises(function() loop.start(request(invalid_coverage), invalid_coverage) end)
    local invalid_subject = documents()
    invalid_subject.coverage_scope.subjects[1].id = nil
    t.raises(function() loop.start(request(invalid_subject), invalid_subject) end)
    local invalid_provenance = documents()
    invalid_provenance.deterministic_cases.cases[1].provenance.source_pointer = "/tmp/source.json"
    t.raises(function() loop.start(request(invalid_provenance), invalid_provenance) end)
    local invalid_status = documents()
    invalid_status.deterministic_cases.cases[1].review_status = "approved"
    t.raises(function() loop.start(request(invalid_status), invalid_status) end)
    for field, bad in pairs({ max_rounds = 0, case_budget = 0, action_budget = 0 }) do
      local value = request(docs)
      value[field] = bad
      t.raises(function() loop.validate_request(value) end)
    end
    local conflict = documents()
    conflict.seed_cases.cases = { case("health", { "module-dashboard" }, "user-seed") }
    t.raises(function() loop.start(request(conflict), conflict) end)
    t.raises(function() loop.validate_state({ schema = loop.schemas.state }) end)
    local state = loop.start(request(docs), docs)
    t.raises(function() loop.merge_into_plan({}, state) end)
  end,

  test_patch_validation_and_action_revision_cover_success_and_failure_paths = function()
    local docs = documents()
    local state, artifacts = loop.start(request(docs), docs)
    t.raises(function() loop.validate_patch({ schema = loop.schemas.patch, round = "one", base_round_digest = artifacts.round_plan.round_digest, operations = {} }) end)
    t.raises(function() loop.validate_patch({ schema = loop.schemas.patch, round = 1, base_round_digest = artifacts.round_plan.round_digest, operations = { { operation = "revise-case", case_id = "health" } } }) end)
    t.raises(function() loop.validate_patch({ schema = loop.schemas.patch, round = 1, base_round_digest = artifacts.round_plan.round_digest, operations = { { operation = "revise-case", case_id = "health", actions = {} } } }) end)
    t.raises(function() loop.validate_reviewer_findings({ schema = loop.schemas.reviewer_findings, findings = { { subject_id = "module-dashboard", status = "unknown", rationale = "Bad status." } } }) end)
    local revised_actions = {
      { action = "open-visible-surface", target = "Dashboard", expected = "Dashboard is visible" },
      { action = "close-visible-surface", target = "Dashboard", expected = "Dashboard closes" },
    }
    local next_state = loop.apply_round(state, {
      schema = loop.schemas.patch,
      round = 1,
      base_round_digest = artifacts.round_plan.round_digest,
      operations = {
        { operation = "revise-case", case_id = "health", expected_observable = "Dashboard opens and closes.", actions = revised_actions },
      },
    })
    t.eq(next_state.cases[1].expected_observable, "Dashboard opens and closes.")
    t.eq(#next_state.cases[1].actions, 2)
    local tight_request = request(docs)
    tight_request.action_budget = 2
    local tight_state, tight_artifacts = loop.start(tight_request, docs)
    revised_actions[3] = { action = "open-visible-surface", target = "Again", expected = "Again is visible" }
    t.raises(function()
      loop.apply_round(tight_state, {
        schema = loop.schemas.patch,
        round = 1,
        base_round_digest = tight_artifacts.round_plan.round_digest,
        operations = { { operation = "revise-case", case_id = "health", actions = revised_actions } },
      })
    end)
  end,

  test_blocked_coverage_and_terminal_contract_failures_are_explicit = function()
    local docs = documents()
    docs.deterministic_cases.cases[2] = case("blocked-dashboard", { "module-dashboard" })
    docs.deterministic_cases.cases[2].review_status = "blocked"
    docs.deterministic_cases.cases[2].reason = "Fixture missing."
    local _, artifacts = loop.start(request(docs), docs)
    t.eq(artifacts.coverage_matrix.entries[2].status, "blocked")
    t.raises(function()
      loop.validate_closure({
        schema = loop.schemas.closure,
        status = "blocked",
        round_count = 1,
        final_round_digest = "round",
        coverage_matrix_pointer = root .. "/coverage-matrix.json",
        coverage_matrix_digest = "coverage",
        unresolved_count = 1,
        high_priority_unresolved_count = 1,
        trace_id = "trace",
        dedup_key = "dedup",
      })
    end)
  end,
}
