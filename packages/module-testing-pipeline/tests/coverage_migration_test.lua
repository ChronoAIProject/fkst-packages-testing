local dead_letter = require("departments.dead_letter.main")
local keepalive = require("raisers.keepalive")
local t = fkst.test

return {
  test_static_department_and_raiser_contracts_are_loaded = function()
    t.eq(type(dead_letter), "table")
    t.eq(keepalive.type, "cron")
    t.eq(keepalive.interval, "5m")
    t.eq(keepalive.produces, "pipeline_keepalive_tick")
  end,
}
