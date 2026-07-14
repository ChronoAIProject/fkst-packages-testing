local graph = require("testkit.graph")
local t = fkst.test

local platform_root = ".testing/runs/platform-final-report-acceptance"
local module_root = ".testing/runs/module-final-report-acceptance"
local module_report_path = module_root .. "/stage-report.md"
local final_report_path = platform_root .. "/final-report.md"
local publication_request_path = platform_root .. "/publication-request.json"
local receipt_path = platform_root .. "/dry-run-publication-receipt.json"

local function reset_artifacts()
  local removed = os.execute("rm -rf '" .. platform_root .. "' '" .. module_root .. "'")
  assert(removed == true or removed == 0)
end

local function write_file(path, content)
  local directory = assert(path:match("^(.*)/[^/]+$"))
  local created = os.execute("mkdir -p '" .. directory .. "'")
  assert(created == true or created == 0)
  local handle = assert(io.open(path, "w"))
  assert(handle:write(content))
  handle:close()
end

local function read_file(path)
  local handle = assert(io.open(path, "r"))
  local content = handle:read("*a")
  handle:close()
  return content
end

local function file_exists(path)
  local handle = io.open(path, "r")
  if handle == nil then return false end
  handle:close()
  return true
end

local function completion_event(satisfied)
  return {
    queue = "platform_aggregate",
    source_ref = { kind = "external", reference = "platform-final-report-acceptance" },
    payload = {
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        {
          schema = "testing-runner.result.v1",
          job = "module-test-loop",
          module = "module-a",
          status = "passed",
          artifact_root = module_root,
          source_ref = { kind = "module", ref = "module-a" },
          trace_id = "trace-platform-final-report",
          dedup_key = "module-a-final-report-run",
          exit_code = 0,
          native_summary = {
            schema = "testing-runner.module-ui-loop-summary.v1",
            module = "module-a",
            status = "passed",
            classification = "bounded-exploration-complete",
            mode = "contract-envelope",
            artifact_root = module_root,
            metadata_path = module_root .. "/metadata.json",
            stage_report_path = module_report_path,
            publication_dry_run = true,
          },
        },
      },
      artifact_root = platform_root,
      source_ref = { kind = "platform", ref = "platform-final-report-acceptance" },
      trace_id = "trace-platform-final-report",
      dedup_key = "platform-final-report-run",
      completion_barrier = {
        schema = "platform-test-loop.completion-barrier.v1",
        satisfied = satisfied,
      },
      coverage_matrix = {
        schema = "platform-test-loop.coverage-matrix.v1",
        rows = {
          {
            id = "module-a-primary-path",
            module = "module-a",
            claim = "The primary module path is covered",
            evidence_pointer = module_root .. "/evidence/primary-path.json",
          },
          {
            id = "module-a-unbacked",
            module = "module-a",
            claim = "This unbacked claim must not appear",
          },
        },
      },
      publication = { mode = "artifact-only", dry_run = true },
    },
  }
end

return {
  test_run_graph_public_completion_persists_one_dry_run_final_report_after_barrier = function()
    local module_report = "# Preserved module report\n\nModule evidence remains unchanged.\n"
    reset_artifacts()
    write_file(module_report_path, module_report)

    local waiting = graph.require_quiescent(graph.run(completion_event(false), { max_steps = 12 }))
    t.eq(graph.find_raise(waiting, "testing-runner.platform_test_request"), nil)
    t.eq(file_exists(final_report_path), false)
    t.eq(file_exists(publication_request_path), false)
    t.eq(file_exists(receipt_path), false)

    local completed = graph.require_quiescent(graph.run(completion_event(true), { max_steps = 16 }))
    graph.require_delivery(completed, {
      queue = "platform-test-loop.platform_aggregate",
      consumer = "platform-test-loop.complete",
    })
    graph.require_delivery(completed, {
      queue = "testing-runner.platform_test_request",
      consumer = "testing-runner.run_platform_loop",
    })
    graph.require_delivery(completed, {
      queue = "test-artifacts.testing_result",
      consumer = "test-artifacts.summarize",
    })
    graph.require_delivery(completed, {
      queue = "test-publication.artifact_summary",
      consumer = "test-publication.prepare_publication",
    })
    graph.require_delivery(completed, {
      queue = "test-publication.publication_request",
      consumer = "test-publication.dry_run",
    })
    graph.assert_covers(completed, {
      "testing-runner.final_report_rendered -> platform-test-loop.persist_final_report",
      "test-artifacts.artifact_summary -> platform-test-loop.publish_final_report",
    })

    local final_report = read_file(final_report_path)
    t.is_true(final_report:find("Run: platform-final-report-acceptance", 1, true) ~= nil)
    t.is_true(final_report:find("module-a: passed", 1, true) ~= nil)
    t.is_true(final_report:find(module_report_path, 1, true) ~= nil)
    t.is_true(final_report:find("The primary module path is covered", 1, true) ~= nil)
    t.eq(final_report:find("This unbacked claim must not appear", 1, true), nil)
    t.eq(read_file(module_report_path), module_report)

    local publication = graph.require_raise(completed, "test-publication.publication_request").payload
    t.eq(publication.schema, "test-publication.publication-request.v1")
    t.eq(publication.dedup_key, "platform-final-report-run")
    t.eq(publication.final_report_path, final_report_path)
    t.eq(publication.publication_mode, "artifact-only")
    t.eq(publication.publication_dry_run, true)

    local receipt = graph.require_raise(completed, "test-publication.dry_run_receipt").payload
    t.eq(receipt.schema, "test-publication.dry-run-receipt.v1")
    t.eq(receipt.publication_key, publication.dedup_key)
    t.eq(receipt.publication_request_path, publication_request_path)
    t.eq(receipt.final_report_path, final_report_path)
    t.eq(receipt.external_operation, false)

    local persisted_request = read_file(publication_request_path)
    local persisted_receipt = read_file(receipt_path)
    t.is_true(persisted_request:find('"dedup_key":"platform-final-report-run"', 1, true) ~= nil)
    t.is_true(persisted_request:find('"final_report_path":"' .. final_report_path .. '"', 1, true) ~= nil)
    t.is_true(persisted_receipt:find('"publication_request_path":"' .. publication_request_path .. '"', 1, true) ~= nil)
    t.is_true(persisted_receipt:find('"external_operation":false', 1, true) ~= nil)

    local replay = graph.require_quiescent(graph.run(completion_event(true), { max_steps = 16 }))
    local replay_publication = graph.require_raise(replay, "test-publication.publication_request").payload
    local replay_receipt = graph.require_raise(replay, "test-publication.dry_run_receipt").payload
    t.eq(replay_publication.dedup_key, publication.dedup_key)
    t.eq(replay_receipt.receipt_path, receipt.receipt_path)
    t.eq(read_file(final_report_path), final_report)
    t.eq(read_file(publication_request_path), persisted_request)
    t.eq(read_file(receipt_path), persisted_receipt)
    t.eq(read_file(module_report_path), module_report)
  end,
}
