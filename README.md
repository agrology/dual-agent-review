# dual-agent-review

<p align="center">
  <img src="docs/dual-agents-meme.png" alt="The three-Spider-Men-pointing meme: author agent, reviewer agent, and the human gate all pointing at each other" width="480">
  <br>
  <em>Author agent, reviewer agent, human gate — everyone double-checking everyone.</em>
</p>

An **opt-in, human-gated** protocol where Claude authors a design doc and an external
reviewer iterates with it to convergence — always ending at a **human approval gate**.

## Install

As a Claude Code plugin:

    /plugin install agrology/dual-agent-review

This installs the `/dual-review` and `/dual-review-auto` slash commands and their supporting
scripts. It does **not** install the reviewer side — see "Reviewer setup" below.

## Reviewer setup (BYO-Codex)

The reviewer agent is a separate tool you bring yourself; it does **not** appear automatically
on plugin install. You need:

- the `codex` CLI, authenticated, with a model available to it
- the self-contained reviewer skill copied into your target repo at
  `<your-repo>/.agents/skills/dual-review/` — this fixed, repo-root-relative location is what
  the skill's bundled helper/protocol paths resolve against, so the path must be exact

Copy the skill directory from this repo (`.agents/skills/dual-review/`) into your repo at the
same relative path, then run Codex **from your repo's root** so the bundled paths resolve.
See "Usage (file-coordination)" below for how the two sides then converge.

## Layout

- `docs/dual-agent-review.md` — the protocol contract
- `commands/dual-review.md` — the `/dual-review` author-mode command
- `commands/dual-review-auto.md` — the `/dual-review-auto` autonomous command
- `.claude-plugin/plugin.json` — the Claude Code plugin manifest
- `.agents/skills/dual-review/` — the self-contained `/dual-review` Codex/GPT reviewer skill
  (bundled copies of the protocol doc + reviewer scripts; not installed by the plugin — see
  "Reviewer setup" above)
- `CLAUDE.md` / `AGENTS.md` — this repo's own engineering working agreement, including the
  author/reviewer dual-agent protocol pointer (§11)
- `scripts/dual-agent-egress-guard.sh` — path/egress validation helper
- `scripts/dual-agent-core.sh` — deterministic marker/thread logic
- `scripts/dual-agent-watch.sh` — mtime watcher (backgrounded, wakes the author agent)
- `scripts/dual-agent-wait.sh` — lock-free bounded marker wait (reviewer-side resume)
- `scripts/dual-agent-pr.sh` — PR-URL mode: ingest a GitHub PR into a local scratch file, then publish the converged review
- `scripts/dual-agent-peer.sh` — symmetric peer-review grammar (mode detect, open-findings, convergence) for PR-mode docs
- `scripts/dual-agent-codex-prompt.sh` — optional: emits the `/codex:rescue` reviewer prompt for the Codex-plugin route
- `scripts/dual-agent-auto-step.sh` — per-round verdict (continue/terminal/stop) for the autonomous loop
- `scripts/dual-agent-build-reviewer-bundle.sh` — regenerates the bundled reviewer skill from the canonical sources
- `scripts/dual-agent-history-check.sh` — scans the full git history for internal/sensitive terms; the pre-publish safety gate (see `PUBLISHING.md`)
- `PUBLISHING.md` — how to take a fork/clone of this repo public safely (fresh-history export or history scrub)

## Usage (file-coordination)

> **Paths in the examples below** (`scripts/…`, `docs/specs/…`) assume you have this repo
> cloned. Installed as a **plugin**, you don't run the scripts yourself — the `/dual-review`
> commands resolve their own bundled scripts via `${CLAUDE_PLUGIN_ROOT}` for you; you just run
> the slash command and copy the reviewer skill into your repo per **Reviewer setup** above.

In your Claude session:

    /dual-review docs/specs/2026-06-09-my-feature.md

Claude arms author mode (inserts the status marker, starts a watcher) and waits. In a second
Codex/GPT session rooted in **your** repo (with the reviewer skill installed per **Reviewer
setup** above), run:

    /dual-review docs/specs/2026-06-09-my-feature.md

The two converge through the file; Claude stops at a **human approval gate**.
For non-Codex reviewer agents, `AGENTS.md` still points them at the same protocol.

- **Config:** `DUAL_AGENT_DOC_DIRS` (default `docs/specs docs/plans`),
  `DUAL_AGENT_MAX_ROUNDS` (default `10`). The dir list is space-separated, so individual
  dirs must not contain spaces (the relative defaults are safe even in a repo whose absolute
  path has them).
- **Egress:** the command refuses to arm on any path outside `DUAL_AGENT_DOC_DIRS`, a symlink,
  or a `../` escape. The reviewer reading only the doc is a trusted-reviewer protocol
  requirement (see `docs/dual-agent-review.md`).
- **Liveness:** there is no reviewer timeout — if the reviewer agent dies mid-turn, the
  author just keeps waiting; interrupt Claude in the terminal.
- **Worktrees:** the doc's absolute path is the rendezvous. When arming from a git
  worktree, relay the absolute path Claude announces to the reviewer verbatim. Keep
  review worktrees under a sandbox-readable root (e.g. `.claude/worktrees/...`) — or
  start the reviewer session inside the worktree itself — so the reviewer can reach the
  doc. Avoid committing an armed review marker unless the branch/worktree identity is
  unambiguous: a stale committed marker in a sibling checkout looks like a second live
  doc to a fresh reviewer (the skill stops on that ambiguity rather than guessing).
- **Pacing:** the author wakes automatically (watcher); the reviewer self-resumes by
  looping `scripts/dual-agent-wait.sh` between rounds (the skill's default — exit 9 just
  means "run it again"). Re-invoke `/dual-review <doc>` manually only if the reviewer's
  harness can't keep waiting. An author that wakes while the marker still says
  `awaiting-reviewer` is benign: the reviewer's mid-edit saves trip the watcher, and the
  marker check makes the author re-arm.

## Usage (PR review)

Point the author at a PR instead of a local doc:

    /dual-review https://github.com/<owner>/<repo>/pull/<n>

(Also accepts `<owner>/<repo>#<n>` and, for the current repo, `#<n>`.) The author fetches the
PR's description + diff via `gh` into a gitignored scratch file
`.dual-agent/reviews/<owner>/<repo>/pr-<n>.md`, then the **same** marker/watcher/wait flow
converges with your reviewer on that local file. The reviewer never touches GitHub. On
convergence the author stops at the human gate; only on your approval does it post **one
neutral** `gh pr review --comment` back to the PR. Agreed findings that carry a
`> — at <path>:<line>` anchor (RIGHT-side new-file line numbers) post as GitHub inline
comments inside that single review; everything else — open, dissented, and un-anchorable
findings — stays in the top-level summary. Requires `gh` and `jq` authenticated with access
to the PR.

## Optional: drive the reviewer via the Codex plugin

By default the reviewer is a **separate Codex/GPT session** you open yourself (the two-session
flow above). If you have OpenAI's [`codex-plugin-cc`](https://github.com/openai/codex-plugin-cc)
installed in Claude Code — with the local Codex CLI authenticated — you can instead **summon the
reviewer from the author's machine**, skipping the second session and the window-switching.

This changes only *how the reviewer is invoked*, never *what the review is*. Codex runs its own
`/dual-review` reviewer skill in its **own context** — so reviewer independence (a different
model family, separate reasoning) and the **human approval gate** are intact, and the
file-coordination protocol remains the source of truth.

**Manual vs plugin is not a setting — it's a per-turn choice.** There is no flag or marker that
selects between them; the author side keys only on the marker and cannot tell which transport
produced a reviewer turn. To use the manual route, open a separate session and run `/dual-review
<doc>`; to use the plugin, run the helper below and hand its prompt to `/codex:rescue`. You may
even switch between them across rounds on the same doc — the marker and threads are the only
state. (Distinct from the `asymmetric` vs `peer-review` *mode* reported by
`scripts/dual-agent-peer.sh mode`, which the doc itself selects — see "Peer review" in
`docs/dual-agent-review.md`.)

From the armed author session, get the canonical reviewer prompt and hand it to the plugin
(the author runs this in its plugin context, where `${CLAUDE_PLUGIN_ROOT}` is set; from a plain
clone, use the bare `scripts/…` path instead):

    ${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-codex-prompt.sh docs/specs/2026-06-09-my-feature.md

Paste the output into the plugin as a background reviewer turn (`--wait` blocks until Codex is
done, so the author wakes on the hand-back):

    /codex:rescue --model gpt-5.5 "<the prompt printed above>" --wait

`--model gpt-5.5` pins the reviewer to a specific GPT model. It matters: the `codex:codex-rescue`
agent is itself a Claude (`sonnet`) wrapper that forwards to Codex, so leaving the model unset can
let a turn run as the wrapper instead of a GPT model (it then discloses `> — via claude-sonnet-…`).
Pinning the model keeps the reviewer — and its disclosure line — a real, consistent GPT model.

The helper only **prints** the prompt — a bash script cannot invoke a Claude Code slash command,
and it never touches the doc, the marker, or the network. The prompt is mode-agnostic: it points
Codex at its own skill, which detects asymmetric vs peer-review mode, so it never drifts from
`.agents/skills/dual-review/SKILL.md`. Re-run the helper each round (the abs path is stable).

**Trade-offs.** This folds an externally-versioned dependency (the plugin + Codex CLI + model
drift) into a flow the core deliberately keeps self-contained and offline, and Codex invocations
count against your Codex usage/billing. It is a convenience layer, not a replacement — the manual
second-session route stays the default and remains fully supported.

## Autonomous review (`/dual-review-auto`)

With the Codex plugin installed (see above), `/dual-review-auto <doc-or-PR>` runs the **entire
review loop unattended in one session** — Claude takes the author turns and summons Codex for
each reviewer turn — until the marker reaches `converged`/`exhausted`, then stops at the **human
gate** (and, in PR mode, the human-gated publish). It covers both asymmetric and peer-review
modes.

    /dual-review-auto docs/specs/2026-06-09-my-feature.md

Each reviewer turn is dispatched with **`--model gpt-5.5`** so the reviewer is a real, consistent
GPT model (the `codex:codex-rescue` agent is a Claude `sonnet` wrapper; pinning the model keeps an
unset turn from running as the wrapper). To use a different model, change the `--model` value in
`commands/dual-review-auto.md` §3.

Safety: any non-conformant turn (Codex didn't flip the marker, an illegal marker transition, a
malformed doc, or a dispatch failure) **stops the loop and surfaces** — no retry, no faked
progress (enforced by `scripts/dual-agent-auto-step.sh`). Nothing auto-merges or auto-posts.

Independence note: Claude decides when to summon Codex and with what prompt, so this narrows
independence of *control* (Codex still runs its own skill in its own context). For a maximally
adversarial second opinion, the manual `/dual-review` route remains and stays the default.

## Tests

    ( for t in scripts/*.test.sh; do echo "== $t =="; bash "$t" || exit 1; done )
