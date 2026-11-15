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

Only the `redact` binary shipped inside Redact.app (checked by its code signature hash) ever receives values; a script talking to the socket directly is refused. A command runs without asking only when it plainly comes from you: started in a terminal app (Terminal, iTerm, Ghostty, WezTerm, …) with no AI agent above it. Anything else, including detached background processes and IDE terminals, gets the approval panel and Touch ID.

Monorepos: each app can be its own project. From the repo root, pick one by name with `-p`: `rr -p driver pnpm --filter driver dev` (works with every command: `redact ls -p driver`).

Add the MCP server to Claude Code:

```sh
claude mcp add redact -- /path/to/Redact.app/Contents/Resources/bin/redact mcp
```

Tools: `redact_status`, `redact_list_variables` (names only), `redact_run` (approved, masked), `redact_request_secret`. No tool returns a value, and agents cannot change the vault through MCP. Changes through the CLI (`set`, `rm`, `import`) by an agent need your approval.

### OpenAI and Anthropic keys stay in Redact

When an agent runs a command (or you pass `--llm-proxy`), `OPENAI_API_KEY` and `ANTHROPIC_API_KEY` are not injected. Instead the command gets:

```
OPENAI_API_KEY=redact-proxy-…            ANTHROPIC_API_KEY=redact-proxy-…
OPENAI_BASE_URL=http://127.0.0.1:PORT/openai/v1   ANTHROPIC_BASE_URL=http://127.0.0.1:PORT/anthropic
```

The official SDKs (and most libraries) read these variables, so calls work unchanged: Redact's local proxy swaps in the real key and forwards to `api.openai.com` / `api.anthropic.com`, streaming included. The command can use the API but can't read or leak the key. Placeholders stop working when the command exits, when the vault locks, or after 12 hours. The proxy listens on 127.0.0.1 only and forwards to those two hosts only. If a project sets its own `OPENAI_BASE_URL` (e.g. Azure), that provider is left alone. Code that hard-codes `https://api.openai.com` will get a 401 with the placeholder; point it at the base URL variable instead.

### Push to hosts

```sh
redact push --to cloudflare --env production --dry-run   # names only, no approval needed
redact push --to cloudflare --env production             # wrangler secret bulk
redact push --to github --target production              # gh secret set (GitHub Actions environment)
redact push --to supabase                                # supabase secrets set
redact push --to vercel --env preview                    # vercel env add (untested on a real account)
redact push --to aws --target myapp/prod                 # Secrets Manager, one JSON secret (untested)
```

Values go to each host's own CLI over stdin, never as arguments. Agents need your approval, like `redact run`. A folder's Cloudflare API-token identity is used to authenticate Wrangler, never pushed as a secret, and never given to other hosts' CLIs.

### Leak scan and pre-commit hook

```sh
redact scan                    # this folder: vault values + well-known key formats (AWS, GitHub, Stripe, …)
redact scan --history          # …plus every added line in git history
redact scan --all              # …plus shell history and Claude Code / Codex transcripts
redact hook install            # pre-commit: block commits that contain secrets
```

The app's **Health** screen runs the same scan across all your projects. Vault values are matched inside the app; only names, file and line come back. The pre-commit hook never prompts for Touch ID or starts the app: if Redact is locked or not running, it checks well-known key formats only and says so.

### Shell integration

```sh
eval "$(redact hook zsh)"      # in ~/.zshrc  (or: redact hook bash)
```

Shows `redact: demo-app · development · cf: acme · gh: work · aws: acme-prod` when you `cd` into a project, sets `$REDACT_PROMPT` for your prompt, exports `AWS_PROFILE` for folders bound to an AWS account (never overriding one you set yourself), and adds `rr` = `redact run --` (`rr -p NAME …` and `rr --env production …` work too).

Add `--wrap gh,vercel,supabase,wrangler` to run those tools with the account bound to the current folder. Wrappers inject only that account's credentials (not your project variables), pass straight through when nothing is bound or Redact isn't running, and never start the app.

### Cloudflare accounts

Redact → Identities manages [Wrangler auth profiles](https://developers.cloudflare.com/workers/wrangler/profiles/): log in once per account, then bind folders. Inside a bound folder, plain `wrangler deploy` uses that account. From the terminal:

```sh
wrangler auth create acme     # once per account (browser login)
redact id bind acme ~/clients/acme
redact id which               # in any folder: which account applies here
```

Redact resolves symlinks before binding (Wrangler otherwise stores a path that never matches) and warns when logins are stored in plaintext. For least-privilege or older Wrangler versions, add an **API token identity** instead; `redact run` injects it as `CLOUDFLARE_API_TOKEN` for bound folders.

### GitHub, Vercel, Supabase and AWS accounts

```sh
redact id add github work --from-gh my-work-login     # token from `gh auth token --user …`
printf '%s' "$TOKEN" | redact id add vercel client-x   # token from stdin (or typed, hidden)
redact id add supabase personal                        # prompts for the token
redact id add aws acme-prod --profile acme-prod        # just a profile name from ~/.aws/config
redact id bind work ~/code                             # nearest bound folder wins, per provider
redact id bind client-x ~/clients/x
redact id which                                        # what applies here
```

| Provider | Set for bound folders |
|---|---|
| GitHub | `GH_TOKEN` |
| Vercel | `VERCEL_TOKEN` |
| Supabase | `SUPABASE_ACCESS_TOKEN` |
| Cloudflare (token) | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` |
| AWS | `AWS_PROFILE` (no secret stored) |

Credentials go to `redact run` and the shell wrappers. `redact push --to github` authenticates `gh` with the folder's GitHub account and never uploads that token as a secret; each host's CLI only ever sees its own provider's credentials. Agents need your approval to add or rebind accounts.

## Backup and moving to a new Mac

**Backup & restore** (⌘7) exports a `.redact` file: everything, or only the projects, keys, code sets and
accounts you pick. It's encrypted, and the Recovery Key you saved at setup opens it; the Touch ID key
stays on this Mac. Wrangler logins, `~/.aws` and shell hooks live outside the vault and aren't included.

On a new Mac, choose **Restore from backup** on the first screen (or double-click the file), enter the
Recovery Key, and set up Touch ID. Folders saved under another user name (`/Users/old/...`) are moved to
your home folder. A checklist then covers what lives outside the vault. Restoring into an existing vault
shows what's new or changed and restores only what you check.

## Release

```sh
REDACT_VERSION=0.1.0 scripts/make-dmg.sh
```

Builds `build/Redact-<version>.dmg` (and its `.sha256`): a universal app (Apple Silicon + Intel), ad-hoc signed with the hardened runtime, plus a "Read me first" note. Redact isn't notarized (no Apple Developer ID), so users allow it once: on macOS 15+ via System Settings > Privacy & Security > Open Anyway, on macOS 14 with right-click > Open. In the app, **Redact > Set Up Terminal…** installs the `redact` command (`~/.local/bin`) and the shell hook. Dev hooks (`REDACT_HOME`, screenshot mode) exist only in debug builds.

## Layout

```
Sources/RedactCore     vault format, crypto, redactor, .env import, Wrangler profiles, broker protocol
Sources/RedactApp      SwiftUI app: vault controller, approvals, broker handler, UI, menu bar, ⌥⌘K
Sources/redact         CLI and MCP server
Sources/redact-devtool dev-only: creates a test vault in $REDACT_HOME without Touch ID
spikes/                M0 spike code and findings
```

`REDACT_HOME=<dir>` points the app and CLI at another vault folder (for testing).
