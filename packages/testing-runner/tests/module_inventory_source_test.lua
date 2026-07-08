local inventory = require("module_inventory")
local t = fkst.test

local function request(source)
  return {
    schema = "testing-runner.module-discovery.v1",
    observations = {
      {
        id = source .. "-panel",
        name = source .. " panel",
        entry_url = "http://localhost:8080/app/" .. source .. "?private=yes#state",
        visible_label = source .. " panel",
        discovery_source = source,
        confidence = "high",
        evidence_pointer = ".testing/runs/evidence/" .. source,
      },
    },
  }
end

local function ui_loop()
  return {
    base_url = "http://localhost:8080/app",
    allowed_origins = { "http://localhost:8080" },
    mutation_policy = "read-only",
  }
end

return {
  test_browser_and_browser_visible_sources_are_accepted = function()
    for _, source in ipairs({ "browser", "browser-visible" }) do
      local result = inventory.inventory(request(source), ui_loop(), ".testing/runs/" .. source, {
        readiness = { status = "ready" },
      })
      t.eq(result.discovery_status, "complete")
      t.eq(result.module_count, 1)
      t.eq(result.modules[1].discovery_source, source)
      t.eq(result.modules[1].entry_url, "http://localhost:8080/app/" .. source)
    end
  end,
}
