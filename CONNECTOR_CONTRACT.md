# Claude quota connector — safety and measurement contract

This contract documents the implementation included with the application. It is
not proof that a particular account currently provides a readable quota.

- Official interactive Claude Code `/usage` only, never SDK print/model prompts.
- Native C `forkpty` creates the dedicated terminal/session; the child execs the installed CLI.
- Safe mode, empty tools, no Chrome, empty strict MCP, process-scoped updater disabled.
- The dedicated CLI receives the normal macOS USER/HOME identity to resolve its own existing login. Arqmeter does not extract credentials, copy keys or automate sign-in. A recognized subscription header must be present before /usage is sent.
- One serial acquisition in flight. Normal refresh 120 seconds after success.
- Server limitation: 600/1200/2400/3600-second backoff. Deadline persisted across relaunch and wake.
- Empty private reader directory: only its exact known trust screen may be confirmed; no global trust/auth/permissions bypass.
- Unknown login/setup stops without automatic authentication. No cookie, credential, OAuth export or private endpoint.
- Final rendered terminal is parsed, not accumulated history. Context/token/cost percentages are never plan quotas.
- Stable quota values/reset labels, not constantly updating terminal duration or locally derived expiry, determine stability.
- Last-known CLI bars are not promoted to fresh. Earlier authentic report stays unchanged, with age and `non actuel` in the UI.
- Selected Desktop/Web account surfaces remain strict: they never silently fall back to CLI.
- CLI selection activates collection at launch/wake; UI/source selection stops the other collector.
- Source errors are shown in settings/cards/menu; menu uses a neutral state word when quota is absent.
- Cleanup drains then closes the owned PTY, sends bounded signals only to its positive owned group, and checks leader reaping/group absence.
- Unconfirmed cleanup suspends acquisition. No blocking waitpid. Task-owned PIDs are recorded in test receipts.
- Existing user statusline integrations are retained; installation does not rewrite their scripts/settings.
- An explicitly requested probe can retain only the final Usage panel in a bounded private 0600 diagnostic, with emails, user paths and token-like values masked. The normal reader never retains terminal content.
- Official statusline capture ignores absent rate_limits and deduplicates replayed inputs. Only a digest of rate windows/API-duration/session identity is stored, no raw identity or transcript.
- No Codex engine, SQLite schema, history or trial changes are needed for this reader.

Passing tests/offline replay do not prove a fresh account quota or acceptance of
the installed application. Synthetic fixtures are not account observations.
