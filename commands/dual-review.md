---
description: Author-mode dual-agent review — watch a spec/plan doc and converge with an external reviewer, ending at a human gate.
argument-hint: "[doc-path | PR-URL] [--reviewer <id>] [--attended]"
---

You are the **author** in a dual-agent review. Drive it with the repo's shell helpers; you
own prose edits, the helpers own the marker. Never advance past the human gate.

## 1. Resolve the argument

**Split first.** `$ARGUMENTS` may carry `--reviewer <id>` and/or `--attended` in addition to
the doc path or PR ref, in any order, before or after the positional. Extract them:

- `--reviewer <id>` — per-invocation reviewer override, consumed in §2.5.
- `--attended` — selects the attended route directly, consumed in §2.5.

Everything else is `<positional>` (empty if `$ARGUMENTS` was flags only, or absent entirely).
Classification and doc resolution below use `<positional>` only — never the raw
`$ARGUMENTS` — so a trailing `--reviewer <id>` can never corrupt PR-ref matching or become
part of a doc path.

### Classify (doc path vs. PR)

Run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-pr.sh parse "<positional>"`.

- **Exit non-zero** (not a PR ref) → this is a local doc. Continue at "Resolve the doc" below.
- **Exit 0** → it printed `owner|repo|number` (owner/repo empty for the bare `#n` form). This
  is **PR mode**:
  1. If owner/repo are empty, fill them: `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-pr.sh resolve-repo` →
     `owner|repo` for the current repo. If it fails, report and STOP.
  2. Compute the scratch path:
     `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-pr.sh scratch-path "<owner>" "<repo>" "<number>"`.
  3. **Resume vs. fresh (r1) — re-ingest ONLY when the scratch file is absent.** Re-ingesting
     rewrites the file via `seed` and would erase accumulated reviewer/author threads, so:
       - **Scratch file does not exist** → `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-pr.sh ingest "<owner>"
         "<repo>" "<number>"` (fetches via `gh`, writes the file, prints its path). On `gh`
         failure (unauthenticated, PR not found), report and STOP.
       - **Exists with a non-terminal marker** (`awaiting-reviewer`/`awaiting-author`, via
         `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh marker "<scratch>"`) → **resume**: do NOT ingest. Go
         straight to Arm; `init` is idempotent and preserves the existing threads. (`ingest`
         also refuses to clobber without `--fresh`, as a backstop.)
       - **Exists with a terminal marker** (`converged`/`exhausted`) → surface it and ask the
         engineer: resume reading it (skip ingest), or start fresh. Only if they choose fresh,
         run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-pr.sh ingest --fresh "<owner>" "<repo>" "<number>"`.
  4. Set `<doc>` to the scratch path and proceed to §2 (Arm) exactly as for a local doc — the
     egress guard already allows `.dual-agent/reviews`, and the marker/watcher/wait flow is
     identical. (The publish step in §3 re-reads the PR url from the scratch file's header, so
     nothing about the PR needs to be carried across turns.)
     PR-mode scratch files are **peer-review** mode (verify with
     `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-peer.sh mode "<doc>"` → `peer-review`); §3 uses the symmetric
     turn for them.

### Resolve the doc (local, deterministic)

- If `<positional>` is non-empty, that path is the doc.
- Else: list `.md` files **directly under** each dir in `DUAL_AGENT_DOC_DIRS`
  (default `docs/specs docs/plans`) whose names match `YYYY-MM-DD-…`. Pick the greatest by
  **date prefix, then filename** (NOT mtime). If there are zero candidates, or the top two
  share a date prefix (a tie), STOP and ask the engineer to pass an explicit path.

## 2. Arm

- Run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-egress-guard.sh "<doc>"`. If it exits non-zero, report the message
  and STOP — do not arm.
- Run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh init "<doc>" "${DUAL_AGENT_MAX_ROUNDS:-10}"`. If it exits
  non-zero, report the message and STOP.
- `init` is idempotent, so you may be RESUMING a review already in flight. Read the marker
  (`${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh marker "<doc>"`) and branch:
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
  `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-watch.sh "<doc>" "<token>"`. Then, BEFORE stopping your turn,
  re-read the marker: edits landing between a previous watcher's exit and this one's
  baseline are invisible to it, so a reviewer hand-back that arrived while you were
  processing would otherwise never wake you. If the re-read still says
  `awaiting-reviewer`, stop your turn and wait to be re-woken when the task exits.
  Otherwise stop the watcher task and handle the new state via §3 NOW.

## 2.5 Resolve the route (autonomous by default)

Unless `--attended` was extracted in §1, this command drives the review **unattended**:

1. Run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-reviewer.sh resolve`, appending
   `--reviewer <flag-id>` when §1 extracted a `--reviewer` flag (omit the flag entirely
   otherwise, so the env var/default applies) → `id|vendor|kind|model|has-skill`. A non-zero
   exit means an unknown provider — report it and STOP.
2. `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-reviewer.sh check --reviewer <id>` (the row's
   resolved `id` from step 1, not the raw flag).
   - **exit 0** → run the unattended loop in §3.5.
   - **non-zero** → announce the reason verbatim, then degrade to the attended state below.
     Never degrade silently.

**Degradation message** (print the `check` reason, then this):

    <reason> — falling back to manual handoff. For zero-dependency autonomous review, set
    DUAL_AGENT_REVIEWER=fable (same-vendor; see independence tiers in the README).

**Attended state** (also what the `--attended` flag extracted in §1 selects directly): emit
the reviewer prompt with
`${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-reviewer.sh prompt "<doc>" --reviewer <id>` (the
row's resolved `id` from step 1), print the canonical absolute doc path, then **return to
§2's `awaiting-reviewer` branch and carry out its arm-the-watcher steps now** — that is the
deliberate hand-back §2's deferral sent you here to receive, not a fresh path to improvise.
This is the pre-existing `/dual-review` behavior, with the prompt already prepared for the
chosen provider. There is no second fallback tier.

The **provider never changes on its own** — only the route degrades. If the engineer wants a
different reviewer they set `DUAL_AGENT_REVIEWER` or pass `--reviewer` (§1); the tool will not
silently substitute one.

**Resolve once, carry it through.** The row produced by step 1 is fixed for the entire run —
§3.5 reuses it and never re-resolves. Provider selection is therefore read exactly once, at a
point where the choice is announced, rather than re-read each round where a mutable env var
could swap reviewers mid-review without anyone noticing. Switching provider means ending the
run and re-invoking the command.

## 3. On each wake — branch on the marker ONLY

Read it with `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh marker "<doc>"`:

- **`awaiting-reviewer`** → not your turn (the reviewer may be mid-edit). Do nothing; re-arm
  per §2 (new token, arm-then-verify) and wait again. The verify step is what catches a
  hand-back that landed while you were waking up — this premature-wake path is exactly
  where the race lives.
- **`awaiting-author`** → re-read the doc IN FULL. Determine mode:
  `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-peer.sh mode "<doc>"`.
  - **`asymmetric`** (local doc) — as before: `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh open-threads "<doc>"`;
    for each open id append `> [author: resolved:<id>] <how>` + `> — via <model>`; then
    `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh next-marker "<doc>" author-done`; re-arm per §2.
  - **`peer-review`** (PR) — you are a **peer reviewer**, not an author:
    1. `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-peer.sh open-findings "<doc>"` lists the other agent's findings
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
    5. `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh next-marker "<doc>" author-done`; re-arm per §2.
- **`converged`** → determine mode: `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-peer.sh mode "<doc>"`, then run the
  matching convergence check (run only that one — not both):
  - **`asymmetric`** (local doc) → run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh check-converged "<doc>"`. If
    it passes, present the annotated doc + a round summary and tell the engineer "converged —
    please review and approve before implementation or PR." If it fails, pause and surface the
    inconsistency. Do NOT relaunch the watcher. STOP.
  - **`peer-review`** (PR) → run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-peer.sh check-converged "<doc>"`. If it
    passes, present the annotated doc + a round summary; tell the engineer it converged and ask
    whether to post. Only on explicit approval, run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-pr.sh publish "<doc>"
    "<your-model-id>"` (publish auto-selects the peer compose and reads the PR url from the
    scratch header). If it fails, pause and surface the inconsistency. Do NOT relaunch the
    watcher. STOP.
- **`exhausted`** → present the trail and tell the engineer: "round bound reached without
  convergence — escalate to a human." In **PR mode**, you may additionally offer to post the
  annotated review to the PR (the summary makes the still-open concerns explicit); only on
  explicit approval, run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-pr.sh publish "<doc>" "<your-model-id>"`
  (one neutral `--comment` review). Do NOT relaunch the watcher. STOP.

## 3.5 The unattended loop

Repeat until `dual-agent-auto-step.sh` returns `terminal` or `stop`:

1. Record `prev_state`/`prev_round` from `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh marker "<doc>"`.
2. **`awaiting-author`** → take the author turn exactly as §3 prescribes for the doc's mode,
   stopping before its `next-marker` and re-arm steps (§3's `awaiting-author` branch ends with
   both; skip them there — running `next-marker` twice dies loudly, and re-arming a watcher
   inside this loop would stall it), then here run
   `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh next-marker "<doc>" author-done`.
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
        of `dual-agent-reviewer.sh prompt "<doc>" --reviewer <id>` as the task text. For
        `codex` use the `codex:codex-rescue` agent with `--model <model> --write`; for `fable`
        use `general-purpose` with `model: fable`. The `--model`/`--write` flags are runtime
        controls, stripped from the task text — never part of the payload.
      - **`shell`** → read NUL-delimited argv and execute it without a shell round-trip:

            argv=()
            while IFS= read -r -d '' a; do argv+=("$a"); done \
              < <("${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-reviewer.sh" command "<doc>" --reviewer <id>)
            "${argv[@]}"

        Use this exact loop, not `mapfile` — macOS ships bash 3.2, which has no `mapfile`.
   d. **Verify identity BEFORE validating transitions:**
      `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-reviewer.sh verify-vendor --baseline "<doc>.baseline" "<doc>" --reviewer <id>`.
      Non-zero → **anomaly stop**: the model that ran was not the one selected, so the round's
      output cannot be trusted. Remove the snapshot (`rm -f "<doc>.baseline"`) — it has served
      its purpose and STOP is exiting the loop — then surface it and STOP. Do not retry, do not
      re-dispatch.
   e. Remove the snapshot: `rm -f "<doc>.baseline"`.
4. Run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-auto-step.sh "<doc>" "<prev_state>" "<prev_round>"`:
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
`peer-review`), same presentation, and same PR-mode publish offer (`dual-agent-pr.sh publish`,
gated on explicit engineer approval, for both `converged` and `exhausted`). §4 adds nothing to
that branching; it only adds the notice below, printed in **both** terminal states. In both
cases, before handing back to the engineer, print the independence notice beside the round
summary:

    ${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-reviewer.sh notice "<your-model-id>" --reviewer <id>

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
