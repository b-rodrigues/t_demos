# remote_builders_t

This demo exercises `nix_options.builders` by offloading a pipeline node to a
mock localhost SSH builder.

## Run

Set `TLANG_REMOTE_BUILDERS` to a valid Nix remote builder specification to
exercise remote offloading explicitly:

```bash
TLANG_REMOTE_BUILDERS="ssh://gha-builder x86_64-linux - 1 1 - -" t run src/pipeline.t
```

If `TLANG_REMOTE_BUILDERS` is unset, the script still runs and falls back to a
local build.
