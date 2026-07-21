---
description: Author-mode dual-agent review — watch a spec/plan doc and converge with an external reviewer, ending at a human gate.
argument-hint: "[doc-path | PR-URL]"
---

You are the **author** in a dual-agent review. Drive it with the repo's shell helpers; you
own prose edits, the helpers own the marker. Never advance past the human gate.

## 0. Classify the argument (doc path vs. PR)

Run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-pr.sh parse "$ARGUMENTS"`.

- **Exit non-zero** (not a PR ref) → this is a local doc. Continue at §1 unchanged.
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

## 1. Resolve the doc (deterministic)

- If `$ARGUMENTS` is non-empty, that path is the doc.
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
    opens in a different checkout (worktree siblings carry same-named docs). **STOP — do
    NOT arm yet.** Go to §2.5 first to resolve the route. Only carry out the arm-the-watcher
    steps below (arm, then verify) if §2.5's attended state sends you back here; the default
    unattended route (§3.5) never reaches this arming step at all.
  - **anything else** (`awaiting-author`, `converged`, `exhausted`) → it is already your move:
    handle it NOW via §3. Do NOT arm a watcher first — waiting on a doc the reviewer will
    never edit again deadlocks the loop.
- To arm (**arm, then verify — always in this order**): pick a random token (e.g.
  `dar-$RANDOM$RANDOM`). Launch the watcher as a **background Bash task**:
  `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-watch.sh "<doc>" "<token>"`. Then, BEFORE stopping your turn,
  re-read the marker: edits landing between a previous watcher's exit and this one's
  baseline are invisible to it, so a reviewer hand-back that arrived while you were
  processing would otherwise never wake you. If the re-read still says
  `awaiting-reviewer`, stop your turn and wait to be re-woken when the task exits.
  Otherwise stop the watcher task and handle the new state via §3 NOW.

## 2.5 Resolve the route (autonomous by default)

Unless the engineer passed `--attended`, this command drives the review **unattended**:

1. `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-reviewer.sh resolve` → `id|vendor|kind|model|has-skill`.
   A non-zero exit means an unknown provider — report it and STOP.
2. `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-reviewer.sh check --reviewer <id>`.
   - **exit 0** → run the unattended loop in §3.5.
   - **non-zero** → announce the reason verbatim, then degrade to the attended state below.
     Never degrade silently.

**Degradation message** (print the `check` reason, then this):

    <reason> — falling back to manual handoff. For zero-dependency autonomous review, set
    DUAL_AGENT_REVIEWER=fable (same-vendor; see independence tiers in the README).

**Attended state** (also what `--attended` selects directly): emit the reviewer prompt with
`${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-reviewer.sh prompt "<doc>" --reviewer <id>`, print the canonical
absolute doc path, then **return to §2's `awaiting-reviewer` branch and carry out its
arm-the-watcher steps now** — that is the deliberate hand-back §2's deferral sent you here to
receive, not a fresh path to improvise. This is the pre-existing `/dual-review`
behavior, with the prompt already prepared for the chosen provider. There is no second
fallback tier.

The **provider never changes on its own** — only the route degrades. If the engineer wants a
different reviewer they set `DUAL_AGENT_REVIEWER` or pass `--reviewer`; the tool will not
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
