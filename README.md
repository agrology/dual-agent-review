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

## Reviewer setup (BYO reviewer)

The reviewer agent is a separate tool you bring yourself; it does **not** appear automatically
on plugin install. You need:

- the `codex` CLI, authenticated, with a model available to it
- the self-contained reviewer skill copied into your target repo at
  `<your-repo>/.agents/skills/dual-review/` — this fixed, repo-root-relative location is what
  the skill's bundled helper/protocol paths resolve against, so the path must be exact

Copy the skill directory from this repo (`.agents/skills/dual-review/`) into your repo at the
same relative path, then run Codex **from your repo's root** so the bundled paths resolve.
See "Usage (file-coordination)" below for how the two sides then converge.

### Choosing the reviewer model

The reviewer defaults to **Codex/GPT**. To use a different one, set `DUAL_AGENT_REVIEWER`:

| value | reviewer | needs |
|---|---|---|
| `codex` *(default)* | Codex/GPT via the local Codex CLI | `codex` on PATH, authenticated |
| `fable` | Claude Fable 5 as a subagent | nothing — runs in-harness |
| `gemini` | Gemini via the `gemini` CLI | `gemini` on PATH, authenticated |

```bash
export DUAL_AGENT_REVIEWER=fable
```

`DUAL_AGENT_REVIEWER_MODEL` optionally pins a specific model for the `gemini` provider.
`codex` is deliberately pinned to `gpt-5.5` and ignores this variable, so an unset model
cannot silently downgrade the reviewer to its Claude wrapper.

**Independence tiers.** A cross-vendor reviewer (`codex`, `gemini`) gives *architectural*
independence: different vendor, different model family, separate reasoning. A same-vendor
reviewer (`fable`) gives fresh context and different weights, but shares a training lineage
with the Claude author — real value, weaker claim. `dual-agent-reviewer.sh notice` reports a
same-vendor pairing so the distinction is visible when you are deciding rather than buried
here; the autonomous route surfaces it at the human gate automatically.

### Manual (two-session) route, per provider

The manual route is the dependency-free default: you open the reviewer yourself and hand it
the doc's **canonical absolute path**. That rendezvous requirement is provider-independent — a
relative path breaks when the reviewer's session opens in a different checkout.

- **Codex/GPT** — install the bundled skill at `.agents/skills/dual-review/` in your repo and
  run Codex from the repo root, then give it the absolute doc path.
- **Claude (Fable 5)** — open a second Claude Code session, and paste the output of
  `scripts/dual-agent-reviewer.sh prompt <doc> --reviewer fable`. It carries an explicit
  instruction to read the bundled protocol before editing, so no skill install is needed.
- **Gemini** — paste the output of
  `scripts/dual-agent-reviewer.sh prompt <doc> --reviewer gemini` into a `gemini` session with
  write access to the repo. Same protocol, same human gate.

  > **Unverified.** The `gemini` provider is implemented and unit-tested, but no end-to-end
  > review has been driven through a real `gemini` CLI — it was not installed on the machine
  > where this shipped. Treat the Gemini route as untested until you have run one review with
  > it. In particular, unattended Gemini review needs the CLI to permit file writes without
  > interactive approval; if yours does not, use the manual route above. The `codex` and
  > `fable` routes do not carry this caveat.

**Write access is a trust contract, not a sandbox.** Any reviewer needs write access to the
doc to append findings and flip the marker. The "read only that document" scope limit is
carried in the prompt and relies on the reviewer honouring it — it is not enforced by a
sandbox. This is the same trade-off the Codex `--write` route has always made.

**Dependencies.** `codex` and `gemini` are optional external CLIs, each with its own auth and
billing. `fable` adds none. The manual route works with any of them.

## Layout

- `docs/dual-agent-review.md` — the protocol contract
- `commands/dual-review.md` — the `/dual-review` author-mode command
- `commands/dual-review-auto.md` — `/dual-review-auto`, a deprecated alias for `/dual-review`
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
- `scripts/dual-agent-reviewer.sh` — the reviewer **provider registry**: which provider is
  selected (`resolve`), whether it's dispatchable (`check`), its reviewer prompt (`prompt`) and
  shell dispatch command (`command`), the same-vendor independence notice (`notice`), and
  post-turn reviewer-identity verification (`verify-vendor`)
- `scripts/dual-agent-auto-step.sh` — per-round verdict (continue/terminal/stop) for the autonomous loop
- `scripts/dual-agent-build-reviewer-bundle.sh` — regenerates the bundled reviewer skill from the canonical sources
- `scripts/dual-agent-history-check.sh` — scans the full git history for internal/sensitive terms; the pre-publish safety gate (see `PUBLISHING.md`)
- `PUBLISHING.md` — how to take a fork/clone of this repo public safely (fresh-history export or history scrub)

## Usage (attended, two-session file-coordination)

> **The unattended route is the default** — see "Autonomous review" below. This section
> documents the **attended** flow: the manual, two-session handoff you get via `--attended`,
> or when the unattended route degrades. The mechanics below (marker, watcher, absolute-path
> rendezvous, worktree notes) are shared by both routes.

> **Paths in the examples below** (`scripts/…`, `docs/specs/…`) assume you have this repo
> cloned. Installed as a **plugin**, you don't run the scripts yourself — the `/dual-review`
> commands resolve their own bundled scripts via `${CLAUDE_PLUGIN_ROOT}` for you; you just run
> the slash command and copy the reviewer skill into your repo per **Reviewer setup** above.

In your Claude session:

    /dual-review docs/specs/2026-06-09-my-feature.md --attended

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

The **autonomous route is the default** (see "Autonomous review" below): `/dual-review` already
dispatches the reviewer for you in one unattended session, and for the `codex` provider it does
so via this same Codex-plugin transport under the hood. The two-session manual flow above is
what you get on degradation (the selected provider isn't available), via `--attended`, or by
explicit choice.

This section documents that Codex-plugin transport directly, for driving a single reviewer turn
yourself — e.g. during the attended flow, or outside the unattended loop — without opening a
second Codex/GPT session. It requires OpenAI's
[`codex-plugin-cc`](https://github.com/openai/codex-plugin-cc) installed in Claude Code, with
the local Codex CLI authenticated; it lets you **summon the reviewer from the author's machine**,
skipping the second session and the window-switching.

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

    ${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-reviewer.sh prompt docs/specs/2026-06-09-my-feature.md

> **Migration:** `dual-agent-codex-prompt.sh` was removed in favour of
> `dual-agent-reviewer.sh prompt <doc>`, which emits the same prompt for Codex and a
> provider-appropriate one for `fable`/`gemini`.

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
second-session route remains fully supported for attended review.

## Autonomous review (`/dual-review`, unattended by default)

`/dual-review <doc-or-PR>` runs the **entire review loop unattended in one session** by
default — Claude takes the author turns and dispatches the reviewer for each reviewer turn —
until the marker reaches `converged`/`exhausted`, then stops at the **human gate** (and, in PR
mode, the human-gated publish). It covers both asymmetric and peer-review modes. Pass
`--attended` to fall back to the manual, two-session handoff instead.

    /dual-review docs/specs/2026-06-09-my-feature.md

The reviewer provider is selected with `DUAL_AGENT_REVIEWER` (`codex`, `fable`, or `gemini`;
defaults to `codex`) or a per-invocation `--reviewer <id>` flag. For `gemini`,
`DUAL_AGENT_REVIEWER_MODEL` pins the model; for `codex`, each turn is dispatched with
`--model gpt-5.5` so the reviewer is a real, consistent GPT model rather than the
`codex:codex-rescue` agent's Claude `sonnet` wrapper falling through unset.

If the chosen provider isn't available (e.g. the Codex CLI isn't installed or authenticated),
the command announces the reason and degrades to the attended, manual-handoff flow rather than
failing silently.

`/dual-review-auto` is now a **deprecated alias** for `/dual-review` — it forwards to the same
command and behavior described here.

Safety: any non-conformant turn (the reviewer didn't flip the marker, an illegal marker
transition, a malformed doc, or a dispatch failure) **stops the loop and surfaces** — no retry,
no faked progress (enforced by `scripts/dual-agent-auto-step.sh`). Nothing auto-merges or
auto-posts.

Independence note: Claude decides when to summon the reviewer and with what prompt, so this
narrows independence of *control* (the reviewer still runs its own skill in its own context).
For a maximally adversarial second opinion, the attended (`--attended`) route remains fully
supported.

## Tests

    ( for t in scripts/*.test.sh; do echo "== $t =="; bash "$t" || exit 1; done )
