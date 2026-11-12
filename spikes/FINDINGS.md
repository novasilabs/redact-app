# M0 spike findings

Date: 2026-11-12 · Mac: Apple silicon, macOS 14.8.3 · Swift 6.0.3 / Xcode 16.2 · Wrangler 4.151.3

All code is in this folder (`swift test` runs 12 tests, all passing). It is spike-quality: the parts worth keeping are `Redactor`, `VaultKeyWrap`, `PeerIdentity` and `WranglerProfiles` in `Sources/RedactCore`.

| # | Spike | Result | Verdict |
|---|---|---|---|
| 1 | Streaming output redactor | Correct at every chunk boundary; 711 MB/s with 500 patterns | ✅ Go |
| 2 | Wrangler auth profiles | Format understood; Swift reader matches Wrangler's lookup; 1 Wrangler bug to work around | ✅ Go (Mode A) |
| 3 | Isolating Wrangler via `XDG_CONFIG_HOME` | Does **not** work on your Mac | ❌ Drop; use Mode B tokens as fallback |
| 4 | Secure Enclave key wrap + Touch ID | Works from an ad-hoc signed CLI, no entitlements | ✅ Go |
| 5 | CLI ↔ app IPC with caller identification | Works; detects Claude Code; signature check only meaningful with a Developer ID | ✅ Go, with a caveat |

---

## 1. Streaming redactor (`Redactor.swift`, `spike-redact`)

- Masks raw values plus base64 (padded, unpadded, URL-safe), percent-encoded and JSON-escaped forms with `[redact:NAME]`. Longest match wins when one value contains another.
- Holds back `maxPatternLength − 1` bytes between chunks, so a secret split across two reads is still caught. Tested at every chunk size 1…N, plus 200 randomized runs with random chunking compared against one-shot output.
- Values shorter than 6 bytes (e.g. `PORT=3000`) are **not** masked, because masking them would mangle normal output. They are reported as `skipped` so the UI can warn.
- **Performance:** a first-byte index managed only 9–15 MB/s, because keys sharing prefixes like `sk_` matched on every common letter. Indexing on the first **two** bytes gives **711 MB/s** (release build, 200 secrets = 500 patterns). That is far above any dev server's output rate.
- End to end: `spike-redact --mask FAKE_KEY -- sh -c …` masked stdout, stderr and base64 output, and kept the child's exit code (3).
- **Open issues for M1:**
  - Piping makes the child see a non-TTY, so colours and progress bars change. Agents don't care, but for human use `redact run` should use a pseudo-terminal (pty) when its own stdout is a TTY.
  - Building the 64K-entry index takes about 1 ms. Build it once per `run` and share it between the stdout and stderr redactors.
  - Values that a program transforms (e.g. prints only the first 8 characters, or hex-encodes them) are not caught. That is an accepted limit, and the approval sheet must say so.

## 2. Wrangler auth profiles (`WranglerProfiles.swift`)

Verified by reading the Wrangler 4.151.3 bundle and testing with throwaway home folders:

```
<root>/config/<profile>.toml                 plaintext: oauth_token, refresh_token, expiration_time, scopes
<root>/config/<profile>.enc                  encrypted version, when `wrangler auth keyring` is on
<root>/profiles/directory-bindings.json      { "/abs/dir": "profile" }
<root> = ~/.wrangler if it exists (legacy, wins), else $XDG_CONFIG_HOME/.wrangler, else ~/Library/Preferences/.wrangler
```

- Lookup is "longest bound ancestor directory wins", with a correct path-boundary check (`acme-old` is not inside `acme`). `CLOUDFLARE_API_TOKEN` overrides everything. The Swift reader reproduces this and is tested.
- There is no `--json` output for `wrangler auth list`, so **read the files directly and write through `wrangler auth activate/deactivate`** to stay compatible as the experimental feature changes.
- **Wrangler bug:** `wrangler auth activate <dir>` stores the path *without resolving symlinks*, but lookup uses the real cwd. Binding `/tmp/x` stores `/tmp/x` while the cwd is `/private/tmp/x`, so the binding silently never applies. **Redact must resolve the real path before calling `activate`**, and `brokenBindings()` detects existing bad ones. (Worth reporting upstream.)
- Profile files do not record which account was chosen, so the account list has to come from `wrangler whoami` per profile.
- **On your Mac today:**
  - Wrangler is using `~/.wrangler`. `~/Library/Preferences/.wrangler` is a stale copy (last written Oct 8) and can be ignored.
  - Your OAuth token is stored **in plaintext** in `~/.wrangler/config/default.toml`. Running `wrangler auth keyring` moves it into the macOS Keychain, and Redact should offer this during setup.
  - Only the `default` profile exists, with no bindings yet.

## 3. Legacy isolation via `XDG_CONFIG_HOME` (CF-7)

- **Does not work** while `~/.wrangler` exists (it does on your Mac), because the legacy folder always wins.
- Overriding `HOME` does isolate logins (tested), but it also changes git, npm and ssh config for the child process. That is too invasive.
- **Decision:** drop CF-7 as designed. When `wrangler auth` is unavailable, fall back to **Mode B** (scoped API token from the vault, injected as `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`).

## 4. Secure Enclave key wrap + Touch ID (`VaultKeyWrap.swift`, `spike-se`)

- The design wraps a random 256-bit vault key to a Secure Enclave P-256 key, using a one-time key pair plus HKDF-SHA256 and ChaCha20-Poly1305.
- `SecureEnclave.P256.KeyAgreement.PrivateKey` works from an **ad-hoc signed CLI with no Keychain entitlement**. Its `dataRepresentation` (314 bytes, or 476 with biometry) is an opaque handle that only this Mac's Secure Enclave can use, so it can be stored as a plain file.

| Case | Result |
|---|---|
| No biometry, same process | unwrap ok, 23 ms |
| No biometry, new process | unwrap ok, 9 ms |
| `.biometryCurrentSet`, first unlock | Touch ID prompt shown, unwrap ok (159 s = waiting for your finger) |
| `.biometryCurrentSet`, new process | Touch ID prompt, unwrap ok, 2.4 s |
| Second use with the same `LAContext` | no prompt, 7 ms |

- **Design consequence:** the **app** holds the `LAContext` (the unlocked session) and does all decryption. The CLI never touches the vault key; it asks the app over IPC. That gives one Touch ID per unlock session instead of one per CLI call, and auto-lock is just "invalidate the context".
- `.biometryCurrentSet` makes the key unusable if fingerprints are added or removed. That is the right security choice, and it is why the Recovery Key must exist from day one.
- Not yet tested: `.userPresence` (Touch ID **or** password fallback), and the Recovery Key wrap. Both are straightforward.

## 5. CLI ↔ app IPC (`PeerIdentity.swift`, `spike-ipc`)

- A Unix domain socket created with mode `0600` (only you can connect). The server reads the caller's **audit token** with `LOCAL_PEERTOKEN`, which avoids the PID-reuse race, then checks the code signature and walks the parent process chain.
- Three clients were tested, all launched from this Claude Code session:

| Client | Signing ID seen | Ancestor chain | Agent guess |
|---|---|---|---|
| `spike-ipc` | `spike-ipc-…` (ad-hoc) | zsh ← claude ← disclaimer ← Claude | Claude Code ✅ |
| impostor re-signed as `com.example.impostor` | `com.example.impostor` (ad-hoc) | same | Claude Code ✅ |
| Python | `Python` | same | Claude Code ✅ |

- **Agent detection works** from the process tree, which is good enough to label approval sheets ("Claude Code wants to run `npm test` with STRIPE_KEY").
- **Caveat:** with ad-hoc signing, the identifier can be anything, as the impostor shows, and any process running as you can connect. Code-signature checks only become a real security boundary once Redact is signed with a **Developer ID**, so the app can require the CLI's team ID. You currently have no signing identities.
  - Until then, **the Touch ID approval sheet is the only boundary.** It must show the caller's real executable path and parent chain, not just a name.
  - Distributing a notarized open-source build also needs the Apple Developer Program ($99/yr).
- Socket paths are limited to 104 bytes. Use `~/Library/Application Support/Redact/agent.sock` (short enough), not a temp path.

## Decisions carried into the PRD

1. **Agent broker architecture:** the app holds the unlocked session and does all decryption; the CLI is a thin client over a `0600` Unix socket with audit-token peer checks.
2. **CF-7 replaced:** the fallback for Wrangler without profiles is Mode B (API token), not config-directory isolation.
3. **Path resolution:** Redact resolves real paths before every `wrangler auth activate`, and the Identities screen warns about broken bindings.
4. **Setup step:** offer `wrangler auth keyring` to move plaintext OAuth tokens into the Keychain.
5. **`redact run`** uses a pty when attached to a terminal; masking is always on when an agent is detected in the parent chain.
6. **Developer ID** is needed before the first public release (signature-pinned CLI and notarization).

## Still open

- **Vault file format** was not spiked. Recommendation: one file of individually sealed records (JSON or CBOR envelope, record id + version as associated data), rewritten atomically. A personal vault is small (well under 1 MB), per-record versions make folder sync merges simple, and it avoids shipping SQLite inside an encrypted envelope. Revisit if the vault grows past ~10k records.
- The approval-sheet UX and grant model need a clickable prototype in the M1 app.
