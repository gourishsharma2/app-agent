---
description: List all available flows (screen docs under flow/ and end-to-end docs under tests/), sorted alphabetically, as a markdown table.
---

# List available flows

Discover every flow doc in this repo and display them in a markdown table.

## Steps

1. Glob for flow docs:
   - `flow/*.md`
   - `tests/**/*.md` (files directly under `tests/` and any `tests/<category>/*.md`)
2. For each file found, derive:
   - **Name** — the filename without the `.md` extension (e.g. `flow/loginFlow.md` → `loginFlow`, `tests/VerifyGpsListing.md` → `VerifyGpsListing`).
   - **Description** — the intro prose under the file's `# <Title>` heading (the text before the first `## Step`/`## ` section), collapsed to one concise line.
3. Sort the resulting list alphabetically by Name (case-insensitive).
4. Render as a markdown table:

   | Name | Description |
   |------|-------------|
   | `<flow_name>` | `<flow_description>` |

5. If no `.md` files are found under `flow/` or `tests/`, output exactly:

   ```
   No flows found.
   ```

Always discover flows directly from the filesystem — don't treat `summary/flows-summary.md` as the source of truth, since it's hand-maintained and can go stale.
