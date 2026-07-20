local runtime = require("runtime")

local P = {}

local function unavailable()
  error("testing-design: runtime-port-unavailable: analyze")
end

function P.production()
  local host = rawget(_G, "testing_design_runtime")
  if type(host) == "table" then
    return { analyze = type(host.analyze) == "function" and host.analyze or unavailable }
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

return P
