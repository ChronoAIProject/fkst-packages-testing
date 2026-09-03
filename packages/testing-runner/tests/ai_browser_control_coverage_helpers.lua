local compat = require("contract.testing_results_compat")

local M = {}

local function with_compat_projection(project_v1, body)
  local original_supported = compat.projection_supported
  local original_project_v1 = compat.project_v1
  compat.projection_supported = function() return true end
  compat.project_v1 = project_v1
  local ok, result = pcall(body)
  compat.projection_supported = original_supported
  compat.project_v1 = original_project_v1
  if not ok then error(result) end
  return result
end

function M.build(deps)
  local browser = deps.browser
  local controller = deps.controller
  local fixture = deps.fixture
  local json_codec = deps.json_codec
  local observation = deps.observation
  local ports = deps.ports
  local sha256 = deps.sha256
  local structured = deps.structured
  local t = deps.t

  return {
    compatibility_projection_replays_without_effects_and_fails_closed_on_write = function()
      local request, artifacts, grant = fixture()
      local writes, effects, interrupted = {}, 0, false
      local first = ports(request, artifacts, grant, {
        writes = writes,
        callback_turn = 1,
        failpoint = function(name)
          if name == "after-case-result-set-write" and not interrupted then
            interrupted = true
            error("result write interrupted")
          end
        end,
        act = function(turn, selected)
          effects = effects + 1
          return {
            schema = browser.schemas.step_receipt, turn = turn,
            action = structured.copy(selected), before = observation(turn),
            after = observation(turn, { callback = true }), status = "executed",
            classification = "effect-applied",
          }
        end,
      })
      t.eq(controller.run(request, first).status, "blocked")

      local compatibility_path = request.artifact_root .. "/case-results.json"
      local projected = {
        schema = compat.schema,
        plan_sha256 = request.reviewed_plan_sha256,
        cases = {},
      }
      local projection_context
      with_compat_projection(function(_, _, context)
        projection_context = context
        return structured.copy(projected)
      end, function()
        local second = ports(request, artifacts, grant, {
          writes = writes,
          claim = { status = "in-progress", claim_id = "claim-browser" },
          act = function() effects = effects + 1; error("effect must not repeat") end,
        })
        local result = controller.run(request, second)
        t.eq(result.status, "passed")
        t.eq(result.case_results_path, compatibility_path)
        t.eq(json_codec.encode(writes[compatibility_path]), json_codec.encode(projected))
        t.eq(projection_context.artifact_root, request.artifact_root)
        t.eq(projection_context.plan_sha256, request.reviewed_plan_sha256)
        t.eq(projection_context.plan, artifacts[request.reviewed_plan_ref].value)
        t.eq(projection_context.run_id, "ai-browser")
        t.eq(projection_context.plan_ref.ref, request.artifact_root .. "/test-plan.json")
        t.eq(projection_context.trace_id, request.trace_id)
        t.eq(projection_context.dedup_key, request.dedup_key)
        t.eq(projection_context.sha256_bytes, second.sha256)
        t.eq(projection_context.repository.source_ref.kind, "git")
        t.eq(effects, 1)

        local failing = ports(request, artifacts, grant, {
          writes = writes,
          claim = { status = "in-progress", claim_id = "claim-browser" },
          act = function() effects = effects + 1; error("effect must not repeat") end,
        })
        local write = failing.write_artifact
        failing.write_artifact = function(path, value)
          if path == compatibility_path then return false end
          return write(path, value)
        end
        local failure = controller.run(request, failing)
        t.eq(failure.status, "blocked")
        t.is_true(failure.message:find(
          "compatibility result artifact write failed", 1, true) ~= nil)
        t.eq(effects, 1)
        t.eq(sha256(json_codec.encode(writes[compatibility_path]) .. "\n"),
          failing.artifact_digest(compatibility_path))
      end)
    end,
  }
end

return M
