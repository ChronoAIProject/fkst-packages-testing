local core = require("core")
local contract = require("contract.testing_execution")
local artifact_manifest = require("testing_runtime.artifact_manifest")
local t = fkst.test

local digest = string.rep("a", 64)

local function intent()
  return {
    schema = "test-artifacts.attempt-commit-intent.v1",
    run_id = "run-contract",
    trace_id = "trace-contract",
    dedup_key = "dedup-contract",
    artifact_kind = "assertion-evidence",
    attempt_id = "attempt-1",
    fence_version = 1,
  }
end

local function completion(pointer)
  local value = intent()
  value.schema = "test-artifacts.attempt-completed.v1"
  value.manifest_sha256 = digest
  value.artifact_pointer = pointer or ".testing/runs/run-contract/artifact-attempt"
  return value
end

local function ports(handler)
  return {
    exec_argv = handler,
    read = function() return "" end,
    write = function() return true end,
    decode = function(value) return value end,
  }
end

local function store_for_lookup(envelope, pointer)
  return core.artifact_attempt_store(ports(function(argv)
    if argv[3] == "artifact-attempt-lookup" then
      return { stdout = envelope, stderr = "", exit_code = 0 }
    end
    return { stdout = (pointer or ".testing/runs/run-contract/expected") .. "\n", stderr = "", exit_code = 0 }
  end))
end

return {
  test_artifact_attempt_contracts_fail_closed = function()
    local malformed_identity = intent()
    malformed_identity.run_id = "run/unsafe"
    t.raises(function() contract.validate_artifact_attempt_intent(malformed_identity) end)

    local malformed_intent_schema = intent()
    malformed_intent_schema.schema = "test-artifacts.unknown.v1"
    t.raises(function() contract.validate_artifact_attempt_intent(malformed_intent_schema) end)

    local malformed_completion_schema = completion()
    malformed_completion_schema.schema = "test-artifacts.unknown.v1"
    t.raises(function() contract.validate_artifact_attempt_completion(malformed_completion_schema) end)
  end,

  test_artifact_attempt_adapter_rejects_failed_and_mismatched_results = function()
    local failed = core.artifact_attempt_store(ports(function()
      return { stdout = "", stderr = "adapter failed", exit_code = 1 }
    end))
    t.raises(function() failed:artifact_pointer(intent()) end)

    local mismatched_identity = core.artifact_attempt_store(ports(function(argv)
      local value = completion()
      value.run_id = "other-run"
      if argv[3] == "artifact-attempt-commit" then
        return { stdout = value, stderr = "", exit_code = 0 }
      end
      return { stdout = value.artifact_pointer .. "\n", stderr = "", exit_code = 0 }
    end))
    t.raises(function() mismatched_identity:commit(intent(), ".testing/runs/staged-contract") end)

    local mismatched_pointer = core.artifact_attempt_store(ports(function(argv)
      if argv[3] == "artifact-attempt-commit" then
        return { stdout = completion(".testing/runs/run-contract/returned"), stderr = "", exit_code = 0 }
      end
      return { stdout = ".testing/runs/run-contract/expected\n", stderr = "", exit_code = 0 }
    end))
    t.raises(function() mismatched_pointer:commit(intent(), ".testing/runs/staged-contract") end)
  end,

  test_artifact_attempt_lookup_envelope_fails_closed = function()
    t.raises(function() store_for_lookup("malformed"):lookup(intent()) end)
    t.raises(function() store_for_lookup({ found = false, unsupported = true }):lookup(intent()) end)
    t.raises(function() store_for_lookup({ found = false, completion = completion() }):lookup(intent()) end)
    t.eq(store_for_lookup({ found = false }):lookup(intent()), nil)
    t.raises(function() store_for_lookup({ found = true }):lookup(intent()) end)
    t.raises(function()
      store_for_lookup(
        { found = true, completion = completion(".testing/runs/run-contract/returned") },
        ".testing/runs/run-contract/expected"
      ):lookup(intent())
    end)
  end,

  test_artifact_manifest_adapter_errors_are_bounded = function()
    local failed_ports = ports(function()
      return { stdout = "", stderr = "adapter failed", exit_code = 1 }
    end)
    t.raises(function()
      artifact_manifest.build_staged(
        ".testing/runs/staged-contract",
        ".testing/runs/run-contract/artifact-attempt",
        nil,
        failed_ports
      )
    end)
    t.raises(function()
      artifact_manifest.build_staged(
        ".testing/runs/staged-contract",
        ".testing/runs/run-contract/artifact-attempt",
        {},
        failed_ports
      )
    end)
    t.raises(function()
      artifact_manifest.digest(".testing/runs/run-contract/artifact-manifest.json", failed_ports)
    end)
  end,
}
