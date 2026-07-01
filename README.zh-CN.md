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

## 运行

```sh
cp env.example .env
$EDITOR .env
scripts/run.sh check
scripts/run.sh test
```

测试 package 默认 dry-run。fkst event 不应保存凭证、cookie、token、浏览器 storage、测试账号密码或大体积报告正文；payload 只携带小控制字段和稳定 artifact 指针。

⟦AI:FKST⟧
