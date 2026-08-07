local json_codec = require("testing_runtime.json")

local project_root
local command_sequence = 0

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function equal(left, right)
  if left == right then return true end
  if type(left) ~= "table" or type(right) ~= "table" then return false end
  for key, value in pairs(left) do
    if not equal(value, right[key]) then return false end
  end
  for key, _ in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local handle = io.open(path, "rb")
  if handle == nil then return nil end
  local value = handle:read("*a")
  handle:close()
  return value
end

local function write_file(path, value)
  local parent = tostring(path):match("^(.*)/[^/]+$")
  if parent ~= nil then
    os.execute("mkdir -p " .. shell_quote(parent))
  end
  local handle = assert(io.open(path, "wb"))
  handle:write(value)
  handle:close()
end

local function direct_exec(argv, cwd)
  local rendered = {}
  for _, item in ipairs(argv) do table.insert(rendered, shell_quote(item)) end
  local command = table.concat(rendered, " ")
  if cwd ~= nil then command = "cd " .. shell_quote(cwd) .. " && " .. command end
  command_sequence = command_sequence + 1
  local stdout_path = os.tmpname() .. "-canonical-stdout-" .. tostring(command_sequence)
  local stderr_path = os.tmpname() .. "-canonical-stderr-" .. tostring(command_sequence)
  local ok, _, code = os.execute(command .. " >" .. shell_quote(stdout_path) .. " 2>" .. shell_quote(stderr_path))
  local stdout = read_file(stdout_path) or ""
  local stderr = read_file(stderr_path) or ""
  os.remove(stdout_path)
  os.remove(stderr_path)
  return {
    exit_code = ok == true and 0 or tonumber(code) or (type(ok) == "number" and ok) or -1,
    stdout = stdout,
    stderr = stderr,
  }
end

local function require_exec(argv, cwd)
  local result = direct_exec(argv, cwd)
  if result.exit_code ~= 0 then
    error("canonical host command failed: " .. tostring(argv[1]) .. " exit=" .. tostring(result.exit_code)
      .. " stderr=" .. tostring(result.stderr), 0)
  end
  return result.stdout
end

local function remove_tree(path, allowed_prefix)
  local script = table.concat({
    "const fs=require('fs');const path=process.argv[1],prefix=process.argv[2];",
    "if(!path.startsWith(prefix)||path===prefix)process.exit(44);",
    "fs.rmSync(path,{recursive:true,force:true});",
  })
  require_exec({ "node", "-e", script, path, allowed_prefix })
end

project_root = require_exec({ "node", "-e", "process.stdout.write(process.cwd())" }):gsub("%s+$", "")

local function prepare_supervisor_project(root)
  local script = table.concat({
    "const fs=require('fs'),path=require('path'),source=process.argv[1],target=process.argv[2],platform=process.argv[3];",
    "fs.mkdirSync(path.join(target,'packages'),{recursive:true});fs.mkdirSync(path.join(target,'libraries'),{recursive:true});",
    "for(const name of fs.readdirSync(path.join(source,'packages'))){const from=path.join(source,'packages',name),to=path.join(target,'packages',name);",
    "if(fs.statSync(from).isDirectory())fs.cpSync(from,to,{recursive:true});}",
    "for(const name of fs.readdirSync(path.join(source,'libraries'))){const from=path.join(source,'libraries',name),to=path.join(target,'libraries',name);",
    "if(fs.statSync(from).isDirectory())fs.cpSync(from,to,{recursive:true});}",
    "const localLibraries=path.join(source,'.fkst','local-libraries');if(fs.existsSync(localLibraries)){",
    "for(const name of fs.readdirSync(localLibraries)){const from=path.join(localLibraries,name),to=path.join(target,'libraries',name);",
    "if(fs.statSync(from).isDirectory()&&!fs.existsSync(to))fs.cpSync(from,to,{recursive:true});}}",
    "for(const group of ['packages','libraries']){const base=path.join(platform,group);if(!fs.existsSync(base))continue;",
    "for(const name of fs.readdirSync(base)){const from=path.join(base,name),to=path.join(target,group,name);",
    "if(fs.statSync(from).isDirectory()&&!fs.existsSync(to))fs.cpSync(from,to,{recursive:true});}}",
    "fs.cpSync(path.join(source,'examples','generic-host'),path.join(target,'packages','generic-host'),{recursive:true});",
  })
  require_exec({
    "node", "-e", script, project_root, root,
    project_root .. "/.fkst/run/fkst-packages-conformance",
  })
  write_file(root .. "/fkst.workspace.toml", table.concat({
    "[workspace]",
    "units = [\"packages/*\", \"libraries/*\"]",
    "packages = [\"packages/*\"]",
    "libraries = [\"libraries/*\"]",
    "",
    "[registries]",
    "workspace = \"workspace\"",
    "",
  }, "\n"))
end

local function absolute(path)
  if tostring(path):sub(1, 1) == "/" then return path end
  return project_root .. "/" .. path
end

local function sha256_bytes(bytes)
  command_sequence = command_sequence + 1
  local input = os.tmpname() .. "-canonical-sha-input-" .. tostring(command_sequence)
  write_file(input, bytes)
  local body = require_exec({
    "node", "-e",
    "const fs=require('fs'),crypto=require('crypto');process.stdout.write(crypto.createHash('sha256').update(fs.readFileSync(process.argv[1])).digest('hex'))",
    input,
  })
  os.remove(input)
  local digest = body:match("([0-9a-f]+)")
  if type(digest) ~= "string" or #digest ~= 64 then error("canonical host sha256 unavailable") end
  return digest
end

local function reserve_port()
  local script = table.concat({
    "const net=require('net');const server=net.createServer();",
    "server.listen(0,'127.0.0.1',()=>{const port=server.address().port;server.close(()=>process.stdout.write(String(port)))})",
  })
  return assert(tonumber(require_exec({ "node", "-e", script })))
end

local function ref(path)
  return { kind = "artifact", ref = path }
end

local Store = {}
Store.__index = Store

local function decode_json(body)
  if type(json) ~= "table" or type(json.decode) ~= "function" then return nil end
  local ok, value = pcall(json.decode, body)
  return ok and value or nil
end

function Store.new()
  return setmetatable({ artifacts = {}, writes = {} }, Store)
end

function Store:_from_disk(path)
  local body = read_file(absolute(path))
  if body == nil or body == "" then return nil end
  local value = decode_json(body)
  if type(value) ~= "table" then value = body end
  local entry = { value = value, raw = body, digest = sha256_bytes(body) }
  self.artifacts[path] = entry
  return entry
end

function Store:load(path)
  local entry = self.artifacts[path] or self:_from_disk(path)
  return entry and copy(entry) or nil
end

function Store:write(path, value)
  local existing = self.artifacts[path] or self:_from_disk(path)
  if existing ~= nil then return equal(existing.value, value) end
  local body = json_codec.encode(value) .. "\n"
  return self:write_raw(path, body, value)
end

function Store:write_raw(path, body, decoded)
  local existing = self.artifacts[path] or self:_from_disk(path)
  if existing ~= nil then return existing.raw == body end
  if decoded == nil then
    local value = decode_json(body)
    decoded = type(value) == "table" and value or body
  end
  write_file(absolute(path), body)
  self.artifacts[path] = { value = copy(decoded), raw = body, digest = sha256_bytes(body) }
  self.writes[path] = (self.writes[path] or 0) + 1
  return true
end

function Store:digest(path)
  local entry = self.artifacts[path] or self:_from_disk(path)
  return entry and entry.digest or nil
end

function Store:write_count(path)
  return self.writes[path] or 0
end

local function artifact_reference(schema, path, digest)
  return {
    schema = "testing-design.artifact-reference.v1",
    artifact_schema = schema,
    artifact_pointer = path,
    artifact_digest = digest,
  }
end

local function spawn_process(argv, cwd, root)
  local rendered = {}
  for _, item in ipairs(argv) do table.insert(rendered, shell_quote(item)) end
  local stdout_path = root .. "/server.stdout"
  local stderr_path = root .. "/server.stderr"
  local pid_path = root .. "/server.pid"
  os.execute("mkdir -p " .. shell_quote(root))
  local body = "cd " .. shell_quote(cwd) .. " && " .. table.concat(rendered, " ")
    .. " >" .. shell_quote(stdout_path) .. " 2>" .. shell_quote(stderr_path)
    .. " & echo $! >" .. shell_quote(pid_path)
  local ok = os.execute("sh -c " .. shell_quote(body))
  if ok ~= true and ok ~= 0 then error("canonical fixture server failed to start") end
  local pid = tonumber((read_file(pid_path) or ""):match("(%d+)"))
  if pid == nil then error("canonical fixture server pid unavailable") end
  return pid
end

local function wait_http(url, timeout_seconds)
  local script = table.concat({
    "const http=require('http');const url=process.argv[1],end=Date.now()+Number(process.argv[2])*1000;",
    "function probe(){const req=http.get(url,res=>{res.resume();if(res.statusCode===200)process.exit(0);retry()});",
    "req.on('error',retry);req.setTimeout(250,()=>req.destroy());}",
    "function retry(){if(Date.now()>=end)process.exit(47);setTimeout(probe,20)}probe();",
  })
  return direct_exec({ "node", "-e", script, url, tostring(timeout_seconds or 10) }).exit_code == 0
end

local function http_request(request, timeout_seconds)
  local script = table.concat({
    "const http=require('http'),u=new URL(process.argv[1]);",
    "const req=http.request({hostname:u.hostname,port:u.port,path:u.pathname+u.search,method:process.argv[2],timeout:Number(process.argv[3])*1000},res=>{",
    "let body='';res.setEncoding('utf8');res.on('data',c=>body+=c);res.on('end',()=>process.stdout.write(JSON.stringify({status:res.statusCode,headers:res.headers,body})));",
    "});req.on('timeout',()=>req.destroy(new Error('timeout')));req.on('error',error=>{process.stderr.write(error.message);process.exit(48)});req.end();",
  })
  local result = direct_exec({ "node", "-e", script, request.url, request.method, tostring(timeout_seconds or 10) })
  if result.exit_code ~= 0 then error(result.stderr) end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    error("canonical host JSON decoder is unavailable")
  end
  return json.decode(result.stdout)
end

return {
  project_root = project_root,
  copy = copy,
  equal = equal,
  shell_quote = shell_quote,
  read_file = read_file,
  write_file = write_file,
  direct_exec = direct_exec,
  require_exec = require_exec,
  remove_tree = remove_tree,
  prepare_supervisor_project = prepare_supervisor_project,
  absolute = absolute,
  sha256_bytes = sha256_bytes,
  reserve_port = reserve_port,
  ref = ref,
  Store = Store,
  artifact_reference = artifact_reference,
  spawn_process = spawn_process,
  wait_http = wait_http,
  http_request = http_request,
}
