local support = require("host_canonical_workflow_qa_support")
local process = require("test_support.durable_workflow_qa_process")
local t = fkst.test

local INITIAL = "{\"sku\":\"SKU-001\",\"on_hand\":5,\"reserved\":0,\"available\":5}\n"
local RESERVED = "{\"sku\":\"SKU-001\",\"on_hand\":5,\"reserved\":3,\"available\":2}\n"

local function run(root, argv)
  local command = { "node", "cli.js" }
  for _, value in ipairs(argv) do table.insert(command, value) end
  return support.direct_exec(command, root)
end

local function copy_fixture(root)
  local parent = assert(root:match("^(.*)/[^/]+$")) .. "/"
  support.remove_tree(root, parent)
  support.require_exec({
    "node", "-e",
    "require('fs').cpSync(process.argv[1],process.argv[2],{recursive:true})",
    support.absolute("examples/generic-host/fixtures/downstream-inventory"), root,
  })
end

local function remove_fixture(root)
  support.remove_tree(root, assert(root:match("^(.*)/[^/]+$")) .. "/")
end

return {
  test_inventory_cli_is_atomic_deterministic_and_fail_closed = function()
    local root = os.tmpname() .. "-downstream-inventory-cli"
    copy_fixture(root)
    local ok, err = pcall(function()
      local missing_preparation = run(root, { "reserve", "SKU-001", "3" })
      t.eq(missing_preparation.exit_code, 2)
      t.eq(missing_preparation.stdout, "")
      t.eq(missing_preparation.stderr, "{\"error\":\"fixture-not-prepared\"}\n")

      support.require_exec({ "node", "build.js" }, root)
      local state_path = root .. "/state/inventory.json"
      t.eq(support.read_file(state_path), INITIAL)
      local malformed = run(root, { "reserve", "SKU-001", "0" })
      t.eq(malformed.exit_code, 2)
      t.eq(malformed.stderr, "{\"error\":\"invalid-quantity\"}\n")
      t.eq(support.read_file(state_path), INITIAL)
      local unknown = run(root, { "reserve", "UNKNOWN", "3" })
      t.eq(unknown.exit_code, 3)
      t.eq(unknown.stderr, "{\"error\":\"unknown-sku\",\"sku\":\"UNKNOWN\"}\n")
      t.eq(support.read_file(state_path), INITIAL)

      local success = run(root, { "reserve", "SKU-001", "3" })
      t.eq(success.exit_code, 0)
      t.eq(success.stdout, RESERVED)
      t.eq(success.stderr, "")
      t.eq(support.read_file(state_path), RESERVED)
      local rejected = run(root, { "reserve", "SKU-001", "3" })
      t.eq(rejected.exit_code, 4)
      t.eq(rejected.stdout, "")
      t.eq(rejected.stderr,
        "{\"error\":\"insufficient-available\",\"sku\":\"SKU-001\",\"requested\":3,\"available\":2}\n")
      t.eq(support.read_file(state_path), RESERVED)
      local leftovers = support.require_exec({
        "node", "-e",
        "const fs=require('fs');process.stdout.write(fs.readdirSync('state').filter(n=>n.includes('.tmp-')).join(','))",
      }, root)
      t.eq(leftovers, "")

      support.write_file(state_path, "not-json\n")
      local malformed_state = run(root, { "reserve", "SKU-001", "1" })
      t.eq(malformed_state.exit_code, 2)
      t.eq(malformed_state.stderr, "{\"error\":\"inventory-state-unavailable\"}\n")
      t.eq(support.read_file(state_path), "not-json\n")
      support.write_file(state_path, "{\"sku\":\"SKU-001\",\"on_hand\":5,\"reserved\":4,\"available\":2}\n")
      local invalid_state = run(root, { "reserve", "SKU-001", "1" })
      t.eq(invalid_state.exit_code, 2)
      t.eq(invalid_state.stderr, "{\"error\":\"inventory-state-malformed\"}\n")
      t.eq(support.read_file(state_path),
        "{\"sku\":\"SKU-001\",\"on_hand\":5,\"reserved\":4,\"available\":2}\n")
      os.remove(state_path)
      local missing_state = run(root, { "reserve", "SKU-001", "1" })
      t.eq(missing_state.exit_code, 2)
      t.eq(missing_state.stderr, "{\"error\":\"inventory-state-unavailable\"}\n")
      t.eq(support.read_file(state_path), nil)
    end)
    remove_fixture(root)
    if not ok then error(err, 0) end
  end,

  test_inventory_server_rejects_unknown_routes_without_mutation = function()
    local root = os.tmpname() .. "-downstream-inventory-server"
    copy_fixture(root)
    local pid
    local ok, err = pcall(function()
      support.require_exec({ "node", "build.js" }, root)
      local port = support.reserve_port()
      pid = support.spawn_process({ "node", "server.js", tostring(port) }, root, root .. "/host")
      t.is_true(support.wait_http("http://127.0.0.1:" .. tostring(port) .. "/inventory/SKU-001", 10))
      local state_path = root .. "/state/inventory.json"
      local before = support.read_file(state_path)
      for _, request in ipairs({
        { method = "POST", path = "/inventory/SKU-001" },
        { method = "GET", path = "/inventory/UNKNOWN" },
        { method = "GET", path = "/unknown" },
      }) do
        local response = support.http_request({
          method = request.method, url = "http://127.0.0.1:" .. tostring(port) .. request.path,
        }, 10)
        t.eq(response.status, 404)
        t.eq(response.headers["content-type"], "application/json")
        t.eq(response.body, "{\"error\":\"not-found\"}\n")
        t.eq(support.read_file(state_path), before)
      end
    end)
    if pid ~= nil then pcall(process.stop_supervisor, pid) end
    remove_fixture(root)
    if not ok then error(err, 0) end
  end,
}
