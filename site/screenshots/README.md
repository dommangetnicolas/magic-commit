# Screenshots

Drop these PNGs here; the landing page picks them up automatically and shows a placeholder for any that are missing.

| File | What it shows |
| --- | --- |
| `panel.png` | The whole panel open under the menu bar. Also used as the social preview image. |
| `commit.png` | The `design-tokens` row: uncommitted changes, with WIP and Commit. |
| `wip.png` | The `aurora-web` row: changes plus WIP commits. |
| `batch-oco.png` | The `pocket-api` row: WIP commits with Batch oco and Push. |
| `push.png` | The warning shown when pushing with WIP commits. |

## Retaking them

1. `./scripts/screenshot-demo.sh setup` builds demo repos in `~/MagicCommitDemo` and points the app at them. Your own project list is backed up.
2. Open the panel, press ⌘⇧4 then Space, and click the panel. That's `panel.png`.
3. Click **Push** on `pocket-api`, press ⌘⇧4 then Space, and click the alert. That's `push.png`. Then click **Cancel**.
4. Crop the three rows out of `panel.png` for the feature cards.
5. `./scripts/screenshot-demo.sh clean` puts your project list back and deletes the demo repos.

Don't click Commit or Batch oco on the demo repos unless you want `oco` to make real API calls.
