# Redact

A native Mac vault for developer secrets. Keys live encrypted on your Mac (Secure Enclave + Touch ID), projects get their variables at run time instead of from `.env` files, AI agents can use keys without seeing them, and each folder knows which Cloudflare account it deploys to.

Status: **M1 in progress** (see [PRD.md](PRD.md) and [spikes/FINDINGS.md](spikes/FINDINGS.md)). MIT licensed.

## Build

Requires macOS 14+, Apple silicon, Xcode 16 / Swift 6.

```sh
scripts/build-app.sh          # → build/Redact.app (ad-hoc signed), CLI at build/Redact.app/Contents/Resources/bin/redact
swift test                    # core tests
```

Install for your user (copies the app to `~/Applications`, links `redact` into `~/.local/bin`, no sudo):

```sh
scripts/install.sh
```

The CLI starts Redact.app in the background when it isn't running.

## Use

1. Open `Redact.app`, create the vault, save the Recovery Key.
2. Drop a project folder on the window (or run `redact import` inside it). Review the diff, save.
3. Run things with your variables:

```sh
redact run -- npm run dev
redact run --env production -- npx wrangler deploy
redact ls                     # names only
printf '%s' "$NEW_KEY" | redact set STRIPE_SECRET_KEY --env production
```

4. Delete the plaintext `.env` files once `redact run` works for you.

### AI agents

`redact run` detects AI agents (Claude Code, Cursor, Codex, …) in its process tree. For them, Redact shows an approval panel on your Mac (Deny / Allow once / Allow for 15 min) and asks for Touch ID; output is always masked as `[redact:NAME]`.

Add the MCP server to Claude Code:

```sh
claude mcp add redact -- /path/to/Redact.app/Contents/Resources/bin/redact mcp
```

Tools: `redact_status`, `redact_list_variables` (names only), `redact_run` (approved, masked), `redact_request_secret`. No tool returns a value, and agents cannot change the vault through MCP. Changes through the CLI (`set`, `rm`, `import`) by an agent need your approval.

### Cloudflare accounts

Redact → Identities manages [Wrangler auth profiles](https://developers.cloudflare.com/workers/wrangler/profiles/): log in once per account, then bind folders. Inside a bound folder, plain `wrangler deploy` uses that account. From the terminal:

```sh
wrangler auth create acme     # once per account (browser login)
redact id bind acme ~/clients/acme
redact id which               # in any folder: which account applies here
```

Redact resolves symlinks before binding (Wrangler otherwise stores a path that never matches) and warns when logins are stored in plaintext. For least-privilege or older Wrangler versions, add an **API token identity** instead; `redact run` injects it as `CLOUDFLARE_API_TOKEN` for bound folders.

## Layout

```
Sources/RedactCore     vault format, crypto, redactor, .env import, Wrangler profiles, broker protocol
Sources/RedactApp      SwiftUI app: vault controller, approvals, broker handler, UI, menu bar, ⌥⌘K
Sources/redact         CLI and MCP server
Sources/redact-devtool dev-only: creates a test vault in $REDACT_HOME without Touch ID
spikes/                M0 spike code and findings
```

`REDACT_HOME=<dir>` points the app and CLI at another vault folder (for testing).
