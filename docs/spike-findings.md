# Spike findings — supervised-run spine

Ticket: `anvil/spike-validate-supervised-0ae2`. Validates the assumptions anvil's
execution engine rests on, against the real `claude` CLI on this machine, before any
Swift is written. All four runs are throwaway; commands are reproducible below.

Environment: `claude` **2.1.195**, macOS. `ANTHROPIC_API_KEY` **unset**. `claude` is a
shell **alias** (`tabset …; command claude`) — the engine must exec the real binary, not
go through the shell. Runs executed from a neutral cwd (the session scratchpad).

## Result: all acceptance items pass

| # | Claim | Verdict |
|---|---|---|
| a | `claude -p … --output-format stream-json` yields parseable events + session_id | **PASS** |
| b | injected preamble makes the agent emit `<<<ANVIL:NEEDS_INPUT>>>` / `<<<ANVIL:DONE>>>` | **PASS** (with a parser caveat) |
| c | `claude -p --resume <id> "<answer>"` continues the same session in-context | **PASS** |
| d | runs draw on the Claude subscription with no API key | **PASS** |
| e | AnvilEngine command/event contract + per-project repo-path resolution | **DECIDED** (below) |

## What each run proved

- **run1** — `-p "PONG"` stream-json, haiku. Clean JSONL: `system/init` → `assistant`
  (thinking+text) → `result`. `session_id` on every event and on `result`. `result`:
  `subtype:success`, `result:"PONG"`, `stop_reason:end_turn`, `total_cost_usd`, `usage`,
  `permission_denials:[]`, `terminal_reason:completed`. **(a)**
- **run2** — blocked task + ANVIL contract via `--append-system-prompt`, sonnet,
  `--tools "" --strict-mcp-config` (hermetic: `tools:[]`, `mcp_servers:[]`). Final
  `result.result` was *exactly* the sentinel block. **(b)**
- **run3** — `--resume <run2 id>` with a human "answer". `SessionStart:resume` hook fired;
  **same session_id**; thinking referenced the prior question; final message
  `<<<ANVIL:DONE>>>` + summary. **(c)**
- **run4** — Opus, prompt that mimics `/work`'s "stop and ask the human" contract-gate rule.
  Opus correctly routed to `<<<ANVIL:NEEDS_INPUT>>>` instead of asking in prose — **but
  prepended a paragraph of reasoning before the block.** **(b), with caveat.**

## Key learnings (these refine the build tickets)

### Sentinel parsing must be lenient — `result.result` is not always just the block
Sonnet emitted the sentinel alone; **Opus added prose before it.** So:
- **Parser (F3):** scan `result.result` for the *last* `<<<ANVIL:NEEDS_INPUT>>>` /
  `<<<ANVIL:DONE>>>` marker; take the text after it and `JSON.parse`. Do **not**
  prefix-match the whole message.
- **Contract (F3):** require the sentinel + JSON to be the **final** lines and bound the
  JSON with a closing delimiter so extraction is unambiguous under a prose preamble:
  ```
  <<<ANVIL:NEEDS_INPUT>>>
  {"question": "...", "options": ["...", "..."]}
  <<<ANVIL:END>>>
  ```
- Re-validate on the production model (Opus) when F3 lands; instruction-following on the
  exact `/work` skill body (loaded, with tools) is the one interaction this spike did not
  exercise — it ran bare prompts, not the real skill.

### Auth / billing (d)
`apiKeySource:"none"` in `init`; a `rate_limit_event` reports
`rateLimitType:"five_hour"` — the subscription's rolling window. Confirmed runs ride the
subscription. **Do not use `--bare`** (it forces `ANTHROPIC_API_KEY`/apiKeyHelper and never
reads OAuth/keychain). For a headless engine outside an interactive login, `claude
setup-token` mints a long-lived subscription token.

### Usage gauge is in the stream
`rate_limit_event.rate_limit_info` (`status`, `resetsAt`, `rateLimitType`, `overageStatus`,
`isUsingOverage`) + `result.total_cost_usd`/`usage` give anvil its "approaching limits"
signal directly. `total_cost_usd` is a notional API-equivalent (still emitted on
subscription runs) — useful as a relative throughput number, not an actual charge.

### Permissions (F1/F3)
`permissionMode` was `default` (run1) and `auto` (runs with `--tools ""`). Real `/work`
runs use tools and **will** hit permission gates headlessly. Set it explicitly —
`--permission-mode acceptEdits` (auto-approve edits + fs in cwd) or `bypassPermissions`
for full autonomy; the per-run **worktree** makes `bypassPermissions` acceptable for v1.
Monitor `result.permission_denials`.

## (e) AnvilEngine command / event contract

**Commands (UI → engine)**
- `listProjects() -> [{ project, ticketDir, repoPath?, launchable }]`
- `listTickets(filter) / groom(id, fields)` — via `tk … --json` / `tk edit|add-note`
- `launch(ticketId) -> runId` — resolve repo, create+prepare worktree, spawn `claude -p`
- `answer(runId, text)` — `--resume <sessionId>` with text
- `cancel(runId)`, `getRun(runId)`, `listRuns()`

**Events (engine → UI)** — derived from the stream:
| stream-json | engine event |
|---|---|
| `system/init` | `run.started { runId, sessionId, model, cwd, mcpServers, permissionMode }` |
| `assistant`(text) | `run.output { runId, text }` |
| `system/thinking_tokens` | `run.progress` (optional) |
| `rate_limit_event` | `run.usage { rateLimit, costUsd?, tokens? }` |
| `result` subtype=success, scan `result.result` | sentinel `NEEDS_INPUT` → `run.needsInput { question, options }`; `DONE` → `run.done { summary }`; neither → `run.done` (cross-check tk status) |
| `result` is_error / nonzero exit / `terminal_reason!=completed` | `run.failed { error }` |

**Run state machine:** `queued → running → needsInput → (running on resume) → done | failed | canceled`.

**Recommended launch invocation (real `/work`, not the hermetic spike flags):**
```
command claude -p "/work <namespaced-id>" \
  --append-system-prompt "<ANVIL headless contract>" \
  --output-format stream-json --verbose \
  --model opus \
  --permission-mode acceptEdits   # or bypassPermissions in the worktree
# resume:  command claude -p --resume <sessionId> "<answer>"  (same cwd!)
```
Do **not** carry over the spike's `--tools "" --strict-mcp-config` (those disabled tools +
MCP to make the sentinel test hermetic; real `/work` needs tk + tools). Resume is scoped to
the encoded cwd — always resume from the worktree path.

## (e) Repo-path resolution + launchability

- **Worktree repo path** = `~/.ticket/config.yaml` → `projects[<project>].path`.
- **Ticket dir** (FSEvents watch / direct read) = `ticket_store_info.projects[<project>]`
  under `central_root` (`/Users/steve/code/tickets-store`).
- The two project sets differ: `ticket_store_info` lists projects that have *tickets*
  (incl. ones with no local clone — `carview`, `cortex`, `moo-rs`, `weft`); config lists
  locally-registered repos (incl. `planning`, which has no tickets). **Launchable =
  has a ticket AND a local repo path.** Others are browse-only on this host — the correct
  behavior for the future multi-device split (each host launches only what it has cloned).
- Worktree: `git worktree add <scratch>/anvil/<ticket-id> -b anvil/<ticket-id>` in the
  resolved repo; prepare step (symlink `.env`, install) before `/work`.

## Reproduce
```
SCRATCH=<scratchpad>
cd "$SCRATCH"
# (a) basic stream + session
command claude -p "Reply with exactly the single word: PONG" \
  --output-format stream-json --verbose --model haiku
# (b) blocked → NEEDS_INPUT  (hermetic)
command claude -p "<empty-contract task>" \
  --append-system-prompt "<ANVIL contract>" \
  --output-format stream-json --verbose --model sonnet --tools "" --strict-mcp-config
# (c) resume → DONE
command claude -p "<answer>" --resume <sessionId from b> \
  --append-system-prompt "<ANVIL contract>" \
  --output-format stream-json --verbose --model sonnet --tools "" --strict-mcp-config
```
