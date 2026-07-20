local department = require("departments.start.main")
local t = fkst.test

return {
  test_start_department_declares_own_public_seam_and_namespaced_dependencies = function()
    t.eq(department.spec.consumes[1], "qa_run_request")
    t.eq(department.spec.published_seam[1], "qa_run_request")
    t.eq(department.spec.produces[1], "test-publication.qa_checkpoint_request")
    t.eq(department.spec.produces[2], "environment-factory.environment_start")
  end,
}
