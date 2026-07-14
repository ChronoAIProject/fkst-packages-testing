local artifact_manifest = require("testing_runtime.artifact_manifest")
local json_encoder = require("testing_runtime.json")
local testing = require("testkit.testing")
local department = require("departments.run_module_loop.main")
local t = fkst.test

local function run(argv)
  local result = exec_argv({ argv = argv, timeout = 30 })
  if type(result) ~= "table" or result.exit_code ~= 0 then
    error("completed run replay command failed: " .. tostring(result and result.stderr or "missing result"))
  end
  return result
end

local function trimmed(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lines(value)
  local result = {}
  for line in tostring(value or ""):gmatch("[^\r\n]+") do table.insert(result, line) end
  return result
end

local function matching_records(root, dedup_key)
  local found = {}
  local result = run({ "find", root, "-type", "f", "-name", "*.json" })
  for _, path in ipairs(lines(result.stdout)) do
    local value = json.decode(file.read(path))
    if value.dedup_key == dedup_key then table.insert(found, { path = path, value = value }) end
  end
  return found
end

return {
  test_replays_completed_native_run_without_second_attempt_or_raise = function()
    t.with_command_cassette({
      path = "tests/completed-run-replay-commands.json",
      mode = "record",
    }, function()
      run({ "mkdir", "-p", ".testing/runs" })
      local temporary = run({ "mktemp", "-d", ".testing/runs/completed-run-replay.XXXXXX" })
      local request_root = trimmed(temporary.stdout)
      local unique_id = request_root:match("^%.testing/runs/([%w._-]+)$")
      t.is_true(unique_id ~= nil)

      local effect_path = request_root .. "/department-effects.log"
      local dedup_key = "dedup-" .. unique_id
      local event = {
        queue = "module_test_request",
        payload = {
          schema = "testing-runner.module-test-loop.request.v1",
          backend = "fkst-native",
          module = "completed-run-replay",
          dry_run = false,
          no_browser = true,
          native_argv = { "sh", "-c", "printf 'executed\\n' >> " .. effect_path },
          artifact_root = request_root,
          source_ref = { kind = "acceptance-test", ref = unique_id },
          trace_id = "trace-" .. unique_id,
          dedup_key = dedup_key,
          probe = {
            run_argv = function(argv) return run(argv) end,
          },
        },
      }

      local first = testing.run_fake(department, event)
      t.eq(#first.raises, 1)
      t.eq(first.raises[1].queue, "testing_result")
      t.eq(first.result.schema, "testing-runner.result.v1")
      t.eq(first.result.status, "passed")
      t.eq(first.result.artifact_root, first.raises[1].payload.artifact_root)
      t.eq(file.read(effect_path), "executed\n")

      local artifact_pointer = first.result.artifact_root
      local metadata_before = file.read(artifact_pointer .. "/metadata.json")
      local manifest_path = artifact_pointer .. "/artifact-manifest.json"
      local manifest = json.decode(file.read(manifest_path))
      t.eq(manifest.schema, "test-artifacts.manifest.v1")
      t.eq(manifest.artifact_root, artifact_pointer)
      t.eq(manifest.algorithm, "sha256")
      t.eq(manifest.entry_count, #manifest.entries)
      t.eq(manifest.entry_count, 1)
      for _, entry in ipairs(manifest.entries) do
        t.eq(artifact_manifest.digest(entry.path), entry.sha256)
      end

      local second = testing.run_fake(department, event)
      t.eq(#second.raises, 0)
      t.eq(json_encoder.encode(second.result), json_encoder.encode(first.result))
      t.eq(file.read(effect_path), "executed\n")
      t.eq(file.read(artifact_pointer .. "/metadata.json"), metadata_before)

      local attempt_run_id = artifact_pointer:match("^%.testing/runs/([^/]+)/artifact%-attempts/")
      t.is_true(attempt_run_id ~= nil)
      local attempts = run({
        "find",
        ".testing/runs/" .. attempt_run_id .. "/artifact-attempts",
        "-type",
        "d",
        "-name",
        "fence-*",
      })
      t.eq(#lines(attempts.stdout), 1)

      local durable_root = os.getenv("FKST_DURABLE_ROOT")
      t.is_true(type(durable_root) == "string" and durable_root ~= "")
      local completions = matching_records(durable_root .. "/test-artifacts/attempt-completions", dedup_key)
      t.eq(#completions, 1)
      t.eq(completions[1].value.artifact_pointer, artifact_pointer)
      t.eq(completions[1].value.manifest_sha256, artifact_manifest.digest(manifest_path))

      local ledger_records = matching_records(durable_root .. "/testing-runner/run-ledger", dedup_key)
      t.eq(#ledger_records, 1)
      t.eq(ledger_records[1].value.state, "completed")
      t.eq(ledger_records[1].value.fence_version, 1)
      t.eq(ledger_records[1].value.terminal_attempt.artifact_pointer, artifact_pointer)
      t.eq(
        json_encoder.encode(ledger_records[1].value.terminal_result),
        json_encoder.encode(first.result)
      )
      run({ "rm", "-rf", request_root, ".testing/runs/" .. attempt_run_id })
    end)
  end,
}
