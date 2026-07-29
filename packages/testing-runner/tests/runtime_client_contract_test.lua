local fixture_factory = require("testing_runtime.tests.runtime_client_fixture")
local runtime_client = require("testing_runtime.runtime_client")
local t = fkst.test

local function spec(extra)
  local value = {
    error_prefix = "runtime-client-test",
    scratch_root = ".testing/runtime/client-test",
  }
  for key, item in pairs(extra or {}) do value[key] = item end
  return value
end

local function client(extra_spec, extra_options, responses)
  local fixture = fixture_factory.new(responses or { effect = { value = "ok" } })
  local options = fixture.options
  for key, value in pairs(extra_options or {}) do options[key] = value end
  return runtime_client.new(spec(extra_spec), options), fixture
end

local function call(value, root, listener_options)
  return value.call("effect", { run_id = "run" }, root, "identity", 7, listener_options)
end

return {
  test_configuration_and_runtime_config_contracts = function()
    local value = runtime_client.new(spec({ cli_global = "runtime_client_test_cli" }), {
      runtime_cli = "option-runtime.js",
    })
    t.eq(value.configured(), true)

    local configured, fixture = client({ runtime_config_required = true }, {
      runtime_config_ref = ".testing/config/runtime.json",
    })
    t.eq(call(configured).value, "ok")
    t.eq(fixture.effect_calls()[1].payload.runtime_config_ref.ref, ".testing/config/runtime.json")

    local missing = client({ runtime_config_required = true })
    t.raises(function() call(missing) end)
    local invalid = client({}, { runtime_config_ref = { kind = "file", ref = "bad" } })
    t.raises(function() call(invalid) end)

    local validated = false
    local checked = client({
      runtime_config_context = function(_request, root, name)
        return { root = root, name = name }
      end,
      validate_runtime_config = function(config, context)
        validated = config.ref == ".testing/config/checked.json"
          and context.root == ".testing/runs/checked" and context.name == "effect"
      end,
    }, {
      runtime_config_ref = function(context)
        t.eq(context.root, ".testing/runs/checked")
        return { kind = "artifact", ref = ".testing/config/checked.json" }
      end,
    })
    call(checked, ".testing/runs/checked")
    t.eq(validated, true)
  end,

  test_io_root_stale_and_unavailable_fail_closed = function()
    local invalid = client()
    t.raises(function() call(invalid, "outside") end)

    local stale, stale_fixture = client()
    stale_fixture.modes.prepare_exit_code = 53
    t.raises(function() call(stale) end)

    local unavailable, unavailable_fixture = client()
    unavailable_fixture.modes.prepare_exit_code = 52
    t.raises(function() call(unavailable) end)

    local skipped = client({ skip_io_prepare = function() return true end })
    t.eq(call(skipped).value, "ok")
    local skipped_invalid = client({ skip_io_prepare = function() return true end })
    t.raises(function() call(skipped_invalid, "outside") end)
  end,

  test_response_correlation_legacy_and_decode_contracts = function()
    local mismatched, mismatch_fixture = client()
    mismatch_fixture.modes.request_id = "stale-request"
    t.raises(function() call(mismatched) end)

    local missing, missing_fixture = client()
    missing_fixture.modes.missing_request_id = true
    t.raises(function() call(missing) end)

    local legacy, legacy_fixture = client({ allow_legacy_response = true })
    legacy_fixture.modes.missing_request_id = true
    t.eq(call(legacy).value, "ok")

    local legacy_function, function_fixture = client({
      allow_legacy_response = function(cli, _options, request, name)
        return cli == "fixtures/fake-runtime.js" and request.run_id == "run" and name == "effect"
      end,
    })
    function_fixture.modes.missing_request_id = true
    t.eq(call(legacy_function).value, "ok")

    local unreadable, unreadable_fixture = client()
    unreadable_fixture.modes.read_error = true
    t.raises(function() call(unreadable) end)
    local malformed, malformed_fixture = client()
    malformed_fixture.modes.decode_error = true
    t.raises(function() call(malformed) end)
  end,

  test_host_failures_are_bounded_and_listener_options_are_applied = function()
    local failed, failed_fixture = client({}, {}, {
      effect = { ok = false, error = string.rep("host\n", 400) },
    })
    failed_fixture.modes.exit_code = 9
    failed_fixture.modes.stderr = string.rep("stderr\n", 400)
    local ok, failure = pcall(call, failed)
    t.eq(ok, false)
    t.is_true(tostring(failure):find("exit=9", 1, true) ~= nil)
    t.is_true(#tostring(failure) < 2200)

    local invalid = client({}, {}, { effect = { ok = false, error = "invalid host result" } })
    local valid, invalid_error = pcall(call, invalid)
    t.eq(valid, false)
    t.is_true(tostring(invalid_error):find("Host error=invalid host result", 1, true) ~= nil)

    local default_listener, default_fixture = client()
    call(default_listener, nil, { claim = "opaque" })
    t.eq(default_fixture.effect_calls()[1].request.listener_options.claim, "opaque")

    local custom_listener, custom_fixture = client({
      apply_listener_options = function(exec_request, options, request, name)
        exec_request.listener_claim = options.claim
        t.eq(request.run_id, "run")
        t.eq(name, "effect")
      end,
    })
    call(custom_listener, nil, { claim = "custom" })
    t.eq(custom_fixture.effect_calls()[1].request.listener_claim, "custom")
  end,
}
