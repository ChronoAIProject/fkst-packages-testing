'use strict';

const fs = require('fs');
const path = require('path');
const { runMeasuredCommand } = require('./measured-command');
const { directoryBytes, processGroupUsage } = require('./platform');

function createBudgetRuntime(deps) {
  const {
    acquireLock,
    durableRoot,
    ledgerPath,
    readIfExists,
    writeJsonAtomic,
  } = deps;

  function resourceBudgets(payload) {
    const value = payload && payload.resource_budgets;
    const fields = ['cpu_millis', 'memory_mb', 'disk_mb', 'processes', 'network_requests', 'output_bytes'];
    if (!value || fields.some((field) => !Number.isInteger(Number(value[field])) || Number(value[field]) < 0)) {
      throw new Error('resource budgets are invalid');
    }
    return Object.fromEntries(fields.map((field) => [field, Number(value[field])]));
  }

  function usagePath(operationId) {
    return ledgerPath('usage', operationId);
  }

  function usageRecord(operationId) {
    const existing = readIfExists(usagePath(operationId));
    if (!existing) {
      return {
        schema: 'environment-factory.resource-usage.v1',
        operation_id: operationId,
        cpu_millis: 0,
        network_requests: 0,
      };
    }
    if (existing.schema !== 'environment-factory.resource-usage.v1' || existing.operation_id !== operationId
      || !Number.isInteger(existing.cpu_millis) || !Number.isInteger(existing.network_requests)) {
      throw new Error('resource usage ledger is malformed');
    }
    return existing;
  }

  function updateUsage(operationId, update) {
    const filePath = usagePath(operationId);
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    const release = acquireLock(`${filePath}.lock`);
    try {
      const next = update({ ...usageRecord(operationId) });
      writeJsonAtomic(filePath, next);
      return next;
    } finally {
      release();
    }
  }

  function consumeNetworkRequest(payload) {
    const budgets = resourceBudgets(payload);
    let accepted = false;
    const usage = updateUsage(payload.operation_id, (current) => {
      if (current.network_requests < budgets.network_requests) {
        current.network_requests += 1;
        accepted = true;
      }
      return current;
    });
    return { accepted, used: usage.network_requests, limit: budgets.network_requests };
  }

  function activeProcessResources(operationId) {
    const directory = path.join(durableRoot(), 'environment-factory', 'resources');
    let names = [];
    try { names = fs.readdirSync(directory); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    return names.map((name) => readIfExists(path.join(directory, name)))
      .filter((resource) => resource && resource.kind === 'process' && resource.operation_id === operationId
        && !resource.cleaned && Number.isInteger(resource.pid));
  }

  function enforceCurrentBudgets(payload, workspacePath) {
    const budgets = resourceBudgets(payload);
    const resources = activeProcessResources(payload.operation_id);
    const processUsage = processGroupUsage(resources.map((resource) => resource.pid));
    const diskUsage = directoryBytes(workspacePath);
    if (!processUsage.supported || !diskUsage.supported) {
      return { passed: false, reason: 'resource-measurement-unavailable' };
    }
    const usage = usageRecord(payload.operation_id);
    const values = {
      cpu_millis: usage.cpu_millis + processUsage.cpuMillis,
      memory_bytes: processUsage.rssBytes,
      disk_bytes: diskUsage.bytes,
      processes: processUsage.processes,
    };
    if (values.cpu_millis > budgets.cpu_millis) return { passed: false, reason: 'cpu-budget-exceeded', values };
    if (values.memory_bytes > budgets.memory_mb * 1024 * 1024) return { passed: false, reason: 'memory-budget-exceeded', values };
    if (values.disk_bytes > budgets.disk_mb * 1024 * 1024) return { passed: false, reason: 'disk-budget-exceeded', values };
    if (values.processes > budgets.processes) return { passed: false, reason: 'process-budget-exceeded', values };
    return { passed: true, values };
  }

  async function executeBudgetedCommand(payload, argv, options) {
    const budgets = resourceBudgets(payload);
    const before = enforceCurrentBudgets(payload, options.workspacePath);
    if (!before.passed) return { reason: before.reason, exitCode: -1 };
    const result = await runMeasuredCommand(argv, {
      cwd: options.cwd,
      env: options.env,
      timeoutMs: options.timeoutMs,
      outputBytes: payload.output_bytes,
    });
    let reason = null;
    if (!result.metricsSupported || !result.processMetricsSupported) reason = 'resource-measurement-unavailable';
    else if (result.cpuMillis > budgets.cpu_millis) reason = 'cpu-budget-exceeded';
    else if (before.values.memory_bytes + result.maxRssBytes > budgets.memory_mb * 1024 * 1024) {
      reason = 'memory-budget-exceeded';
    } else if (before.values.processes + result.maxProcesses > budgets.processes) {
      reason = 'process-budget-exceeded';
    }
    if (result.metricsSupported) {
      const usage = updateUsage(payload.operation_id, (current) => {
        current.cpu_millis += result.cpuMillis;
        return current;
      });
      if (usage.cpu_millis > budgets.cpu_millis) reason = reason || 'cpu-budget-exceeded';
    }
    const after = enforceCurrentBudgets(payload, options.workspacePath);
    if (!after.passed) reason = reason || after.reason;
    if (result.timedOut) reason = reason || 'command-timeout';
    if (result.outputExceeded) reason = reason || 'output-budget-exceeded';
    if (result.exitCode !== 0) reason = reason || 'command-failed';
    return { ...result, reason };
  }

  return {
    consumeNetworkRequest,
    enforceCurrentBudgets,
    executeBudgetedCommand,
    resourceBudgets,
    usageRecord,
  };
}

module.exports = { createBudgetRuntime };
