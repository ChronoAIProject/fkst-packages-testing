local P = {}

local function unavailable(name)
  return function()
    error("testing-runtime: port-unavailable: " .. name)
  end
end

function P.production()
  return {
    exec_argv = type(exec_argv) == "function" and function(argv, timeout)
      return exec_argv({ argv = argv, timeout = timeout or 30 })
    end or unavailable("exec_argv"),
    read = type(file) == "table" and type(file.read) == "function" and function(path)
      return file.read(path)
    end or unavailable("file.read"),
    write = type(file) == "table" and type(file.write) == "function" and function(path, body)
      file.write(path, body)
      return true
    end or unavailable("file.write"),
    decode = type(json) == "table" and type(json.decode) == "function" and function(body)
      return json.decode(body)
    end or unavailable("json.decode"),
  }
end

function P.resolve(ports)
  local value = ports or P.production()
  for _, name in ipairs({ "exec_argv", "read", "write", "decode" }) do
    if type(value[name]) ~= "function" then
      error("testing-runtime: invalid-ports: missing " .. name)
    end
  end
  return value
end

return P
