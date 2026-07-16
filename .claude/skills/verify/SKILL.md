---
name: verify
summary: Drive the repository host supervise CLI through real startup.
---

# Verify

Use the public host CLI with isolated state and GitHub writes disabled:

```sh
RT="$(mktemp -d /tmp/fkst-verify-rt.XXXXXX)"
DUR="$(mktemp -d /tmp/fkst-verify-durable.XXXXXX)"
env -u FKST_GITHUB_WRITE scripts/run.sh host -- supervise \
  --durable-root "$DUR" \
  --runtime-root "$RT"
```

A successful launch prints `MSG=schema validation passed` and writes an `event=startup` record under `$RT/logs/`. Stop that verification process after capturing those markers.

Probe the adjacent guard by passing the same directory to `--runtime-root` and `--durable-root`; the CLI must exit nonzero with `runtime-root and --durable-root resolved to the same directory`.
