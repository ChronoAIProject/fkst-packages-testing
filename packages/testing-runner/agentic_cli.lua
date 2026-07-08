local M = {}

local function blocked()
  error("testing-runner: legacy-backend: agentic-testing backend is not executable")
end

function M.argv()
  blocked()
end

function M.command()
  blocked()
end

function M.adapter()
  return {
    name = "fkst-native",
    mode = "legacy-backend-blocked",
  }
end

function M.run(_job, _payload, context)
  return context.result_payload("blocked", {
    adapter = M.adapter(),
    stderr = "testing-runner legacy agentic-testing backend is not executable",
  })
end

return M
