# fkst-packages-testing

`fkst-packages-testing` 是 **fkst** 生态的测试 / QA 领域 package 仓库。

本仓有意独立于 [`fkst-packages`](https://github.com/ChronoAIProject/fkst-packages)。它负责 testing / QA 领域边界：测试 runner 编排、浏览器 readiness、测试 artifact contract、发布 handoff、模块/平台测试 loop 生命周期，以及在线回归入口。

runtime adapter 默认走 `fkst-native`。旧 `agentic-testing` Python CLI 和 host wrapper 不再是可执行 backend；legacy 请求会返回 `blocked`，不会静默 fallback。

本仓不包含 engine Rust，也不保存 host 应用状态。

## Package 目录

| Package | 形态 | 作用 | 状态 |
| --- | --- | --- | --- |
| `testing-runner` | flat adapter | 通过 FKST-native runtime boundary 运行普通测试任务和 approval-bound 的结构化 API/CLI 计划，并输出标准 testing result payload；legacy `agentic-testing` 请求会被 blocked。 | migrating |
| `browser-readiness` | flat adapter | 检查本地 browser-harness/CDP/base URL readiness，并可透传 bounded execution context。 | migrating |
| `test-artifacts` | flat library package | 定义标准 `.testing` artifact summary contract。 | skeleton |
| `test-publication` | durable adapter | 将 testing handoff 转换为 pointer-only publication request，把已验证的产品缺陷发布为幂等 development Issue，并通过 host-routed `github-proxy` seam 提供 replay-safe QA checkpoint、immutable GitHub artifact receipt 和对账后的 aggregate report。 | migrating |
| `testing-pipeline` | composed lifecycle | 组合 module loop、runner、artifact summary 和 publication handoff，用于 graph-level testing flows。 | skeleton |
| `testing-discovery` | composed lifecycle | 将本地 app scope 的 bounded observations 转成 FKST-native module starts，不需要手写产品 module catalog。 | experimental |
| `module-test-loop` | composed lifecycle | 模块级测试生命周期编排，并委托 `testing-runner` 执行 runner path。 | migrating |
| `platform-test-loop` | composed lifecycle | 平台级多模块测试生命周期编排；初始委托给 `module-test-loop` / `testing-runner`。 | skeleton |
| `online-regression` | flat adapter | 在线回归 / heartbeat 入口，已具备第一条 native no-browser heartbeat path。 | migrating |

## 下游使用方式

Host 仓负责组合这些 packages，并提供自己的应用默认值。本仓不应编码产品模块名、固定 base URL、浏览器角色或环境变量名。

典型 host flow：

1. 产生 `browser-readiness.check.v1` 请求，包含 host 提供的 sessions、本地 base URL，以及可选的 bounded `request_context`。
2. 将 `browser-readiness.result.v1` 传给 `module-test-loop.start.v1`。
3. 由 `module-test-loop` 发出 `testing-runner.module-test-loop.request.v1`。
4. 由 `testing-runner` 执行；省略 `backend` 时默认解析为唯一可执行 backend `fkst-native`。

产品特定 profile 应放在 downstream host 仓。本仓只提供可复用的 testing/QA building blocks 和中性 contract。

对于 sandbox 托管的 QA，`examples/opensandbox-host/` 提供 provider-specific downstream adapter：绑定固定 OpenSandbox image/snapshot、获批 capability 指针、受限资源和网络策略、单一幂等 sandbox receipt、artifact 哈希/发布及 teardown。OpenSandbox 细节仍位于可复用 packages 之外，也不会改变 `environment-factory.v1`。

对于无人手写 module catalog 的覆盖，host 可以提交 `testing-discovery.app-scope.v1`，只包含本地 scope、sessions、安全策略，以及 bounded AI/browser/navigation/accessibility observations。`testing-discovery` 会自动推导 module starts，把 sanitized discovery plan 写到 `.testing/runs/...`，并复用现有 `browser-readiness` -> `testing-pipeline` -> `module-test-loop` -> `testing-runner` -> artifact/publication 路径。host 只提供 bootstrap scope 和 safety policy；产品模块目录不属于本 package set。

对于 headless API/CLI 计划，host 使用 `contracts/structured-execution.v1.md` 定义的
`testing-runner.structured-execution.request.v1` pointer-only seam。独立、已认证、单次使用的 approval
把精确 plan digest 绑定到正向 argv 与 HTTP capability；runner 只有在 point-of-use 验证和原子 replay
claim 后才执行 direct argv/HTTP effect，并继续复用现有 artifact/publication packages。

GitHub 可见的 durable QA 报告使用 `contracts/qa-publication.v1.md` 中的 checkpoint 与 finalize
seam。`test-publication` 维护 compare-and-swap run ledger，通过 host capability 发布 immutable
artifact receipt，对 terminal case results 和 cleanup receipt 做对账，并输出 bounded
`github-proxy.v1` comment intent。GitHub credential 和命令不会进入 testing package。

结构化执行中已验证的产品缺陷使用 `contracts/defect-publication.v1.md` 定义的 pointer-only
request、issue-draft artifact、GitHub Issue intent、acknowledgement 和逐 case receipt 协议。只有
`product-defect` 会发出 Issue intent；环境、fixture、harness、passed 和 not-executed 结果只进入
summary。Host 负责把出站 Issue seam 和 durable issue-written acknowledgement 映射到固定版本的
`github-proxy` package。

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

可执行 native path 有意保持很窄：module UI-loop request 使用 bounded `ui_loop`、`module_discovery` 和 `cdp_execution` facts；module no-browser request 只有在 `dry_run = false`、`no_browser = true` 且提供 bounded `native_argv` 时才执行；module browser request 只有在 `dry_run = false`、提供 `e2e_driver` 和 bounded `native_argv` 时才执行。缺少 module `native_argv` 返回 `planned`；`native_argv` 指向 legacy `agentic-testing` CLI 或 host wrapper 返回 `blocked`；`agentic_testing_repo_root` 不再是 active field。online regression 只在提供 `heartbeat_url` 时支持 native no-browser HTTP heartbeat。其他 unsupported native live path 返回 `blocked`，不得 fallback 到 legacy code。

### 下游最小消费协议

Publisher 应消费 `test-publication.publication-request.v1`；aggregator 可消费 `test-artifacts.summary.v1`。通用最小 consumer 只需要 `schema`、`status`、`job`、`artifact_root`、`metadata_path`、`source_ref`、`trace_id` 和 `dedup_key`。`native_summary` 只是可选诊断信息，generic consumer 不应依赖它。下游 / 产品特定 profile、module set、browser role、URL、环境变量名和发布策略都属于 host 仓。

`trace_id` 用于串起一次逻辑测试 flow。下游 publisher 应将 `(publication_kind, channel, dedup_key)` 作为幂等 key；重放同一个 artifact summary 必须产生同一个 publication request。

## 运行

```sh
cp env.example .env
$EDITOR .env
scripts/run.sh check
scripts/run.sh test
scripts/run.sh ai-pipeline-smoke
```

`scripts/run.sh test` 会在全仓测试时写出标准 Lua coverage artifact：
`.fkst/run/lua-coverage/coverage.json`，并执行 `migration/coverage-uncovered.allowlist` 的
shrink-only ratchet。`scripts/run.sh ai-pipeline-smoke` 是 hermetic smoke，用来验证 AI 自动生成
测试用例、consensus review、pointer-only resume、CDP execution handoff 和 publication handoff。
CI 会在 run 结束时上传标准 coverage artifact 和 `.testing/runs/**` smoke artifact，包括失败 run。

如果要验证真实本地浏览器 runtime path，先启动本地 app 和带 remote debugging 的 Chrome/Chromium，
然后运行：

```sh
FKST_LIVE_BASE_URL=http://127.0.0.1:8317 \
FKST_LIVE_CDP_URL=http://127.0.0.1:9222 \
scripts/run.sh live-cdp-smoke
```

另有手动触发的 `live-cdp-smoke` GitHub Actions workflow，会在 runner 上启动 loopback fixture app
和 Chrome CDP，并上传 `.testing/runs/**` artifact。

测试 package 默认 dry-run。fkst event 不应保存凭证、cookie、token、浏览器 storage、测试账号密码或大体积报告正文；payload 只携带小控制字段和稳定 artifact 指针。

⟦AI:FKST⟧
