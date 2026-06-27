# anvil — Design (v1)

A native, fast macOS app that replaces tk-ui's fire-and-forget `w` (iTerm spawn) with a
**supervised** model: browse and groom tickets across all tk projects, and launch `/work`
as a non-interactive Claude run that reports liveness, queues for a human when blocked, and
lands results back on the ticket.

> Supersedes `~/code/ticket/docs/HARNESS-DESIGN.md`. That doc front-loaded a multi-stage
> workflow engine and a plugin/adapter layer into v1; this design deliberately cuts both —
> `/work` already runs its own implement→review loop, so v1 is a single supervised launch.

## 1. Motivation

`tk` gives us solid ticket management (CLI, TUI, MCP). What it lacks is a way to *run agents
against tickets and supervise them*. The gap is concrete in tk-ui's `w` keybinding, which
`osascript`-spawns an iTerm + Claude session per ticket:

- A one-shot terminal spawn can't be **monitored** — once launched, the launcher forgets it.
  No signal for running / done / failed / blocked.
- Results flow back only **implicitly**, via the file watcher noticing the ticket changed.
- There's no way to **queue** a run that's waiting on a human, or to recover/resume it.

A native app can own the worker process, consume its structured event stream, and present a
real control plane.

## 2. What we're building (v1)

A fast native macOS app that, across **all** tk projects:

1. Browses/filters tickets and grooms one to a launchable state (why/success, status,
   priority, notes).
2. Launches `/work <id>` as a supervised `claude -p` run in an isolated git worktree in that
   ticket's own repo.
3. Shows it go running → needs-input → done/failed live, with token usage.
4. Lets you answer inline when it blocks; the run resumes.
5. Lands the result (status, branch, notes) back on the ticket.
6. Surfaces a **consolidated cross-project inbox**: what's ready to work, and what needs
   intervention.

No iTerm spawn anywhere in the flow.

## 3. Architecture

### 3.1 Engine / UI split + stack

**Swift / SwiftUI.** Two modules, one process for v1:

- **`AnvilEngine`** — a standalone, headless Swift core with **no UI dependencies**. Owns
  process supervision, the tk connection, git/worktrees, the run registry, and the event
  bus. Exposes a **command-in / event-stream-out** API.
- **`AnvilApp`** — the SwiftUI app, a **pure client** of `AnvilEngine`.

The seam is the point: an iPhone can never spawn `claude` or touch the repos, so the engine
must eventually become a **headless daemon on the machine that has the code** (the Mac
Studio), with every UI — Studio, MacBook, iPhone — a network client of it. v1 builds **no**
networking; it only keeps the engine cleanly separable so "go multi-device" is *insert a
transport*, not *rearchitect*. Swift (not Tauri) is chosen so a native iOS client later
reuses the engine code.

### 3.2 Execution model — ephemeral `claude -p` + resume

Launch `claude -p "/work <id>" --output-format stream-json`. The process streams events
while it works and **exits at turn end**. anvil captures the `session_id`; to continue,
`claude -p --resume <session_id> "<answer>"`. No long-lived agent process lingers between
turns — good for "lightning fast", and it scales to many tickets without a babysitter
process each. (Long-lived bidirectional streaming / a TS sidecar with `canUseTool`/`defer`
is the path for *interactive* mode later; the event-parsing and session model carry over.)

**Spike-confirmed launch (see `docs/spike-findings.md`):** exec the real `claude` binary, not
the shell alias; `claude -p "/work <id>" --append-system-prompt "<contract>" --output-format
stream-json --verbose --model opus --permission-mode acceptEdits` (or `bypassPermissions`
inside the worktree). **Not `--bare`** — it forces API-key auth. Capture `session_id` from
`system/init`; resume from the **same cwd** (the worktree).

### 3.3 needs-input contract + queue + resume pointer

Headless `claude -p` has no chat to "ask the human" into — the turn just ends. anvil owns its
own contract instead of editing `/work`:

- At launch anvil **injects a headless preamble**: *when you would stop and ask the human,
  end your turn with a `<<<ANVIL:NEEDS_INPUT>>>` block (question + options); on completion
  end with `<<<ANVIL:DONE>>>`.* `/work` and warp stay pristine.
- anvil parses the sentinel from the `stream-json` `result.result`. **Scan for the last
  marker** — Opus may prefix prose before the block (spike-confirmed) — and parse the JSON
  that follows, bounded by a closing `<<<ANVIL:END>>>`. `NEEDS_INPUT` → the run enters a
  **queued** state holding the question + `session_id`. Answering resumes the session.
- done/failed are cross-checked against **tk status + process exit code**; the sentinel only
  disambiguates the *blocked* case.

**Queue location:** the live queue (session_id + question) lives in anvil. It is **mirrored
to the ticket** as a waiting-on-human marker + the question as a note + a break-glass resume
pointer:

```
anvil-session:  <session_id>
anvil-worktree: <abs worktree path>
anvil-host:     <hostname>
```

This makes the run self-describing: if anvil is down you can hand-run
`claude -p --resume <session_id> "<answer>"` from the worktree **on that host**. Caveats:
resume needs the session JSONL + the exact worktree cwd + the worktree still on disk, so
break-glass is host-pinned; and a manual resume desyncs anvil's live view until it re-reads
the ticket. Other devices can *see* the waiting state (it's in tk, git-synced) but can't
*act* — answering is pinned to the host.

> Spike result (`docs/spike-findings.md`): the loop is validated end-to-end
> (NEEDS_INPUT → resume → DONE) on the subscription. Residual risk to close in F1/F3: the real
> `/work` skill *loaded, with tools* — the spike used bare prompts. Fallback if it ever proves
> flaky: also teach `/work` to emit the signal.

### 3.4 Isolation — git worktree per run

Each run gets `git worktree add <scratch>/anvil/<ticket-id> -b anvil/<ticket-id>` in the
ticket's **own project repo**. Concurrent runs never collide; your main checkout is never
touched; the branch+diff is the review/merge unit. `/work` commits and pushes the branch;
**you review and merge** (autonomous agents don't push straight to `main`).

The real cost worktrees add: a bare worktree shares `.git` but **not** untracked/ignored
files — no `.env`, no `node_modules`, no build artifacts — so `/work`'s test step would fail.
anvil runs a **configurable per-project prepare step** after `git worktree add` (symlink
`.env`, run install/bootstrap) before launching `/work`.

### 3.5 tk integration — multi-project, CLI + FSEvents

tk's central store is already multi-project (`MultiStore`, IDs namespaced
`project/ticket-id`). anvil is **all-projects by default**.

- **Reads via `tk query` (JSONL), writes via `tk edit/add-note/create`** — through the same
  store layer as MCP (timestamping, validation, parent-status propagation), no daemon, no
  markdown parsing of our own, and **never our own `tk serve`** (two serve daemons would duel
  over the store's 5-second git auto-commit/push). Verified `tk` realities: `tk show` ignores
  `--json` (YAML frontmatter); `tk query` emits JSONL with extras flattened to top level; the
  CLI wants the **bare slug** (not the namespaced id), and per-project reads are scoped with
  `TICKETS_DIR=<central_root>/tickets/<project>` (cloned projects can also use `--repo <repo>`).
  `ready`/`blocked`/`inbox`/`store-info` are MCP-only, so anvil **computes them client-side**
  from the full ticket set and derives store layout from the central store + `config.yaml`.
  The `anvil-state` extras anvil writes (F3) surface in `tk query` as the file-backed
  needs-intervention signal.
- **Liveness via FSEvents** (debounced) on the central store root: re-query on any change —
  local edits, other agents, and tickets pulled in by the existing global `tk serve`'s git
  sync. Browse reads **every** project's ticket dir under the central store (cloned or not);
  cloning only gates launch. anvil can `tk sync` after its own writes.
- **Browse = all projects; launchable = projects with a ticket AND a local repo path.** The
  worktree repo path comes from `~/.ticket/config.yaml` `projects[<project>].path`;
  `ticket_store_info` gives ticket *dirs* (not repos) and lists more projects than are cloned
  here. Projects without a local clone are browse-only on this host — correct for the
  multi-device future.
- The spawned `/work` sessions get the tk MCP for free — they inherit your global `claude`
  config, which warp already renders tk into.

### 3.6 Auth / billing

As of June 2026 the planned "Agent SDK credit pool" split is **paused** — `claude -p` and
Agent-SDK/programmatic usage still draw from your normal Pro/Max subscription limits. So:

- v1 **rides your Max subscription** via the local, already-logged-in `claude` — no
  `ANTHROPIC_API_KEY`, no per-token cash cost.
- Cost lens is **subscription usage limits**, not dollars. anvil surfaces token usage (from
  the result JSON) as a throughput guardrail.
- Stay **auth-agnostic**: `claude` owns auth; anvil just spawns it. If the split returns,
  flipping to API-key billing is a config/env change, not a rearchitecture.
- **Spike-confirmed:** runs report `apiKeySource:"none"` and a `five_hour` `rate_limit_event`
  — definitively on the subscription. Do **not** pass `--bare` (forces `ANTHROPIC_API_KEY`,
  never reads OAuth/keychain). Usage gauge = `rate_limit_event` + `result.total_cost_usd`.

## 4. Consolidated cross-project inbox

The app's **front door**: one triage home across all projects, two lanes —

- **Ready to work** — `ticket_ready` semantics (deps resolved, actionable).
- **Needs intervention** — anvil's `NEEDS_INPUT` blocked runs ∪ tk's native `ticket_inbox`,
  deduped.

Launch-from-inbox starts a supervised run on a ready ticket; answer-inline resolves a blocked
run. The browser and worker board sit behind the inbox.

## 5. Scope

**In v1:** multi-project ticket browse + groom; single supervised `/work` launch
(`claude -p` + resume); worktree-per-run + prepare; needs-input contract + queue + ticket
resume pointer; tk CLI + FSEvents data layer; SwiftUI app (browser, grooming, worker board);
consolidated cross-project inbox; subscription auth + usage surfacing; engine/UI seam.

**Not in v1:**
- Multi-stage workflow engine (work→review orchestration) — `/work` reviews itself.
- Plugin/adapter abstraction; Codex/Cursor backends — Claude only.
- Networking, remote engine, iOS app, multi-device sync — engine *seam* only.
- Interactive mode (live brainstorm/debug/attach, keyboard takeover).
- Containers / blast-radius isolation — worktree is workspace isolation only.
- Auto-merge of run branches — `/work` pushes a branch; you review/merge.
- Full ticket-editing UI beyond grooming (why/success, status, priority, notes).

## 6. Risks / the spike

**Spike complete** (`docs/spike-findings.md`): stream-json events + `session_id`, the
NEEDS_INPUT → resume → DONE sentinel loop, subscription auth, and the AnvilEngine
command/event contract + repo-path resolution are all validated against `claude` 2.1.195.
**Residual risks to close while building:** (1) the real `/work` skill loaded *with tools*
honoring the sentinel contract — the spike used bare prompts (F1/F3); (2) `/work`'s test step
passing in a *prepared* worktree with `.env`/deps present (F2).

## 7. Ticket map

Epic `anvil/brainstorm-anvil-plan-853f`:

| Ticket | Depends on |
|---|---|
| Spike: validate the supervised-run spine | — *(ready)* |
| tk data layer — multi-project CLI client + FSEvents | — *(ready)* |
| AnvilEngine core + supervised `claude -p` runner | Spike |
| Worktree-per-run + per-project prepare step | Spike |
| Needs-input contract + human queue + ticket resume pointer | AnvilEngine |
| SwiftUI app — multi-project browser, grooming, worker board | AnvilEngine, Needs-input, tk data layer |
| Consolidated cross-project inbox | Needs-input, tk data layer, SwiftUI app |

## 8. Future (v2+)

Remote engine + networking; native iOS client; multi-device sync. Interactive mode
(live attach, brainstorm/investigate). Codex/Cursor backends behind a plugin contract +
the multi-stage workflow engine. Containers for blast-radius isolation. Auto-merge / PR
automation.
