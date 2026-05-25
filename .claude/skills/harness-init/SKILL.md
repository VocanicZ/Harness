---
name: harness-init
description: First-time Harness setup — run the wizard that writes .harness/config and seeds GitHub labels. Trigger on /harness-init or "set up the harness config".
---

# /harness-init — run the Harness setup wizard

Thin wrapper around `.harness/bin/harness init`. Don't hand-write config; let the wizard do it.

**This writes `.harness/config` and may create GitHub labels — confirm before running.**

The wizard is interactive (mode, topology, owner/repo, labels, pool size). The Bash tool has no
TTY, so prefer one of:

1. **Interactive (best):** tell the user to run it in their session:
   `! .harness/bin/harness init`
2. **Non-interactive:** if the user already gave you the values, run with env vars set, e.g.
   `HARNESS_MODE=prd HARNESS_OWNER=acme HARNESS_REPO=acme/widget .harness/bin/harness init`
   (unset vars take defaults; see `.harness/init.sh`).

After it writes config, next step is `/harness-start`. For full setup+operate guidance use `/harness`.
