local generation = require("testing_ai.module_ai_generation")
local t = fkst.test

return {
  test_generation_prompt_and_dispatch_use_read_only_codex_identity = function()
    local context = {
      context_manifest_path = ".testing/runs/module-a/ai-context-manifest.json",
      generated_cases_path = ".testing/runs/module-a/generated-test-cases.json",
      input_digest = "input-digest",
    }
    local prompt = generation.prompt_for_context(context)
    t.is_true(prompt:find(context.context_manifest_path, 1, true) ~= nil)

    local opts = generation.read_only_generation_opts(context, "/worktree")
    t.eq(opts.worktree, "/worktree")
    t.eq(opts.sandbox, "read-only")

    local previous_runs = fkst.codex_runs
    local previous_spawn = spawn_codex_sync
    fkst.codex_runs = function() return { running = {} } end
    spawn_codex_sync = function(dispatch_opts) return dispatch_opts end
    local ok, result = pcall(generation.generate_candidates, context, nil, "/worktree")
    fkst.codex_runs = previous_runs
    spawn_codex_sync = previous_spawn
    if not ok then error(result, 0) end

    t.eq(result.role, "testing-ai-author")
    t.eq(result.proposal_id, "testing-ai/author/input-digest")
    t.eq(result.sync, nil)
    t.eq(result.worktree, "/worktree")
    t.eq(result.sandbox, "read-only")
  end,
}
