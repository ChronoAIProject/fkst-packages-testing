local runtime = require("runtime")

local P = {}

local function unavailable(name)
  return function()
    error("testing-design: runtime-port-unavailable: " .. name)
  end
end

function P.production()
  local host = rawget(_G, "testing_design_runtime")
  if type(host) == "table" then
    return {
      analyze = type(host.analyze) == "function" and host.analyze or unavailable("analyze"),
      generate_candidates = type(host.generate_candidates) == "function" and host.generate_candidates or unavailable("generate_candidates"),
    }
  end
  return runtime.production()
end

function P.resolve(value)
  local ports = value or P.production()
  if type(ports) ~= "table" or type(ports.analyze) ~= "function" then
    error("testing-design: invalid-runtime: missing analyze")
  end
  return ports
end

function P.resolve_generation(value)
  local ports = value or P.production()
  if type(ports) ~= "table" or type(ports.generate_candidates) ~= "function" then
    error("testing-design: invalid-generation-port: missing generate_candidates")
  end
  return ports
end

return P
