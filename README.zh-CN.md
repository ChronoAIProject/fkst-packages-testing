# fkst-packages-testing

`fkst-packages-testing` 是 **fkst** 生态的测试 / QA 领域 package 仓库。

本仓有意独立于 [`fkst-packages`](https://github.com/ChronoAIProject/fkst-packages)。它负责 testing / QA 领域边界：测试 runner 编排、浏览器 readiness、测试 artifact contract、发布 handoff、模块/平台测试 loop 生命周期，以及在线回归入口。

runtime adapter 现在同时包含显式 `fkst-native` backend 和 legacy [`ChronoAIProject/agentic-testing`](https://github.com/ChronoAIProject/agentic-testing) Python CLI 兼容 backend。native 覆盖会在不改变 queue contract 的前提下逐步扩展；尚未支持的 native live path 会返回 `blocked`，不会静默 fallback 到 legacy CLI。

本仓不包含 engine Rust，也不保存 host 应用状态。

## Package 目录

| Package | 形态 | 作用 | 状态 |
| --- | --- | --- | --- |
| `testing-runner` | flat adapter | 通过 `fkst-native` 或 legacy `agentic-testing-cli` backend 运行测试任务，并输出标准 testing result payload。 | migrating |
| `browser-readiness` | flat adapter | 检查本地 browser-harness/CDP/base URL readiness，并可透传 bounded execution context。 | migrating |
| `test-artifacts` | flat library package | 定义标准 `.testing` artifact summary contract。 | skeleton |
| `test-publication` | flat adapter | 将 testing publication handoff artifacts 转换为 publication requests，后续用于组合 `github-proxy`。 | skeleton |
| `testing-pipeline` | composed lifecycle | 组合 module loop、runner、artifact summary 和 publication handoff，用于 graph-level testing flows。 | skeleton |
| `module-test-loop` | composed lifecycle | 模块级测试生命周期编排，并委托 `testing-runner` 执行 runner path。 | migrating |
| `platform-test-loop` | composed lifecycle | 平台级多模块测试生命周期编排；初始委托给 `module-test-loop` / `testing-runner`。 | skeleton |
| `online-regression` | flat adapter | 在线回归 / heartbeat 入口，已具备第一条 native no-browser heartbeat path。 | migrating |

## 下游使用方式

Host 仓负责组合这些 packages，并提供自己的应用默认值。本仓不应编码产品模块名、固定 base URL、浏览器角色或环境变量名。

典型 host flow：

1. 产生 `browser-readiness.check.v1` 请求，包含 host 提供的 sessions、本地 base URL，以及可选的 bounded `request_context`。
2. 将 `browser-readiness.result.v1` 传给 `module-test-loop.start.v1`。
3. 由 `module-test-loop` 发出 `testing-runner.module-test-loop.request.v1`。
4. 由 `testing-runner` 通过 `backend = "fkst-native"` 或 legacy `agentic-testing-cli` backend 执行。

产品特定 profile 应放在 downstream host 仓。本仓只提供可复用的 testing/QA building blocks 和中性 contract。

### 下游 generic 接入示例

Host 仓可以把应用特定选择留在自己仓内，只向本 package set 提交 bounded control metadata：

```lua
-- 1. Host 提供 readiness gate。
{
  schema = "browser-readiness.check.v1",
  base_url = host_base_url,
  sessions = host_browser_sessions,
  request_context = {
    no_browser = true,
    dry_run = false,
    native_argv = host_module_check_argv,
  },
}

-- 2. 将 ready result 转成 generic pipeline start event。
{
  schema = "testing-pipeline.module-start.v1",
  module = host_module_name,
  backend = "fkst-native",
  preflight_result = readiness_result,
  artifact_root = ".testing/runs/" .. host_run_key,
  source_ref = { kind = "host-module", ref = host_module_name },
  trace_id = host_trace_id,
  dedup_key = host_run_key,
}

-- 3. Generic consumer 读取最终 handoff event。
-- queue: test-publication.publication_request
-- payload schema: test-publication.publication-request.v1
```

多模块 flow 中，host 可以把 module result 指针传给 `platform-test-loop.aggregate.v1`；aggregate 会保留每个 module 的 status/pointer，并生成 `planned`、`passed`、`failed`、`blocked` 或 `mixed` 平台级 status。

### no-browser native 约束

第一批可执行 native path 有意保持很窄：module no-browser request 只有在 `backend = "fkst-native"`、`dry_run = false`、`no_browser = true` 且提供 bounded `native_argv` 时才执行；module browser request 只有在 `backend = "fkst-native"`、`dry_run = false`、提供 `e2e_driver` 和 bounded `native_argv` 时才执行。缺少 module `native_argv` 返回 `planned`；`native_argv` 指向 `agentic_testing.cli` 返回 `blocked`；`agentic_testing_repo_root` 会被 `fkst-native` 忽略。online regression 只在提供 `heartbeat_url` 时支持 native no-browser HTTP heartbeat。其他 unsupported native live path 返回 `blocked`，不得 fallback 到 legacy CLI。

### 下游最小消费协议

Publisher 应消费 `test-publication.publication-request.v1`；aggregator 可消费 `test-artifacts.summary.v1`。通用最小 consumer 只需要 `schema`、`status`、`job`、`artifact_root`、`metadata_path`、`source_ref`、`trace_id` 和 `dedup_key`。`native_summary` 只是可选诊断信息，generic consumer 不应依赖它。下游 / 产品特定 profile、module set、browser role、URL、环境变量名和发布策略都属于 host 仓。

`trace_id` 用于串起一次逻辑测试 flow。下游 publisher 应将 `(publication_kind, channel, dedup_key)` 作为幂等 key；重放同一个 artifact summary 必须产生同一个 publication request。

## 运行

```sh
cp env.example .env
$EDITOR .env
scripts/run.sh check
scripts/run.sh test
```

测试 package 默认 dry-run。fkst event 不应保存凭证、cookie、token、浏览器 storage、测试账号密码或大体积报告正文；payload 只携带小控制字段和稳定 artifact 指针。

⟦AI:FKST⟧
