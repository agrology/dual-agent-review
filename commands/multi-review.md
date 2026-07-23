---
description: Author-mode multi-review review — watch a spec/plan doc and converge with an external reviewer, ending at a human gate.
argument-hint: "[doc-path | PR-URL] [--reviewer <id>] [--reviewers <csv>] [--attended]"
---

You are the **author** in a multi-review review. Drive it with the repo's shell helpers; you
own prose edits, the helpers own the marker. Never advance past the human gate.

## 1. Resolve the argument

**Split first.** `$ARGUMENTS` may carry `--reviewer <id>` and/or `--attended` in addition to
the doc path or PR ref, in any order, before or after the positional. Extract them:

- `--reviewer <id>` — per-invocation reviewer override, consumed in §2.5.
- `--reviewers <csv>` — a comma-separated reviewer-provider set (e.g. `codex,fable,gemini`),
  consumed in §1.5. Naming this flag (or setting `MULTI_REVIEW_REVIEWERS`) is what turns the run
  into a **star** review (one primary — you — plus N independent secondaries); a single
  `--reviewer <id>` (or nothing) is the ordinary one-reviewer path below. The two are
  independent axes, not to be combined: if `--reviewers`/`MULTI_REVIEW_REVIEWERS` resolves to a
  non-empty set, it takes over and any `--reviewer` is ignored for this run.
- `--attended` — selects the attended route directly, consumed in §2.5.

Everything else is `<positional>` (empty if `$ARGUMENTS` was flags only, or absent entirely).
Classification and doc resolution below use `<positional>` only — never the raw
`$ARGUMENTS` — so a trailing `--reviewer <id>` can never corrupt PR-ref matching or become
part of a doc path.

### Classify (doc path vs. PR)

Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh parse "<positional>"`.

- **Exit non-zero** (not a PR ref) → this is a local doc. Continue at "Resolve the doc" below.
- **Exit 0** → it printed `owner|repo|number` (owner/repo empty for the bare `#n` form). This
  is **PR mode**:
  1. If owner/repo are empty, fill them: `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh resolve-repo` →
     `owner|repo` for the current repo. If it fails, report and STOP.
  2. Compute the scratch path:
     `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh scratch-path "<owner>" "<repo>" "<number>"`.
  3. **Resume vs. fresh (r1) — re-ingest ONLY when the scratch file is absent.** Re-ingesting
     rewrites the file via `seed` and would erase accumulated reviewer/author threads, so:
       - **Scratch file does not exist** → `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh ingest "<owner>"
         "<repo>" "<number>"` (fetches via `gh`, writes the file, prints its path). On `gh`
         failure (unauthenticated, PR not found), report and STOP.
       - **Exists with a non-terminal marker** (`awaiting-reviewer`/`awaiting-author`, via
         `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh marker "<scratch>"`) → **resume**: do NOT ingest. Go
         straight to Arm; `init` is idempotent and preserves the existing threads. (`ingest`
         also refuses to clobber without `--fresh`, as a backstop.)
       - **Exists with a terminal marker** (`converged`/`exhausted`) → surface it and ask the
         engineer: resume reading it (skip ingest), or start fresh. Only if they choose fresh,
         run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh ingest --fresh "<owner>" "<repo>" "<number>"`.
  4. Set `<doc>` to the scratch path and proceed to §2 (Arm) exactly as for a local doc — the
     egress guard already allows `.multi-review/reviews`, and the marker/watcher/wait flow is
     identical. (The publish step in §3 re-reads the PR url from the scratch file's header, so
     nothing about the PR needs to be carried across turns.)
     PR-mode scratch files are **peer-review** mode (verify with
     `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-peer.sh mode "<doc>"` → `peer-review`); §3 uses the symmetric
     turn for them.

### Resolve the doc (local, deterministic)

- If `<positional>` is non-empty, that path is the doc.
- Else: list `.md` files **directly under** each dir in `MULTI_REVIEW_DOC_DIRS`
  (default `docs/specs docs/plans`) whose names match `YYYY-MM-DD-…`. Pick the greatest by
  **date prefix, then filename** (NOT mtime). If there are zero candidates, or the top two
  share a date prefix (a tie), STOP and ask the engineer to pass an explicit path.

## 1.5 Detect star mode (multi-secondary)

Before arming anything, determine whether this is a **star** review (one primary — you — plus
N independent secondaries) or the ordinary single-reviewer path below. This check MUST happen
before §2: §2's `multi-review-core.sh init` stamps an asymmetric round-1 marker onto any doc with
none yet, and that shape is wrong for star — running it first would corrupt the doc before star
ever gets a look.

1. **Resume check (the doc's own header, checked first):** run
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh mode "<doc>"`.
   - Prints `star` (exit 0) → `<doc>` is **already** a star review in flight from a prior
     invocation (its header carries `<!-- multi-review-mode: star -->`). Resuming without
     `--reviewers`/`MULTI_REVIEW_REVIEWERS` set must never silently fall back to the
     single-reviewer path below. Read the `reviewers: <ids>` suffix off that same header line
     and feed it straight back into `multi-review-star.sh resolve-set --reviewers <ids,comma,
     joined>` (same lookup as step 2 below, just doc-recorded input instead of the flag/env) to
     rebuild the `id|vendor|kind|model|has-skill` rows. Go to §1.6.
   - Exits 1 (no star hint in the header) → not yet star by the doc's own state; fall through
     to step 2.
2. **Fresh-request check:** run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh resolve-set`,
   appending `--reviewers <csv>` when §1 extracted the flag (omit it entirely otherwise, so
   `MULTI_REVIEW_REVIEWERS` applies).
   - **Exit 0** → a non-empty, resolved set — one `id|vendor|kind|model|has-skill` row per line.
     This is a **star** review. Resolve the set **once**, here, and carry these rows through the
     rest of the run (mirror §2.5's "resolve once" rule — do not call `resolve-set` again later
     in this invocation). Go to §1.6.
   - **Exit 3** → empty (no `--reviewers` flag and no `MULTI_REVIEW_REVIEWERS`). Not a star review
     — continue at §2 exactly as before; nothing in §1.6 applies to this run.
   - **Any other exit** (an unknown provider id named in the set) → report the message and
     STOP, same as an unknown `--reviewer` in §2.5.

## 1.6 Star mode — fan-out, primary turn, and terminal gate

You are the **primary** in a star review — the same author role as the rest of this command,
just responding to N independent secondaries instead of one. This section is self-contained:
once §1.5 sends you here, it owns arming, both marker states unique to star, and the terminal
gate for this doc. §2 through §4 do not apply for the rest of this run.

### Arm (idempotent)

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-egress-guard.sh "<doc>"`. Non-zero → report the
  message and STOP — do not arm. Star gets no pass on this hard gate; it applies exactly as
  in §2.
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh marker "<doc>"`.
  - **Succeeds** (a marker already exists) → this run is RESUMING a star review already armed.
    Do not re-arm. Go straight to "Branch on the marker" below, using the CURRENT state.
  - **Fails** (no marker yet) → fresh. Insert, right after the H1 (the same insertion point
    `multi-review-core.sh init` uses — but `init` only knows the asymmetric shape, round bound 10
    and state `awaiting-reviewer`, so star's own two-line header is inserted directly instead):

        <!-- multi-review: awaiting-secondaries · round 1/2 -->
        <!-- multi-review-mode: star · reviewers: <ids> -->

    `<ids>` is the resolved set's ids from §1.5, **space**-joined, in resolved order (e.g.
    `codex fable`). The round bound is **2** for star, always — a secondary never responds to
    another secondary's finding, so there is nothing to iterate beyond one primary pass per
    round.
  - **If `<doc>` has no `## Review` heading yet** (true the first time a fresh spec/plan doc
    enters star review), append one now, with nothing under it. `merge` (used below) appends
    namespaced findings after the LAST `## Review` heading in `<doc>` — a doc with none would
    silently lose every merged finding.
  - Tell the engineer: "star review armed on `<doc>` — secondaries: `<ids>`."

### Branch on the marker (star states only)

- **`awaiting-secondaries`** → run "Fan-out" below, then re-read the marker (now
  `awaiting-primary`) and continue directly into "Primary turn" in the same invocation — unlike
  the single-reviewer path, the primary IS this command, so there is no cross-session handoff
  to wait on between these two states.
- **`awaiting-primary`** → run "Primary turn" below.
- **`converged`** → go to "Terminal gate" below.
- **`exhausted`** → present the still-open findings
  (`${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh open-findings "<doc>"`) and tell the
  engineer: "round bound reached with findings still unaddressed — escalate to a human." STOP.
  (In practice this should not occur — star's convergence is coverage-based, so the primary can
  always converge once it has responded to every finding — but the state is honored
  defensively in case a doc was hand-edited into it.)

#### Fan-out (on `awaiting-secondaries`)

1. **Snapshot the baseline.** Copy `<doc>` to `<doc>.baseline`. In that COPY ONLY, truncate
   everything after the doc's LAST `## Review` heading — keep the heading line itself, drop
   every line after it (any prior round's merged findings/responses). `<doc>` itself is
   untouched by this step.
2. **Seed one copy per provider**, using the SAME resolved set from §1.5/Arm — round 2 (if it
   happens) does not shrink the set, even for a provider quarantined in round 1; it gets a
   fresh independent copy again. For each id: `cp "<doc>.baseline" "<doc>.<id>"`, then rewrite
   that copy's header to:

        <!-- multi-review: awaiting-reviewer · round <N>/2 -->
        <!-- multi-review-mode: star -->

   (`<N>` is the star round this fan-out is running; no `reviewers:` suffix here — that
   annotation belongs to `<doc>`, not the per-provider working copy.) The copy carries the
   empty `## Review` heading from step 1; the secondary appends its findings beneath it.
3. **Dispatch every secondary in the same turn**, so the harness runs them concurrently — never
   one after another. Branch on `kind` exactly as §3.5 step 3.c does, pointed at `<doc>.<id>`
   instead of `<doc>`: `codex` → the `codex:codex-rescue` agent with `--model <model> --write`;
   `fable` → `general-purpose` with `model: fable`; `gemini` → the §3.5 NUL-argv shell loop,
   launched as a background task so it does not block the rest of the batch. Both subagent
   dispatches (`codex`, `fable`) go in the SAME response block as each other.
4. **Bound the wait, per copy.**
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-wait.sh "<doc>.<id>" awaiting-author [seconds]`
   (its own 240s default is a reasonable bound; raise it for a known-slow provider). Exit 0 →
   proceed to verify below. Non-zero (bound hit, or the copy went sideways) → quarantine this
   provider (next step) with that reason. A hung secondary must never stall the others or the
   round.
5. **Verify identity, per copy that reached `awaiting-author`.**
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh verify-vendor --baseline
   "<doc>.baseline" "<doc>.<id>" --reviewer <id>`. Pass → admit the copy into the merge. Fail →
   quarantine: exclude it from the merge and record `--quarantined <id>:<reason>` (the reason
   is `verify-vendor`'s message, or "no response within the wait bound" from step 4).
   - **All secondaries quarantined** → an **anomaly stop**: do not advance the marker; surface
     every quarantine reason to the engineer and STOP. A round with zero trustworthy findings
     cannot merge.
6. **Merge.** `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh merge --round <N> [--quarantined
   <id>:<reason> ...] "<doc>" <admitted copies...>` (`<N>` is the round number this marker
   currently names — 1 or 2).
7. **Flip the marker.** Edit `<doc>`'s marker from `awaiting-secondaries` to `awaiting-primary`,
   same round number — your final edit of this step. (`core.sh next-marker` only knows the
   asymmetric `author-done` event; this transition, like a secondary's own hand-back, is a
   direct edit, not a helper call.) Retain `<doc>.<id>` for every provider, `<doc>.manifest`,
   and `<doc>.baseline` — do not delete them yet. The terminal gate is what releases them.

#### Primary turn (on `awaiting-primary`)

1. List the merged findings awaiting a response:
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh open-findings "<doc>"`.
2. For each, append **exactly one** of:
   - `> [agree:<ns-id>]` + `> — via <primary-model-id>` — accept it, and address it in the doc
     body, or
   - `> [dispute:<ns-id>] <one-line reason>` + `> — via <primary-model-id>` — reject it,
     tersely.
   Never the asymmetric `> [author: resolved:<id>]` — star's `check-converged` does not
   recognize that form and would never see coverage as complete.

   Caution: `<primary-model-id>` must differ from every secondary's disclosed `> — via` model
   id — the self-response guard fails a response whose model equals the finding's raiser model,
   so colliding with a secondary (e.g. a Claude-family secondary like `fable`) would make
   convergence impossible.
3. Decide: **converge**, or — **at most once, and only when the current round is < 2** —
   re-enter `awaiting-secondaries` for a second round (e.g. because addressing round 1's
   findings changed the doc body enough to warrant a fresh independent pass). At round 2 this
   choice is not available — converge; the round bound forces terminal. Edit the marker
   directly:
   - **Converge** → state word only: `awaiting-primary` → `converged` (same round number).
   - **Round 2** → state AND round: `awaiting-primary · round 1/2` → `awaiting-secondaries ·
     round 2/2`, then return to "Fan-out" above.

### Terminal gate

Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh check-converged "<doc>"`.

- **Pass** → present `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-star.sh gate-summary "<doc>"
  "<primary-model-id>"` to the engineer and STOP — same human-gate discipline as §4: never
  implement, commit, or open a PR from this command. Only once the engineer confirms the
  review is done, remove the retained working files (`<doc>.<id>` for every provider,
  `<doc>.manifest`, `<doc>.baseline`) — never before the gate, since the gate is presented FROM
  them (`check-converged`/`gate-summary` read the manifest).
- **Fail** → the marker says `converged` but the contract doesn't hold (e.g. a hand-edit broke
  coverage, or tampered with a quarantine record) — pause, surface the inconsistency, and STOP.
  Do not clean up the working files; they are what a human needs to diagnose the mismatch.

## 2. Arm

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-egress-guard.sh "<doc>"`. If it exits non-zero, report the message
  and STOP — do not arm.
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh init "<doc>" "${MULTI_REVIEW_MAX_ROUNDS:-10}"`. If it exits
  non-zero, report the message and STOP.
- `init` is idempotent, so you may be RESUMING a review already in flight. Read the marker
  (`${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh marker "<doc>"`) and branch:
  - **`awaiting-reviewer`** → resolve the doc's canonical ABSOLUTE path
    (`"$(cd "$(dirname "<doc>")" && pwd -P)/$(basename "<doc>")"`) and tell the engineer:
    "author mode armed on `<abs-path>` — give your reviewer exactly this path." The
    absolute path is the rendezvous: a relative path breaks when the reviewer's session
    opens in a different checkout (worktree siblings carry same-named docs).
    - **Route not yet resolved this run** (the first time §2 is reached this invocation) →
      **STOP — do NOT arm yet.** Go to §2.5 first to resolve the route. Only carry out the arm-the-watcher
      steps below (arm, then verify) if §2.5's attended state sends you back here; the default
      unattended route (§3.5) never reaches this arming step at all.
    - **Route already resolved this run** (this is a re-arm requested by §3, already
      committed to the attended route for this invocation) → carry out the arm-the-watcher
      steps below directly; do not revisit §2.5 or re-resolve — that would contradict
      "resolve once, carry it through" (§2.5).
  - **`awaiting-author`** → it is already your move: handle it NOW via §3. Do NOT arm a
    watcher first — waiting on a doc the reviewer will never edit again deadlocks the loop.
  - **`converged` / `exhausted`** → it is already terminal: handle it NOW via §4 (which
    branches exactly as §3's `converged`/`exhausted` bullets, and also prints the
    independence notice — a resume that lands directly on a terminal state must not skip it).
    Do NOT arm a watcher first.
- To arm (**arm, then verify — always in this order**): pick a random token (e.g.
  `dar-$RANDOM$RANDOM`). Launch the watcher as a **background Bash task**:
  `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-watch.sh "<doc>" "<token>"`. Then, BEFORE stopping your turn,
  re-read the marker: edits landing between a previous watcher's exit and this one's
  baseline are invisible to it, so a reviewer hand-back that arrived while you were
  processing would otherwise never wake you. If the re-read still says
  `awaiting-reviewer`, stop your turn and wait to be re-woken when the task exits.
  Otherwise stop the watcher task and handle the new state NOW: `awaiting-author` via §3;
  `converged`/`exhausted` via §4, so the independence notice is printed on this path too.

## 2.5 Resolve the route (autonomous by default)

**Step 1 runs on every path.** Both routes need the resolved row — the attended state passes its
`id` to `prompt` — so resolve first, then branch:

1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh resolve`, appending
   `--reviewer <flag-id>` when §1 extracted a `--reviewer` flag (omit the flag entirely
   otherwise, so the env var/default applies) → `id|vendor|kind|model|has-skill`. A non-zero
   exit means an unknown provider — report it and STOP.
2. **If §1 extracted `--attended`**, skip the check and go straight to the attended state
   below, carrying the row from step 1. Otherwise this command drives the review
   **unattended**: run
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh check --reviewer <id>` (the row's
   resolved `id` from step 1, not the raw flag).
   - **exit 0** → run the unattended loop in §3.5.
   - **non-zero** → announce the reason verbatim, then degrade to the attended state below.
     Never degrade silently.

**Degradation message** (print the `check` reason, then this):

    <reason> — falling back to manual handoff. For zero-dependency autonomous review, set
    MULTI_REVIEW_REVIEWER=fable (same-vendor; see independence tiers in the README).

**Attended state** (also what the `--attended` flag extracted in §1 selects directly): emit
the reviewer prompt with
`${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh prompt "<doc>" --reviewer <id>` (the
row's resolved `id` from step 1), print the canonical absolute doc path, then **return to
§2's `awaiting-reviewer` branch and carry out its arm-the-watcher steps now** — that is the
deliberate hand-back §2's deferral sent you here to receive, not a fresh path to improvise.
This is the pre-existing `/multi-review` behavior, with the prompt already prepared for the
chosen provider. There is no second fallback tier.

The **provider never changes on its own** — only the route degrades. If the engineer wants a
different reviewer they set `MULTI_REVIEW_REVIEWER` or pass `--reviewer` (§1); the tool will not
silently substitute one.

**Resolve once, carry it through.** The row produced by step 1 is fixed for the entire run —
§3.5 reuses it and never re-resolves. Provider selection is therefore read exactly once, at a
point where the choice is announced, rather than re-read each round where a mutable env var
could swap reviewers mid-review without anyone noticing. Switching provider means ending the
run and re-invoking the command.

## 3. On each wake — branch on the marker ONLY

Read it with `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh marker "<doc>"`:

- **`awaiting-reviewer`** → not your turn (the reviewer may be mid-edit). Do nothing; re-arm
  per §2 (new token, arm-then-verify) and wait again. The verify step is what catches a
  hand-back that landed while you were waking up — this premature-wake path is exactly
  where the race lives.
- **`awaiting-author`** → re-read the doc IN FULL. Determine mode:
  `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-peer.sh mode "<doc>"`.
  - **`asymmetric`** (local doc) — as before: `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh open-threads "<doc>"`;
    for each open id append `> [author: resolved:<id>] <how>` + `> — via <model>`; then
    `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh next-marker "<doc>" author-done`; re-arm per §2.
  - **`peer-review`** (PR) — you are a **peer reviewer**, not an author:
    1. `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-peer.sh open-findings "<doc>"` lists the other agent's findings
       awaiting your response (a hard error means a malformed doc — pause and surface).
    2. For each open finding, append a response in the `## Review` section: `> [concur:<id>]`
       or `> [dispute:<id>] <why>`, each followed by `> — via <your-model-id>`.
    3. Add any new findings of your own: `> [finding:<new-id>|<sev>] <concern>` + `> — via
       <your-model-id>` + `> — risk: <short risk>` (unique ids; `<sev>` ∈ high/med/low; one terse
       line for the concern, one clause for the risk).
       You MAY anchor a finding to a specific changed line by adding, immediately after its
       `> — risk:` line, a `> — at <path>:<line>` (or `<path>:<start>-<end>`) line using
       RIGHT-side new-file line numbers from the `## Diff`. Optional; omit if unsure.
    4. Optionally `> [withdraw:<id>]` + `> — via <your-model-id>` for your own findings.
    5. `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh next-marker "<doc>" author-done`; re-arm per §2.
- **`converged`** → determine mode: `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-peer.sh mode "<doc>"`, then run the
  matching convergence check (run only that one — not both):
  - **`asymmetric`** (local doc) → run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh check-converged "<doc>"`. If
    it passes, present the annotated doc + a round summary and tell the engineer "converged —
    please review and approve before implementation or PR." If it fails, pause and surface the
    inconsistency. Do NOT relaunch the watcher. STOP.
  - **`peer-review`** (PR) → run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-peer.sh check-converged "<doc>"`. If it
    passes, present the annotated doc + a round summary; tell the engineer it converged and ask
    whether to post. Only on explicit approval, run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh publish "<doc>"
    "<your-model-id>"` (publish auto-selects the peer compose and reads the PR url from the
    scratch header). If it fails, pause and surface the inconsistency. Do NOT relaunch the
    watcher. STOP.
- **`exhausted`** → present the trail and tell the engineer: "round bound reached without
  convergence — escalate to a human." In **PR mode**, you may additionally offer to post the
  annotated review to the PR (the summary makes the still-open concerns explicit); only on
  explicit approval, run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-pr.sh publish "<doc>" "<your-model-id>"`
  (one neutral `--comment` review). Do NOT relaunch the watcher. STOP.

## 3.5 The unattended loop

Repeat until `multi-review-auto-step.sh` returns `terminal` or `stop`:

1. Record `prev_state`/`prev_round` from `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh marker "<doc>"`.
2. **`awaiting-author`** → take the author turn exactly as §3 prescribes for the doc's mode,
   stopping before its `next-marker` and re-arm steps (§3's `awaiting-author` branch ends with
   both; skip them there — running `next-marker` twice dies loudly, and re-arming a watcher
   inside this loop would stall it), then here run
   `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-core.sh next-marker "<doc>" author-done`.
3. **`awaiting-reviewer`** → dispatch one reviewer turn:
   a. **Snapshot first:** `cp "<doc>" "<doc>.baseline"`. This must happen *immediately* before
      dispatch — it is what scopes the identity check to this turn alone.
   b. Use the `id|vendor|kind|model|has-skill` row **resolved once in §2.5**. Do **not** call
      `resolve` again inside the loop: re-resolving each round would make the active reviewer
      depend on mutable environment state, so an env change mid-run could silently swap
      providers between rounds — the exact silent substitution §2.5 forbids. It would also
      desynchronise `verify-vendor`, which judges a turn against "the resolved provider".
      A deliberate provider change is made by ending this run and re-invoking the command,
      which re-resolves at §2.5 and states the choice; it is never a mid-loop mutation.
   c. Branch on `kind`:
      - **`subagent`** → dispatch the Agent tool with the resolved `model`, passing the output
        of `multi-review-reviewer.sh prompt "<doc>" --reviewer <id>` as the task text. For
        `codex` use the `codex:codex-rescue` agent with `--model <model> --write`; for `fable`
        use `general-purpose` with `model: fable`. The `--model`/`--write` flags are runtime
        controls, stripped from the task text — never part of the payload.
      - **`shell`** → read NUL-delimited argv and execute it without a shell round-trip:

            argv=()
            while IFS= read -r -d '' a; do argv+=("$a"); done \
              < <("${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh" command "<doc>" --reviewer <id>)
            "${argv[@]}"

        Use this exact loop, not `mapfile` — macOS ships bash 3.2, which has no `mapfile`.
   d. **Verify identity BEFORE validating transitions:**
      `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh verify-vendor --baseline "<doc>.baseline" "<doc>" --reviewer <id>`.
      Non-zero → **anomaly stop**: the model that ran was not the one selected, so the round's
      output cannot be trusted. Remove the snapshot (`rm -f "<doc>.baseline"`) — it has served
      its purpose and STOP is exiting the loop — then surface it and STOP. Do not retry, do not
      re-dispatch.
   e. Remove the snapshot: `rm -f "<doc>.baseline"`.
4. Run `${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-auto-step.sh "<doc>" "<prev_state>" "<prev_round>"`:
   `continue` (0) → loop; `terminal` (10) → §4; `stop` (20) → an **anomaly stop** — surface
   `auto-step`'s `stop <reason>` and the partial round trail to the engineer, same as 3.d
   above (including the same snapshot cleanup, if one is still present). Do not retry, do not
   re-dispatch, do not edit the marker.

A **dispatch failure** (the agent/CLI could not be invoked at all) is a *degradation trigger*,
not an anomaly stop: remove the snapshot taken in step a (`rm -f "<doc>.baseline"` — there was
no turn for it to scope), announce the failure, and drop to the attended state from §2.5.
Anomaly stops are reserved for a turn that ran but cannot be trusted — an identity mismatch —
or for protocol violations detected by `auto-step`.

An **anomaly stop is not a human gate** and does not run §4: the marker is neither `converged`
nor `exhausted`, so do not print the independence notice — a vendor-identity claim would be
misleading for a turn whose identity is exactly what's in question. Surface the raw reason and
the partial round trail instead.

## 4. Terminal — human gate

Branch on the marker exactly as §3's `converged` and `exhausted` branches prescribe — same
convergence checks (`core.sh check-converged` for `asymmetric`, `peer.sh check-converged` for
`peer-review`), same presentation, and same PR-mode publish offer (`multi-review-pr.sh publish`,
gated on explicit engineer approval, for both `converged` and `exhausted`). §4 adds nothing to
that branching; it only adds the notice below, printed in **both** terminal states. In both
cases, before handing back to the engineer, print the independence notice beside the round
summary:

    ${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh notice "<your-model-id>" --reviewer <id>

It prints one line when author and reviewer share a vendor, an explicit *unverified* line if
the author id cannot be mapped, and nothing when they are genuinely cross-vendor — so silence
means "checked and cross-vendor", never "not checked".

STOP at the gate. Never implement, commit, or open a PR from this command.

## Guardrails

- §3 applies only when the watcher exited **0** (a doc change). Non-zero is NOT a wake:
  exit 4 means a newer watcher took over this doc — this session's review is superseded,
  STOP and do not relaunch; 130/143 mean it was killed — stop unless the engineer says
  otherwise.
- Turn-taking is the marker only — never act on "new text appeared" while it says
  `awaiting-reviewer`.
- If the marker is missing/corrupt, or the doc changed while it said `awaiting-author`
  (a turn violation), pause and surface — do not race-edit.
- Disclosure warnings on stderr are non-blocking; surface them at the gate but keep going.
- Star mode (§1.6) does not use the watcher/lock pattern above — its two marker states
  (`awaiting-secondaries`/`awaiting-primary`) are driven synchronously within one invocation,
  since the primary is this command itself and the fan-out uses its own bounded wait
  (`multi-review-wait.sh`) per copy instead.
