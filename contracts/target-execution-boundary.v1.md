# Target Execution Boundary v1

`testing-host.target-execution-boundary.v1` is a Host-owned admission contract for every command or
HTTP effect that can reach a target repository or its running application. It is not emitted by the
target repository, the implementation worker, PQL, or a run-scoped artifact producer.

The current package accepts exactly one mode:

```json
{
  "schema": "testing-host.target-execution-boundary.v1",
  "mode": "trusted-fixture-exact",
  "target_class": "host-owned-exact-trusted-fixture",
  "repository": {
    "url": "https://example.invalid/testing/fixture.git",
    "commit_sha": "0123456789012345678901234567890123456789"
  },
  "authority": {
    "kind": "host-policy",
    "ref": "fixtures/reviewed-fixture-boundary"
  },
  "policy_revision": "reviewed-fixture-policy-v1",
  "human_approval_required": false,
  "authorization_capability": false,
  "execution_authorized": false,
  "promotion_authorized": false
}
```

The repository URL must be canonical, credential-free HTTPS and the commit must be a full lowercase
40-character SHA. The Host runtime config must live under `.testing/host/**`, while the operation
artifact root must live under `.testing/runs/**`; the two namespaces cannot overlap. Environment
Factory validates the boundary before checkout, target commands, readiness, and target cleanup.
Structured Execution independently validates it before issuing a CLI effect receipt, consuming that
receipt, or sending a target HTTP request. The Generic Host persists the same exact binding in its
durable Host config.

`trusted-fixture-exact` means that the Host operator has reviewed and admitted that exact immutable
fixture. It must not be inferred from repository contents, a PQL compatibility result, an asset
admission, an execution preauthorization, or a Grant. A URL or commit mismatch fails closed with
`HOST_RUNTIME_ISOLATION_REQUIRED`.

No other execution-boundary mode is currently accepted. In particular, a boolean such as
`isolated=true` is not evidence of isolation. A future untrusted-repository mode requires a separate,
verifiable Host-owned receipt from an OS identity, container, VM, or equivalent filesystem boundary
that prevents target code from reading or replacing Host credentials.

The private HOME lease, disabled Git credential helpers/hooks/fsmonitor, and removed GitHub and SSH
environment variables are defense-in-depth controls for an admitted fixture. They are not an
operating-system sandbox and do not make arbitrary code under the Host UID safe.

The trusted Host may set `FKST_WORKER_RUNTIME_ROOT` to keep worker HOME allocation separate from the
FKST framework's own `FKST_RUNTIME_ROOT`. The worker root must be a Host-owned, non-symlink private
directory with no group or other permission bits. Existing Hosts that omit it use `FKST_RUNTIME_ROOT`
for compatibility, but the same private-directory checks still apply and fail closed. Neither root,
the object-bound allocation/cleanup broker paths, nor their digests are inherited by target workers.
