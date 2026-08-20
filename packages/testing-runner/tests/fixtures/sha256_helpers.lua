local function quote(value) return string.format("%q", value) end

return function(bytes)
  local input, output = os.tmpname(), os.tmpname()
  local handle = assert(io.open(input, "wb")); handle:write(bytes); handle:close()
  local commands = {
    "shasum -a 256 " .. quote(input),
    "sha256sum " .. quote(input),
    "openssl dgst -sha256 " .. quote(input),
  }
  for _, command in ipairs(commands) do
    os.execute(command .. " > " .. quote(output) .. " 2>/dev/null")
    local digest_file = io.open(output, "r")
    local line = digest_file and digest_file:read("*l") or ""
    if digest_file then digest_file:close() end
    for candidate in tostring(line):gmatch("[0-9A-Fa-f]+") do
      if #candidate == 64 then os.remove(input); os.remove(output); return candidate:lower() end
    end
  end
  os.remove(input); os.remove(output)
  error("no SHA-256 command is available")
end
