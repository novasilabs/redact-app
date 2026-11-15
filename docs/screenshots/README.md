# Screenshots

Rendered from the app with demo data (project `acme` in `~/code/acme`, fake keys ending in `0000`). No real
secrets. Regenerate with `scripts/snapshots.sh` (both appearances) or `scripts/snapshots.sh dark`.

Main window at 1200×760 pt, captured @2x (2400×1520). Files ending in `-w1` are the sheet or panel on its own;
`-w0` is the main window behind it.

| File | Shows |
|---|---|
| `01-locked` | Locked vault, Touch ID unlock |
| `02-projects` | All projects, with the accounts each one runs as |
| `03-projects-detail` | One project: environment tabs, masked values, a linked shared key, the `redact run` strip |
| `02-keys`, `03-keys-detail` | Keys list with brand logos, key inspector |
| `02-codes`, `03-codes-detail` | Backup codes and the code grid |
| `02-identities` | Accounts: Wrangler profiles bound to folders, tokens |
| `02-health` | Leak check |
| `02-activity` | Activity: which agent ran what, with which variable names |
| `02-backup` | Backup & restore: export all or a selection |
| `04-import-sheet-w1` | Importing a folder's `.env` files |
| `05-paste-sheet-w1` | Paste anything: key format detected |
| `06-approval-panel-w1` | An AI agent asks for production secrets; Touch ID approval |
| `07-quick-find-w1` | Quick find (⌥⌘K) |
| `08-restore-sheet-w1` | Restoring a `.redact` backup with the Recovery Key |
