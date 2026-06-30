# fkst-packages-testing

`fkst-packages-testing` 是 **fkst** 生态的测试 / QA 领域 package 仓库。

本仓有意独立于 [`fkst-packages`](https://github.com/ChronoAIProject/fkst-packages)。它负责 testing / QA 领域边界：测试 runner 编排、浏览器 readiness、测试 artifact contract、发布 handoff、模块/平台测试 loop 生命周期，以及在线回归入口。

初始 runtime adapter 会调用现有 [`ChronoAIProject/agentic-testing`](https://github.com/ChronoAIProject/agentic-testing) Python CLI，并消费它的 `.testing` artifact contract。package 结构按长期 fkst-native testing 领域设计，因此后续可以逐步替换 adapter 实现而不改变 queue contract。

本仓不包含 engine Rust，也不保存 host 应用状态。

## Package 目录

| Package | 形态 | 作用 | 状态 |
| --- | --- | --- | --- |
| `testing-runner` | flat adapter | 通过初始 `agentic-testing-cli` adapter 运行测试任务，并输出标准 testing result payload。 | seed |
| `browser-readiness` | flat adapter | 定义本地 browser E2E session 的 browser-harness/CDP readiness contract。 | skeleton |
| `test-artifacts` | flat library package | 定义标准 `.testing` artifact summary contract。 | skeleton |
| `test-publication` | flat adapter | 将 testing publication handoff artifacts 转换为 publication requests，后续用于组合 `github-proxy`。 | skeleton |
| `module-test-loop` | composed lifecycle | 模块级测试生命周期编排；初始委托给 `testing-runner`。 | skeleton |
| `platform-test-loop` | composed lifecycle | 平台级多模块测试生命周期编排；初始委托给 `module-test-loop` / `testing-runner`。 | skeleton |
| `online-regression` | flat adapter | 在线回归 / heartbeat 入口；初始委托给 `testing-runner`。 | skeleton |
| `ornn-testing-profile` | profile package | Ornn 专用 testing profile 和本地安全默认值。 | skeleton |

## 运行

```sh
cp env.example .env
$EDITOR .env
scripts/run.sh check
scripts/run.sh test
```

测试 package 默认 dry-run。fkst event 不应保存凭证、cookie、token、浏览器 storage、测试账号密码或大体积报告正文；payload 只携带小控制字段和稳定 artifact 指针。

⟦AI:FKST⟧
