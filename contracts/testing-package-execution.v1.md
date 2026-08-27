# Testing Package Execution v1

The admitted Browser-title walking skeleton follows a durable idempotency journal:

1. Recompute the admitted invocation digest using the pure `sha256` dependency.
2. Look up completion by `dedup_key` and `admission_digest`.
3. Claim the execution and load the closed intent/receipt state for the effect identity.
4. For absent state, check freshness and persist `effect-intent`, including `started_at`, before the Browser effect.
5. Validate the raw `testing-package-executor.browser-read-title-receipt.v1`, then construct and persist a distinct closed `testing-package-executor.effect-receipt.v1` carrying `completed_at` before deriving canonical facts.
6. Resume from a stored intent and receipt without repeating the Browser effect, or terminalize an intent without a receipt as `lost` without retrying an uncertain effect.
7. Persist `testing-evidence-manifest.v1` before `testing-case-result-set.v2`.
8. Atomically persist `testing-package-executor.completed-execution.v1` and replay that receipt without repeating effects.

The semantic executor receives only `load_completed_execution`, `claim_execution`, `load_effect_intent`,
`load_effect_receipt`, `check_freshness`,
`persist_effect_intent`, `browser_read_title`, `persist_effect_receipt`, `write_canonical`,
`complete_execution`, `now`, and `sha256`. Runtime and Host adapters own durable journals,
Browser resources, persisted bytes, byte-size measurement, and persisted-byte digest verification.

Execution identity is the pair `dedup_key` plus `admission_digest`; `trace_id` is correlation only.
All lifecycle objects are closed, all identity strings are bounded, and all digests are lowercase SHA-256.
