local support = require("test_support.canonical_workflow_qa")
local supervisor = require("test_support.host_workflow_qa_supervisor")
local t = fkst.test

local function artifact(context, path)
  local value = context.store:load(path)
  if value == nil then error("canonical browser recovery artifact is unavailable: " .. path) end
  return value
end

local function with_context(options, fn)
  local context = support.new(options)
  local ok, err = pcall(fn, context)
  context:cleanup()
  if not ok then error(err, 0) end
end

local function expect_interruption(context)
  local ok = pcall(function() context:run_lifecycle() end)
  t.eq(ok, false)
end

local function assert_terminal(context, expected_status)
  local result_path = context.artifact_root .. "/case-result-set.json"
  local manifest_path = context.artifact_root .. "/evidence-manifest.json"
  local result = artifact(context, result_path).value
  local manifest = artifact(context, manifest_path).value
  t.eq(result.cases[1].execution_status, expected_status)
  t.eq(result.evidence_manifest_ref.sha256, artifact(context, manifest_path).digest)
  t.eq(result.evidence_manifest_artifact_sha256, artifact(context, manifest_path).digest)
  t.eq(result.evidence_manifest_sha256, manifest.canonical_sha256)
  t.is_true(result.evidence_manifest_sha256 ~= result.evidence_manifest_artifact_sha256)
  local cleanup = artifact(context, context.terminal.cleanup_receipt_ref).value
  t.eq(cleanup.status, "complete")
  t.eq(#cleanup.remaining_resources, 0)
  t.eq(context.publication_count, 1)
  t.eq(context.terminal_records, 1)
end

local function assert_effect_identity(context)
  local manifest = artifact(context, context.artifact_root .. "/evidence-manifest.json").value
  local found
  for _, entry in ipairs(manifest.entries) do
    if entry.redaction_classification == "sanitized-browser-effect-intent" then
      found = entry
      break
    end
  end
  t.is_true(type(found) == "table")
  t.is_true(found.evidence_id:match("^browser%-effect%-%x+$") ~= nil)
  t.is_true(found.artifact_ref.ref:sub(1, #context.artifact_root + 1) == context.artifact_root .. "/")
  t.eq(found.artifact_ref.ref:find("..", 1, true), nil)
  t.eq(artifact(context, found.artifact_ref.ref).value.effect_id, found.evidence_id)
end

return {
  test_duplicate_grant_claim_and_controller_replacement_are_effect_free_until_resume = function()
    with_context({
      scenario = "canonical-browser-grant-replay",
      publication_channel = "filesystem-dry-run-v1",
      browser_failpoint = "after-claim",
    }, function(context)
      expect_interruption(context)
      t.eq(context.browser_grant_claims, 1)
      t.eq(#context.browser_effects, 0)
      context.browser_failpoint_fired = false
      expect_interruption(context)
      t.eq(context.browser_grant_claims, 1)
      t.eq(#context.browser_effects, 0)
      context.browser_failpoint = nil
      context:replace_browser_process()
      context:run_lifecycle()
      t.eq(context.browser_grant_claims, 1)
      t.eq(#context.browser_effects, 1)
      assert_terminal(context, "passed")
    end)
  end,

  test_browser_crash_is_published_as_lost_without_automatic_rerun = function()
    with_context({
      scenario = "canonical-browser-crash",
      publication_channel = "filesystem-dry-run-v1",
      browser_crash = true,
    }, function(context)
      context:run_lifecycle()
      t.eq(#context.browser_effects, 1)
      assert_terminal(context, "lost")
      assert_effect_identity(context)
    end)
  end,

  test_effect_acknowledgement_loss_recovers_as_lost_with_original_identity = function()
    with_context({
      scenario = "canonical-browser-effect-uncertain",
      publication_channel = "filesystem-dry-run-v1",
      browser_failpoint = "after-browser-effect",
    }, function(context)
      expect_interruption(context)
      t.eq(#context.browser_effects, 1)
      context:replace_browser_process()
      context:run_lifecycle()
      t.eq(#context.browser_effects, 1)
      assert_terminal(context, "lost")
      assert_effect_identity(context)
    end)
  end,

  test_canonical_result_and_manifest_write_interruptions_are_idempotent = function()
    for _, failpoint in ipairs({ "after-case-result-set-write", "after-evidence-manifest-write" }) do
      with_context({
        scenario = "canonical-browser-" .. failpoint,
        publication_channel = "filesystem-dry-run-v1",
        browser_failpoint = failpoint,
      }, function(context)
        expect_interruption(context)
        t.eq(#context.browser_effects, 1)
        local interrupted_path = context.artifact_root .. (failpoint == "after-case-result-set-write"
          and "/case-result-set.json" or "/evidence-manifest.json")
        local interrupted_bytes = artifact(context, interrupted_path).raw
        local interrupted_digest = artifact(context, interrupted_path).digest
        context:replace_browser_process()
        context:run_lifecycle()
        t.eq(#context.browser_effects, 1)
        t.eq(artifact(context, interrupted_path).raw, interrupted_bytes)
        t.eq(artifact(context, interrupted_path).digest, interrupted_digest)
        local result_path = context.artifact_root .. "/case-result-set.json"
        local manifest_path = context.artifact_root .. "/evidence-manifest.json"
        t.eq(context.store:write_count(result_path), 1)
        t.eq(context.store:write_count(manifest_path), 1)
        assert_terminal(context, "passed")
      end)
    end
  end,

  test_cleanup_interruption_replays_without_duplicate_cleanup_or_early_publication = function()
    with_context({
      scenario = "canonical-browser-cleanup-replay",
      publication_channel = "filesystem-dry-run-v1",
    }, function(context)
      supervisor.prepare_phase(context, context.project_root, "cleanup-checkpoint")
      local cleanup_effects = context.cleanup_effects
      t.is_true(cleanup_effects > 0)
      t.eq(context.publication_count, 0)
      t.eq(context.terminal, nil)
      context:run_lifecycle()
      t.eq(context.cleanup_effects, cleanup_effects)
      t.eq(#context.browser_effects, 1)
      assert_terminal(context, "passed")
    end)
  end,

  test_publication_acknowledgement_loss_reuses_provider_materialization = function()
    with_context({
      scenario = "canonical-browser-publication-ack-loss",
      publication_channel = "filesystem-dry-run-v1",
      publication_ack_loss = true,
    }, function(context)
      expect_interruption(context)
      t.eq(context.publication_count, 1)
      t.eq(context.terminal, nil)
      context:run_lifecycle()
      t.eq(context.publication_count, 1)
      t.eq(#context.browser_effects, 1)
      assert_terminal(context, "passed")
    end)
  end,

  test_terminal_replay_is_a_fresh_process_no_op = function()
    with_context({
      scenario = "canonical-browser-terminal-replay",
      publication_channel = "filesystem-dry-run-v1",
    }, function(context)
      context:run_lifecycle()
      local result_path = context.artifact_root .. "/case-result-set.json"
      local manifest_path = context.artifact_root .. "/evidence-manifest.json"
      local result_bytes = artifact(context, result_path).raw
      local manifest_bytes = artifact(context, manifest_path).raw
      local observations = context.browser_observations
      context:replace_browser_process()
      local replay = context:run_lifecycle()
      t.eq(replay.no_op, true)
      t.eq(artifact(context, result_path).raw, result_bytes)
      t.eq(artifact(context, manifest_path).raw, manifest_bytes)
      t.eq(context.browser_observations, observations)
      t.eq(#context.browser_effects, 1)
      t.eq(context.publication_count, 1)
      t.eq(context.terminal_records, 1)
    end)
  end,
}
