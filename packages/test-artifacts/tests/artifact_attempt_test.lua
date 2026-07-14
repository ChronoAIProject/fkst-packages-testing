local core = require("core")
local artifact_manifest = require("testing_runtime.artifact_manifest")
local t = fkst.test

local function run(argv)
  local result = exec_argv({ argv = argv, timeout = 30 })
  if type(result) ~= "table" or result.exit_code ~= 0 then
    error("artifact attempt test command failed: " .. tostring(result and result.stderr or "missing result"))
  end
  return result
end

local function intent(run_id)
  return {
    schema = "test-artifacts.attempt-commit-intent.v1",
    run_id = run_id,
    trace_id = "trace-verified-attempt",
    dedup_key = "dedup-verified-attempt",
    artifact_kind = "assertion-evidence",
    attempt_id = "attempt-1",
    fence_version = 1,
  }
end

return {
  test_commits_and_replays_one_verified_artifact_attempt = function()
    t.with_command_cassette({
      path = "tests/artifact-attempt-commands.json",
      mode = "record",
    }, function()
      run({ "mkdir", "-p", ".testing/runs" })
      local temporary = run({ "mktemp", "-d", ".testing/runs/artifact-attempt-smoke.XXXXXX" })
      local run_root = tostring(temporary.stdout or ""):gsub("^%s+", ""):gsub("%s+$", "")
      local run_id = run_root:match("^%.testing/runs/([%w._-]+)$")
      t.is_true(run_id ~= nil)
      local staged_root = run_root .. "/staged"
      local artifact_body = "verified artifact bytes\n"
      local commit_intent = intent(run_id)
      local writer = core.artifact_attempt_store()
      local artifact_pointer = writer:artifact_pointer(commit_intent)

      run({ "mkdir", "-p", staged_root })
      file.write(staged_root .. "/assertion.txt", artifact_body)
      artifact_manifest.build_staged(staged_root, artifact_pointer, { "assertion.txt" })
      local expected_manifest_sha256 = artifact_manifest.digest(staged_root .. "/artifact-manifest.json")

      local completion = writer:commit(commit_intent, staged_root)
      t.eq(completion.schema, "test-artifacts.attempt-completed.v1")
      t.eq(completion.run_id, commit_intent.run_id)
      t.eq(completion.trace_id, commit_intent.trace_id)
      t.eq(completion.dedup_key, commit_intent.dedup_key)
      t.eq(completion.artifact_kind, commit_intent.artifact_kind)
      t.eq(completion.attempt_id, commit_intent.attempt_id)
      t.eq(completion.fence_version, 1)
      t.eq(completion.manifest_sha256, expected_manifest_sha256)
      t.eq(completion.artifact_pointer, artifact_pointer)
      t.is_true(completion.artifact_pointer:find("current", 1, true) == nil)
      t.eq(file.read(completion.artifact_pointer .. "/assertion.txt"), artifact_body)
      t.eq(
        artifact_manifest.digest(completion.artifact_pointer .. "/artifact-manifest.json"),
        expected_manifest_sha256
      )

      writer = nil
      local reader = core.artifact_attempt_store()
      local replayed = reader:lookup(commit_intent)
      t.eq(replayed.schema, completion.schema)
      t.eq(replayed.run_id, completion.run_id)
      t.eq(replayed.trace_id, completion.trace_id)
      t.eq(replayed.dedup_key, completion.dedup_key)
      t.eq(replayed.artifact_kind, completion.artifact_kind)
      t.eq(replayed.attempt_id, completion.attempt_id)
      t.eq(replayed.fence_version, completion.fence_version)
      t.eq(replayed.manifest_sha256, completion.manifest_sha256)
      t.eq(replayed.artifact_pointer, completion.artifact_pointer)

      local serialized = core.encode_artifact_attempt_completion(replayed)
      t.eq(serialized, core.encode_artifact_attempt_completion(replayed))
      t.eq(serialized:find(artifact_body, 1, true), nil)
      local with_body = {}
      for key, value in pairs(replayed) do with_body[key] = value end
      with_body.artifact_body = artifact_body
      t.raises(function() core.encode_artifact_attempt_completion(with_body) end)
      run({ "rm", "-rf", run_root })
    end)
  end,
}
