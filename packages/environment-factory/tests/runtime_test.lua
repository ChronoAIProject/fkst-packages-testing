local json_codec = require("testing_runtime.json")
local runtime = require("runtime")
local host_json = json
local t = fkst.test

local config_ref = {
  kind = "artifact",
  ref = ".testing/host/environment-factory/runtime-test/config.json",
}

local function with_globals(values, fn)
  local names, previous = {}, {}
  for key, value in pairs(values) do
    table.insert(names, key)
    previous[key] = rawget(_G, key)
    rawset(_G, key, value)
  end
  local ok, result = pcall(fn)
  for _, key in ipairs(names) do rawset(_G, key, previous[key]) end
  if not ok then error(result, 0) end
  return result
end

local function exact_ref(kind, ref)
  return { kind = kind, ref = ref }
end

local function fake_listener_capability(calls, releases, fail_at)
  return {
    claim_loopback = function(request)
      table.insert(calls or {}, request)
      if fail_at ~= nil and #(calls or {}) == fail_at then error("listener claim failed") end
      local claim = {
        opaque_listener_claim = request.owner_key .. ":" .. tostring(#(calls or {})),
        released = false,
      }
      claim.release = function(self)
        if self.released then return end
        self.released = true
        table.insert(releases or {}, self.opaque_listener_claim)
      end
      return claim
    end,
  }
end

local function effect_name(spec)
  for index, value in ipairs(spec.argv or {}) do
    if value == "--name" then return spec.argv[index + 1] end
  end
  return nil
end

local function response_decoder(responses)
  local index = 0
  return function()
    index = index + 1
    local response = responses[index]
    if response == nil then error("missing runtime response " .. tostring(index)) end
    return { ok = true, result = response }
  end
end

return {
  test_call_cli_serializes_host_config_ref_and_uses_direct_argv = function()
    local written = {}
    local executed
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      file = {
        write = function(path, body) written[path] = body end,
        read = function(path)
          t.is_true(path:find("remaining-budget", 1, true) ~= nil)
          return "response"
        end,
      },
      json = {
        decode = function(body)
          t.eq(body, "response")
          return { ok = true, result = { remaining_seconds = 9 } }
        end,
      },
      exec_argv = function(spec)
        executed = spec
        return { exit_code = 0, stdout = "", stderr = "" }
      end,
    }, function()
      local result = runtime.call_cli("remaining-budget", {
        artifact_root = ".testing/runs/runtime-test",
        operation_id = "runtime-test",
        deadline_epoch_seconds = 10,
        total_seconds = 10,
      }, 7)
      t.eq(result.remaining_seconds, 9)
    end)

    t.eq(executed.argv[1], "node")
    t.eq(executed.argv[2], "packages/environment-factory/bin/environment-factory-runtime.js")
    t.eq(executed.argv[3], "effect")
    t.eq(executed.timeout, 7)
    t.eq(executed.shell, nil)
    local request_body
    for path, body in pairs(written) do
      if path:find("request.json", 1, true) ~= nil then request_body = body end
    end
    t.is_true(type(request_body) == "string")
    t.is_true(request_body:find('"runtime_config_ref":{"kind":"artifact","ref":"'
      .. config_ref.ref .. '"}', 1, true) ~= nil)
    t.is_true(request_body:find('"deadline_epoch_seconds":10', 1, true) ~= nil)
  end,

  test_same_identity_calls_use_concurrency_safe_frames_and_reject_stale_or_missing_response_ids = function()
    local files, request_paths, response_paths, response_mode = {}, {}, {}, "exact"
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      environment_factory_runtime_cli = "custom-correlated-runtime.js",
      file = {
        write = function(path, body) files[path] = body end,
        read = function(path) return assert(files[path], "missing fake runtime file " .. tostring(path)) end,
      },
      json = { decode = host_json.decode },
      exec_argv = function(spec)
        if spec.argv[2] == "-e" then return { exit_code = 0 } end
        local request_path, response_path = spec.argv[7], spec.argv[9]
        local request = host_json.decode(files[request_path])
        table.insert(request_paths, request_path)
        table.insert(response_paths, response_path)
        local response = { ok = true, result = { remaining_seconds = 9 } }
        if response_mode == "exact" then response.request_id = request.request_id
        elseif response_mode == "stale" then response.request_id = host_json.decode(files[request_paths[1]]).request_id end
        files[response_path] = json_codec.encode(response) .. "\n"
        return { exit_code = 0 }
      end,
    }, function()
      local request = {
        artifact_root = ".testing/runs/runtime-correlation",
        operation_id = "runtime-correlation",
        deadline_epoch_seconds = 10,
        total_seconds = 10,
      }
      t.eq(runtime.call_cli("remaining-budget", request, 7).remaining_seconds, 9)
      t.eq(runtime.call_cli("remaining-budget", request, 7).remaining_seconds, 9)
      local first = host_json.decode(files[request_paths[1]])
      local second = host_json.decode(files[request_paths[2]])
      t.is_true(type(first.request_id) == "string" and first.request_id ~= "")
      t.is_true(type(second.request_id) == "string" and second.request_id ~= "")
      t.is_true(first.request_id ~= second.request_id)
      t.is_true(request_paths[1] ~= request_paths[2])
      t.is_true(response_paths[1] ~= response_paths[2])
      t.is_true(request_paths[1]:find(first.request_id, 1, true) ~= nil)
      t.is_true(response_paths[2]:find(second.request_id, 1, true) ~= nil)

      response_mode = "stale"
      local stale_ok, stale_error = pcall(runtime.call_cli, "remaining-budget", request, 7)
      t.eq(stale_ok, false)
      t.is_true(tostring(stale_error):find("runtime-response-request-id-mismatch", 1, true) ~= nil)

      response_mode = "missing"
      local missing_ok, missing_error = pcall(runtime.call_cli, "remaining-budget", request, 7)
      t.eq(missing_ok, false)
      t.is_true(tostring(missing_error):find("runtime-response-request-id-missing", 1, true) ~= nil)
    end)
  end,

  test_nonzero_runtime_exit_surfaces_correlated_bounded_host_error = function()
    local files = {}
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      environment_factory_runtime_cli = "custom-correlated-runtime.js",
      file = {
        write = function(path, body) files[path] = body end,
        read = function(path) return assert(files[path], "missing fake runtime file " .. tostring(path)) end,
      },
      json = { decode = host_json.decode },
      exec_argv = function(spec)
        if spec.argv[2] == "-e" then return { exit_code = 0 } end
        local request = host_json.decode(files[spec.argv[7]])
        files[spec.argv[9]] = json_codec.encode({
          ok = false,
          request_id = request.request_id,
          error = string.rep("h", 5000) .. "secret-host-tail",
        }) .. "\n"
        return { exit_code = 19, stderr = "transport failed" }
      end,
    }, function()
      local ok, failure = pcall(runtime.call_cli, "sha256", {
        artifact_root = ".testing/runs/runtime-host-error",
        value = "fixture",
      }, 3)
      t.eq(ok, false)
      local message = tostring(failure)
      t.is_true(message:find("runtime-effect-failed: sha256 exit=19", 1, true) ~= nil)
      t.is_true(message:find("Host error=", 1, true) ~= nil)
      t.is_true(#message < 2300)
      t.eq(message:find("secret-host-tail", 1, true), nil)
    end)
  end,

  test_runtime_effect_failure_is_classified_and_bounded = function()
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      file = { write = function() end, read = function() return "unused" end },
      json = { decode = function() return {} end },
      exec_argv = function(spec)
        if spec.argv[2] == "-e" then return { exit_code = 0 } end
        return { exit_code = 17, stderr = string.rep("x", 5000) .. "\nsecret-tail" }
      end,
    }, function()
      local ok, failure = pcall(runtime.call_cli, "sha256", {
        artifact_root = ".testing/runs/runtime-failure",
        value = "fixture",
      }, 3)
      t.eq(ok, false)
      local message = tostring(failure)
      t.is_true(message:find("environment-factory: runtime-effect-failed: sha256 exit=17", 1, true) ~= nil)
      t.is_true(#message < 1300)
      t.eq(message:find("secret-tail", 1, true), nil)
    end)
  end,

  test_authority_callback_requires_exact_host_attestation_bindings = function()
    local authority = exact_ref("host-policy", "fixtures/runtime")
    local evidence = exact_ref("signed-attestation", "fixtures/runtime-approval")
    local approval = {
      authority = authority,
      policy_revision = "runtime-policy-1",
      evidence_ref = evidence,
    }
    local response = {
      ok = true,
      result = {
        profile = { revision = "runtime-profile" },
        approval = approval,
        receipt = {},
        context = {
          now = "2026-07-16T00:00:30Z",
          approval_ref = exact_ref("artifact", ".testing/runs/runtime/approval.json"),
          trusted_authorities = { {
            source_ref = authority,
            policy_revision = "runtime-policy-1",
            approval_sha256 = string.rep("a", 64),
            evidence_ref = evidence,
            authenticated = true,
          } },
        },
      },
    }
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      file = { write = function() end, read = function() return "bundle" end },
      json = { decode = function() return response end },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      local bundle = runtime.production().load_authorization_bundle({
        operation_id = "runtime-authority",
        artifact_root = ".testing/runs/runtime-authority",
      })
      local verify = bundle.context.trusted_authorities[1].verify
      local accepted = verify({ approval = approval, approval_sha256 = string.rep("a", 64) })
      t.eq(accepted.authenticated, true)
      t.eq(accepted.approval_sha256, string.rep("a", 64))
      t.eq(accepted.authority.ref, authority.ref)
      t.eq(accepted.evidence_ref.ref, evidence.ref)

      local wrong_digest = verify({ approval = approval, approval_sha256 = string.rep("b", 64) })
      t.eq(wrong_digest.authenticated, false)
      local foreign = {
        authority = authority,
        policy_revision = approval.policy_revision,
        evidence_ref = exact_ref("signed-attestation", "fixtures/foreign"),
      }
      t.eq(verify({ approval = foreign, approval_sha256 = string.rep("a", 64) }).authenticated, false)
    end)
  end,

  test_cached_claim_reuses_untransferred_group_and_transfers_exact_broker_shape = function()
    local authorization_calls, claim_calls, releases, executed = 0, {}, {}, {}
    local port = { name = "application", port = 4173 }
    local passed = { status = "passed", profile_snapshot = { revision = "cached" } }
    local responses = {
      { status = "planned", needs_claim = { port }, already_owned = {} },
      { found = true, outcome = passed }, passed,
      { status = "planned", needs_claim = { port }, already_owned = {} },
      { found = true, outcome = passed }, passed,
      { status = "running" }, { status = "cleaned" },
    }
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      network_listener = fake_listener_capability(claim_calls, releases),
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder(responses) },
      exec_argv = function(spec)
        table.insert(executed, spec)
        return { exit_code = 0 }
      end,
    }, function()
      local ports = runtime.production()
      local request = {
        artifact_root = ".testing/runs/runtime-cache",
        operation_id = "runtime-cache",
        effect_id = "runtime-cache/environment-factory/port-claim",
        runtime_ports = { port },
        listener_groups = { { port } },
        request_binding = { schema = "binding" },
        authorize = function()
          authorization_calls = authorization_calls + 1
          error("authorization must not run for a cached effect")
        end,
      }
      t.eq(ports.authorize_claim_ports(request).profile_snapshot.revision, "cached")
      t.eq(ports.authorize_claim_ports(request).profile_snapshot.revision, "cached")
      t.eq(#claim_calls, 1)

      local running = ports.run_argv({
        artifact_root = request.artifact_root,
        operation_id = request.operation_id,
        effect_id = "runtime-cache/service/start",
        mode = "supervised",
        listener_mode = "fkst-inherited-listeners-v1",
        runtime_ports = { port },
        timeout_seconds = 5,
      })
      t.eq(running.status, "running")
      local run_spec
      for _, spec in ipairs(executed) do
        if effect_name(spec) == "run-argv" then run_spec = spec end
      end
      t.eq(run_spec.inherited_listeners.claim.opaque_listener_claim, "runtime-cache:1")
      t.eq(run_spec.inherited_listeners.names[1], "application")
      t.eq(#releases, 1)

      ports.cleanup({
        artifact_root = request.artifact_root,
        operation_id = request.operation_id,
        effect_id = "runtime-cache/cleanup",
        timeout_seconds = 5,
      })
      t.eq(#releases, 1)
    end)
    t.eq(authorization_calls, 0)
  end,

  test_runtime_capability_function_cli_file_and_response_failures = function()
    local configured
    with_globals({
      environment_factory_runtime_config_ref = function(context)
        configured = context
        return config_ref
      end,
      file = { write = function() end, read = function() return "response" end },
      json = { decode = function() return { ok = true, result = { digest = string.rep("a", 64) } } end },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      local result = runtime.call_cli("sha256", {
        artifact_root = ".testing/runs/runtime-capability",
        operation_id = "runtime-capability",
        value = "fixture",
      }, 3)
      t.eq(result.digest, string.rep("a", 64))
      t.eq(configured.operation_id, "runtime-capability")
    end)

    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      environment_factory_runtime_cli = "bad\ncli",
      file = { write = function() end, read = function() return "response" end },
      json = { decode = function() return {} end },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      t.raises(function()
        runtime.call_cli("sha256", { artifact_root = ".testing/runs/runtime-bad-cli", value = "fixture" }, 3)
      end)
    end)

    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      file = false,
      json = { decode = function() return {} end },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      t.raises(function()
        runtime.call_cli("sha256", { artifact_root = ".testing/runs/runtime-no-file", value = "fixture" }, 3)
      end)
    end)

    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      file = { write = function() end, read = function() return "response" end },
      json = { decode = function() return { ok = false } end },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      t.raises(function()
        runtime.call_cli("sha256", { artifact_root = ".testing/runs/runtime-invalid-response", value = "fixture" }, 3)
      end)
    end)
  end,

  test_authorization_enters_before_group_acquisition_and_final_cleanup_drains_residuals = function()
    local order, claim_calls, releases = {}, {}, {}
    local database = { name = "database", port = 6301 }
    local application = { name = "application", port = 4173 }
    local responses = {
      {
        profile = { revision = "runtime-profile" }, approval = {}, receipt = {},
        context = {
          now = "2026-07-16T00:00:30Z",
          approval_ref = exact_ref("artifact", ".testing/runs/runtime-claim/approval.json"),
          trusted_authorities = {},
        },
      },
      { status = "planned", needs_claim = { database, application }, already_owned = {} },
      { found = false },
      { status = "passed", claim_id = "runtime-claim-id" },
      { status = "cleaned" },
    }
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      network_listener = {
        claim_loopback = function(request)
          table.insert(order, "claim-" .. request.listeners[1].name)
          return fake_listener_capability(claim_calls, releases).claim_loopback(request)
        end,
      },
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder(responses) },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      local ports = runtime.production()
      local bundle = ports.load_authorization_bundle({
        operation_id = "runtime-claim",
        artifact_root = ".testing/runs/runtime-claim",
      })
      t.raises(function() bundle.context.replay_guard({ approval_id = "outside" }) end)
      local outcome = ports.authorize_claim_ports({
        artifact_root = ".testing/runs/runtime-claim",
        operation_id = "runtime-claim",
        effect_id = "runtime-claim/environment-factory/port-claim",
        runtime_ports = { database, application },
        listener_groups = { { database }, { application } },
        request_binding = { schema = "binding" },
        authorize = function()
          table.insert(order, "authorize")
          local claim = bundle.context.replay_guard({
            approval_id = "approval",
            approval_sha256 = string.rep("a", 64),
          })
          t.eq(claim.claimed, true)
          table.insert(order, "authorized")
          return { revision = "runtime-profile" }
        end,
      })
      t.eq(outcome.status, "passed")
      t.eq(order[1], "authorize")
      t.eq(order[2], "claim-database")
      t.eq(order[3], "claim-application")
      t.eq(order[4], "authorized")
      t.eq(#claim_calls, 2)
      t.eq(#releases, 0)

      ports.cleanup({
        artifact_root = ".testing/runs/runtime-claim",
        operation_id = "runtime-claim",
        effect_id = "runtime-claim/cleanup",
        timeout_seconds = 5,
      })
      t.eq(#releases, 2)
    end)
  end,

  test_authorization_failure_before_and_after_replay_guard_releases_claims = function()
    local claim_calls, releases = {}, {}
    local port = { name = "application", port = 4174 }
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      network_listener = fake_listener_capability(claim_calls, releases),
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder({
        { status = "planned", needs_claim = { port }, already_owned = {} }, { found = false },
      }) },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      local ports = runtime.production()
      t.raises(function() ports.authorize_claim_ports({
        artifact_root = ".testing/runs/runtime-auth-failure", operation_id = "runtime-auth-failure",
        effect_id = "runtime-auth-failure/claim", runtime_ports = { port }, listener_groups = { { port } },
        request_binding = { schema = "binding" }, authorize = function() error("authorization rejected") end,
      }) end)
      t.eq(#claim_calls, 0)
      t.eq(#releases, 0)
    end)

    local bundle = { profile = {}, context = { trusted_authorities = {} } }
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      network_listener = fake_listener_capability(claim_calls, releases),
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder({ bundle,
        { status = "planned", needs_claim = { port }, already_owned = {} }, { found = false },
        { status = "passed", claim_id = "claim" },
      }) },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      local ports = runtime.production()
      local loaded = ports.load_authorization_bundle({ operation_id = "runtime-auth-after-claim",
        artifact_root = ".testing/runs/runtime-auth-after-claim" })
      local ok, failure = pcall(ports.authorize_claim_ports, {
        artifact_root = ".testing/runs/runtime-auth-after-claim", operation_id = "runtime-auth-after-claim",
        effect_id = "runtime-auth-after-claim/claim", runtime_ports = { port }, listener_groups = { { port } },
        request_binding = { schema = "binding" }, authorize = function()
          loaded.context.replay_guard({})
          error("snapshot construction failed")
        end,
      })
      t.eq(ok, false)
      t.is_true(tostring(failure):find("snapshot construction failed", 1, true) ~= nil)
      t.eq(#claim_calls, 1)
      t.eq(#releases, #claim_calls)
    end)
  end,

  test_supervised_start_failure_releases_transferred_and_residual_groups = function()
    local claim_calls, releases = {}, {}
    local database = { name = "database", port = 6302 }
    local application = { name = "application", port = 4175 }
    local passed = { status = "passed", profile_snapshot = { revision = "cached" } }
    local responses = {
      { status = "planned", needs_claim = { database, application }, already_owned = {} },
      { found = true, outcome = passed }, passed,
    }
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      network_listener = fake_listener_capability(claim_calls, releases),
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder(responses) },
      exec_argv = function(spec)
        if effect_name(spec) == "run-argv" then
          return { exit_code = 17, stderr = "startup failed" }
        end
        return { exit_code = 0 }
      end,
    }, function()
      local ports = runtime.production()
      ports.authorize_claim_ports({
        artifact_root = ".testing/runs/runtime-start-failure",
        operation_id = "runtime-start-failure",
        effect_id = "runtime-start-failure/claim",
        runtime_ports = { database, application },
        listener_groups = { { database }, { application } },
        request_binding = { schema = "binding" },
        authorize = function() error("cached effect must not authorize") end,
      })
      t.eq(#claim_calls, 2)
      local ok = pcall(ports.run_argv, {
        artifact_root = ".testing/runs/runtime-start-failure",
        operation_id = "runtime-start-failure",
        effect_id = "runtime-start-failure/database/start",
        mode = "supervised",
        listener_mode = "fkst-inherited-listeners-v1",
        runtime_ports = { database },
        timeout_seconds = 5,
      })
      t.eq(ok, false)
      t.eq(#releases, 2)
    end)
  end,

  test_listener_plan_group_and_capability_failure_matrix = function()
    local port = { name = "application", port = 4180 }
    local other = { name = "database", port = 6310 }
    local passed = { status = "passed", profile_snapshot = { revision = "cached" } }
    local cases = {
      { responses = { {} }, runtime_ports = { port }, groups = { { port } } },
      { responses = { { status = "planned", needs_claim = { other }, already_owned = {} } },
        runtime_ports = { port }, groups = { { port } } },
      { responses = { { status = "planned", needs_claim = { port }, already_owned = {} } },
        runtime_ports = { port }, groups = { {} } },
      { responses = { { status = "planned", needs_claim = { port }, already_owned = {} } },
        runtime_ports = { port }, groups = { { other } } },
      { responses = {
          { status = "planned", needs_claim = { port }, already_owned = { other } },
          { found = true, outcome = passed },
        }, runtime_ports = { port, other }, groups = { { port, other } } },
      { responses = {
          { status = "planned", needs_claim = { port }, already_owned = {} },
          { found = true, outcome = passed },
        }, runtime_ports = { port }, groups = { { port } }, no_capability = true },
    }
    for index, case in ipairs(cases) do
      with_globals({
        environment_factory_runtime_config_ref = config_ref,
        network_listener = case.no_capability and {} or fake_listener_capability({}, {}),
        file = { write = function() end, read = function() return "response" end },
        json = { decode = response_decoder(case.responses) },
        exec_argv = function() return { exit_code = 0 } end,
      }, function()
        local ports = runtime.production()
        t.raises(function()
          ports.authorize_claim_ports({
            artifact_root = ".testing/runs/runtime-plan-" .. tostring(index),
            operation_id = "runtime-plan-" .. tostring(index),
            effect_id = "runtime-plan-" .. tostring(index) .. "/claim",
            runtime_ports = case.runtime_ports,
            listener_groups = case.groups,
            request_binding = { schema = "binding" },
            authorize = function() error("cached plan must not authorize") end,
          })
        end)
      end)
    end
  end,

  test_listener_partial_acquisition_and_cached_plan_divergence_release_claims = function()
    local first = { name = "database", port = 6311 }
    local second = { name = "application", port = 4181 }
    local passed = { status = "passed", profile_snapshot = { revision = "cached" } }

    local calls, releases = {}, {}
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      network_listener = {
        claim_loopback = function(request)
          table.insert(calls, request)
          if #calls == 2 then return {} end
          return fake_listener_capability({}, releases).claim_loopback(request)
        end,
      },
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder({
        { status = "planned", needs_claim = { first, second }, already_owned = {} },
        { found = true, outcome = passed },
      }) },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      t.raises(function()
        runtime.production().authorize_claim_ports({
          artifact_root = ".testing/runs/runtime-partial-acquire",
          operation_id = "runtime-partial-acquire",
          effect_id = "runtime-partial-acquire/claim",
          runtime_ports = { first, second },
          listener_groups = { { first }, { second } },
          request_binding = { schema = "binding" },
          authorize = function() error("cached effect must not authorize") end,
        })
      end)
      t.eq(#releases, 1)
    end)

    local function divergence(operation_id, first_plan, second_plan)
      local acquired, released = {}, {}
      with_globals({
        environment_factory_runtime_config_ref = config_ref,
        network_listener = fake_listener_capability(acquired, released),
        file = { write = function() end, read = function() return "response" end },
        json = { decode = response_decoder({
          first_plan, { found = true, outcome = passed }, passed,
          second_plan, { found = true, outcome = passed },
        }) },
        exec_argv = function() return { exit_code = 0 } end,
      }, function()
        local ports = runtime.production()
        local request = {
          artifact_root = ".testing/runs/" .. operation_id,
          operation_id = operation_id,
          effect_id = operation_id .. "/claim",
          runtime_ports = { first, second },
          listener_groups = { { first }, { second } },
          request_binding = { schema = "binding" },
          authorize = function() error("cached effect must not authorize") end,
        }
        ports.authorize_claim_ports(request)
        t.raises(function() ports.authorize_claim_ports(request) end)
        t.eq(#released, #acquired)
      end)
    end
    divergence("runtime-cache-incomplete",
      { status = "planned", needs_claim = { first }, already_owned = { second } },
      { status = "planned", needs_claim = { first, second }, already_owned = {} })
    divergence("runtime-cache-different",
      { status = "planned", needs_claim = { first, second }, already_owned = {} },
      { status = "planned", needs_claim = { first }, already_owned = { second } })
  end,

  test_authorize_and_supervised_failure_cleanup_matrix = function()
    local port = { name = "application", port = 4182 }
    local passed = { status = "passed", profile_snapshot = { revision = "cached" } }

    local function cached_failure(operation_id, run, responses, exec)
      local acquired, released = {}, {}
      with_globals({
        environment_factory_runtime_config_ref = config_ref,
        network_listener = fake_listener_capability(acquired, released),
        file = { write = function() end, read = function() return "response" end },
        json = { decode = response_decoder(responses) },
        exec_argv = exec or function() return { exit_code = 0 } end,
      }, function()
        local ports = runtime.production()
        local request = {
          artifact_root = ".testing/runs/" .. operation_id,
          operation_id = operation_id,
          effect_id = operation_id .. "/claim",
          runtime_ports = { port },
          listener_groups = { { port } },
          request_binding = { schema = "binding" },
          authorize = function() error("cached effect must not authorize") end,
        }
        ports.authorize_claim_ports(request)
        run(ports, request)
        t.eq(#released, #acquired)
      end)
    end

    cached_failure("runtime-invalid-mode", function(ports, request)
      t.raises(function() ports.run_argv({ artifact_root = request.artifact_root,
        operation_id = request.operation_id, effect_id = request.operation_id .. "/start",
        mode = "supervised", listener_mode = "direct-bind", runtime_ports = { port } }) end)
    end, {
      { status = "planned", needs_claim = { port }, already_owned = {} },
      { found = true, outcome = passed }, passed,
    })

    cached_failure("runtime-missing-group", function(ports, request)
      t.raises(function() ports.run_argv({ artifact_root = request.artifact_root,
        operation_id = request.operation_id, effect_id = request.operation_id .. "/start",
        mode = "supervised", listener_mode = "fkst-inherited-listeners-v1",
        runtime_ports = { { name = "foreign", port = 4183 } } }) end)
    end, {
      { status = "planned", needs_claim = { port }, already_owned = {} },
      { found = true, outcome = passed }, passed,
    })

    cached_failure("runtime-blocked-start", function(ports, request)
      t.eq(ports.run_argv({ artifact_root = request.artifact_root,
        operation_id = request.operation_id, effect_id = request.operation_id .. "/start",
        mode = "supervised", listener_mode = "fkst-inherited-listeners-v1",
        runtime_ports = { port }, timeout_seconds = 5 }).status, "blocked")
    end, {
      { status = "planned", needs_claim = { port }, already_owned = {} },
      { found = true, outcome = passed }, passed, { status = "blocked" },
    })

    cached_failure("runtime-cached-verification-blocked", function() end, {
      { status = "planned", needs_claim = { port }, already_owned = {} },
      { found = true, outcome = passed }, { status = "blocked" },
    })

    local acquired, released = {}, {}
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      network_listener = fake_listener_capability(acquired, released),
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder({
        { status = "planned", needs_claim = { port }, already_owned = {} },
        { found = true, outcome = passed },
      }) },
      exec_argv = function(spec)
        if effect_name(spec) == "authorize-claim-ports" then return { exit_code = 19, stderr = "verify failed" } end
        return { exit_code = 0 }
      end,
    }, function()
      t.raises(function() runtime.production().authorize_claim_ports({
        artifact_root = ".testing/runs/runtime-cached-verify-failure",
        operation_id = "runtime-cached-verify-failure",
        effect_id = "runtime-cached-verify-failure/claim",
        runtime_ports = { port }, listener_groups = { { port } },
        request_binding = { schema = "binding" }, authorize = function() error("cached") end,
      }) end)
      t.eq(#released, #acquired)
    end)
  end,

  test_uncached_authorize_effect_failure_and_missing_replay_outcome_release = function()
    local port = { name = "application", port = 4184 }
    local bundle = {
      profile = { revision = "runtime-profile" }, approval = {}, receipt = {},
      context = { now = "2026-07-16T00:00:30Z",
        approval_ref = exact_ref("artifact", ".testing/runs/runtime-uncached/approval.json"),
        trusted_authorities = {} },
    }
    local acquired, released = {}, {}
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      network_listener = fake_listener_capability(acquired, released),
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder({ bundle,
        { status = "planned", needs_claim = { port }, already_owned = {} }, { found = false } }) },
      exec_argv = function(spec)
        if effect_name(spec) == "authorize-claim-ports" then return { exit_code = 20, stderr = "claim failed" } end
        return { exit_code = 0 }
      end,
    }, function()
      local ports = runtime.production()
      local loaded = ports.load_authorization_bundle({ operation_id = "runtime-uncached",
        artifact_root = ".testing/runs/runtime-uncached" })
      local ok, failure = pcall(ports.authorize_claim_ports, {
        artifact_root = ".testing/runs/runtime-uncached", operation_id = "runtime-uncached",
        effect_id = "runtime-uncached/claim", runtime_ports = { port }, listener_groups = { { port } },
        request_binding = { schema = "binding" }, authorize = function()
          loaded.context.replay_guard({ approval_id = "approval", approval_sha256 = string.rep("a", 64) })
        end,
      })
      t.eq(ok, false)
      t.is_true(tostring(failure):find("authorize-claim-ports exit=20", 1, true) ~= nil)
      t.eq(#acquired, 1)
      t.eq(#released, #acquired)
    end)

    acquired, released = {}, {}
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      network_listener = fake_listener_capability(acquired, released),
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder({ bundle,
        { status = "planned", needs_claim = { port }, already_owned = {} }, { found = false },
        { status = "blocked" } }) },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      local ports = runtime.production()
      local loaded = ports.load_authorization_bundle({ operation_id = "runtime-uncached-blocked",
        artifact_root = ".testing/runs/runtime-uncached-blocked" })
      local outcome = ports.authorize_claim_ports({
        artifact_root = ".testing/runs/runtime-uncached-blocked", operation_id = "runtime-uncached-blocked",
        effect_id = "runtime-uncached-blocked/claim", runtime_ports = { port }, listener_groups = { { port } },
        request_binding = { schema = "binding" }, authorize = function()
          local claim = loaded.context.replay_guard({ approval_id = "approval",
            approval_sha256 = string.rep("a", 64) })
          t.eq(claim.claimed, false)
          return { revision = "snapshot" }
        end,
      })
      t.eq(outcome.status, "blocked")
      t.eq(#released, #acquired)
    end)

    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      file = { write = function() end, read = function() return "response" end },
      json = { decode = response_decoder({
        { status = "planned", needs_claim = { port }, already_owned = {} }, { found = false },
      }) },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      t.raises(function() runtime.production().authorize_claim_ports({
        artifact_root = ".testing/runs/runtime-missing-replay", operation_id = "runtime-missing-replay",
        effect_id = "runtime-missing-replay/claim", runtime_ports = { port }, listener_groups = { { port } },
        request_binding = { schema = "binding" }, authorize = function() return { revision = "snapshot" } end,
      }) end)
    end)
  end,

  test_production_accepts_explicit_runtime_providers_and_globals_override_them = function()
    local executed = {}
    local option_ref = exact_ref("artifact", ".testing/host/environment-factory/options/config.json")
    local global_ref = exact_ref("artifact", ".testing/host/environment-factory/global/config.json")
    with_globals({
      file = { write = function() end, read = function() return "response" end },
      json = { decode = function() return { ok = true, result = { remaining_seconds = 4 } } end },
      exec_argv = function(spec) table.insert(executed, spec); return { exit_code = 0 } end,
    }, function()
      local ports = runtime.production({
        runtime_config_ref = option_ref,
        runtime_cli = "fixtures/explicit-environment-runtime.js",
      })
      t.eq(ports.remaining_budget({
        artifact_root = ".testing/runs/runtime-explicit",
        operation_id = "runtime-explicit",
        deadline_epoch_seconds = 10,
        total_seconds = 10,
      }), 4)
    end)
    t.eq(executed[#executed].argv[2], "fixtures/explicit-environment-runtime.js")

    with_globals({
      os = { getenv = function(name)
        if name == "FKST_ENVIRONMENT_FACTORY_RUNTIME_CONFIG_REF" then
          return ".testing/host/environment-factory/environment/config.json"
        end
        if name == "FKST_ENVIRONMENT_FACTORY_RUNTIME_CLI" then
          return "fixtures/environment-environment-runtime.js"
        end
        return nil
      end },
      file = { write = function(path, body) executed.environment_body = body end,
        read = function() return "response" end },
      json = { decode = function() return { ok = true, result = { remaining_seconds = 2 } } end },
      exec_argv = function(spec) executed.environment = spec; return { exit_code = 0 } end,
    }, function()
      t.eq(runtime.production().remaining_budget({
        artifact_root = ".testing/runs/runtime-environment",
        operation_id = "runtime-environment",
        deadline_epoch_seconds = 10,
        total_seconds = 10,
      }), 2)
    end)
    t.eq(executed.environment.argv[2], "fixtures/environment-environment-runtime.js")
    t.is_true(executed.environment_body:find(".testing/host/environment-factory/environment/config.json", 1, true) ~= nil)

    with_globals({
      environment_factory_runtime_config_ref = global_ref,
      environment_factory_runtime_cli = "fixtures/global-environment-runtime.js",
      file = { write = function(path, body) executed.request_path = path; executed.request_body = body end,
        read = function() return "response" end },
      json = { decode = function() return { ok = true, result = { remaining_seconds = 3 } } end },
      exec_argv = function(spec) executed.global = spec; return { exit_code = 0 } end,
    }, function()
      local ports = runtime.production({
        runtime_config_ref = option_ref,
        runtime_cli = "fixtures/explicit-environment-runtime.js",
      })
      t.eq(ports.remaining_budget({
        artifact_root = ".testing/runs/runtime-global",
        operation_id = "runtime-global",
        deadline_epoch_seconds = 10,
        total_seconds = 10,
      }), 3)
    end)
    t.eq(executed.global.argv[2], "fixtures/global-environment-runtime.js")
    t.is_true(executed.request_body:find(global_ref.ref, 1, true) ~= nil)
    t.eq(executed.request_body:find(option_ref.ref, 1, true), nil)
  end,

  test_runtime_config_capability_must_be_outside_operation_artifact_root = function()
    with_globals({
      environment_factory_runtime_config_ref = {
        kind = "artifact",
        ref = ".testing/runs/runtime-inside/config.json",
      },
      file = { write = function() end, read = function() return "response" end },
      json = { decode = function() return { ok = true, result = {} } end },
      exec_argv = function() error("runtime must not execute with an in-root config capability") end,
    }, function()
      local ok, failure = pcall(runtime.call_cli, "sha256", {
        artifact_root = ".testing/runs/runtime-inside",
        value = "fixture",
      }, 3)
      t.eq(ok, false)
      t.is_true(tostring(failure):find("runtime-config-inside-operation-root", 1, true) ~= nil)
    end)
  end,

  test_runtime_config_capability_is_required = function()
    with_globals({
      environment_factory_runtime_config_ref = false,
      file = { write = function() end, read = function() return "" end },
      json = { decode = function() return {} end },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      local ok, failure = pcall(runtime.call_cli, "sha256", {
        artifact_root = ".testing/runs/runtime-config-missing",
        value = "fixture",
      }, 3)
      t.eq(ok, false)
      t.is_true(tostring(failure):find("runtime-config-unavailable", 1, true) ~= nil)
    end)
  end,

  test_runtime_request_requires_an_artifact_root = function()
    with_globals({
      environment_factory_runtime_config_ref = config_ref,
      file = { write = function() end, read = function() return "" end },
      json = { decode = function() return {} end },
      exec_argv = function() return { exit_code = 0 } end,
    }, function()
      local ok, failure = pcall(runtime.call_cli, "sha256", { value = "fixture" }, 3)
      t.eq(ok, false)
      t.is_true(tostring(failure):find("runtime-request-root-missing", 1, true) ~= nil)
    end)
  end,
}
