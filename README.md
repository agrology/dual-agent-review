# multi-review

<p align="center">
  <img src="docs/multi-review-meme.png" alt="The three-Spider-Men-pointing meme: author agent, reviewer agent, and the human gate all pointing at each other" width="480">
  <br>
  <em>Author agent, reviewer agent, human gate — everyone double-checking everyone.</em>
</p>

An **opt-in, human-gated** protocol where Claude authors a design doc and an external
reviewer iterates with it to convergence — always ending at a **human approval gate**.

## Install

As a Claude Code plugin:

    /plugin install agrology/multi-review

This installs the `/multi-review` slash command and its supporting scripts. It does **not**
install the reviewer side — see "Reviewer setup" below, though note that the `fable` reviewer
needs no setup at all.

## Reviewer setup (BYO reviewer)

What you need depends on which reviewer you pick — **only `codex` requires setup**:

| reviewer | setup required |
|---|---|
| `fable` | **None.** Runs in-harness as a Claude subagent; no CLI, no skill install, no extra auth. |
| `gemini` | The `gemini` CLI on PATH and authenticated, plus two settings — see the Gemini notes under "Manual (two-session) route" below. No skill install. |
| `codex` *(default)* | The `codex` CLI, authenticated, **and** the reviewer skill copied into your repo (below). |

**Codex only** — copy the self-contained reviewer skill from this repo
(`.agents/skills/multi-review/`) into your target repo at exactly
`<your-repo>/.agents/skills/multi-review/`. That fixed, repo-root-relative location is what the
skill's bundled helper/protocol paths resolve against, so the path must match. Then run Codex
**from your repo's root** so those paths resolve.

`fable` and `gemini` need no skill: the prompt they receive points them at the protocol
contract directly. See "Usage (attended, two-session file-coordination)" below for how the two
sides converge once a reviewer is in place.

### Choosing the reviewer model

The reviewer defaults to **Codex/GPT**. To use a different one, set `MULTI_REVIEW_REVIEWER`:

| value | reviewer | needs |
|---|---|---|
| `codex` *(default)* | Codex/GPT via the local Codex CLI | `codex` on PATH, authenticated |
| `fable` | Claude Fable 5 as a subagent | nothing — runs in-harness |
| `gemini` | Gemini via the `gemini` CLI | `gemini` on PATH, authenticated |

```bash
export MULTI_REVIEW_REVIEWER=fable
```

**Which model each provider runs.** Defaults prefer a *provider-published* alias over a version
pinned in this repo, so a new release is picked up without a code change:

| provider | default model | why |
|---|---|---|
| `codex` | `gpt-5.5` | OpenAI publishes no "latest" alias, so a named default is unavoidable. It must be non-empty — an unset model lets the `codex:codex-rescue` wrapper answer as Claude. |
| `fable` | `fable` | Already an alias the harness resolves; no version here to go stale. |
| `gemini` | `gemini-pro-latest` | Google's own alias for the top Pro tier. Without an explicit `-m` the CLI falls back to the cheaper *flash* tier, which is a weaker reviewer. **Note:** this alias currently resolves to a **preview** model (`gemini-3.1-pro-preview` at time of writing), and preview models can change or be withdrawn. Pin `MULTI_REVIEW_REVIEWER_MODEL` if you need a fixed, non-preview model. |

`MULTI_REVIEW_REVIEWER_MODEL` overrides the default for whichever provider is selected — nothing
above is unoverridable. It names a model, not a provider, so if you switch providers you will
usually want to unset it. Whatever model runs, `verify-vendor` still checks that the id it
discloses belongs to the selected provider's vendor.

> **A `> — via` line is the reviewer's own claim about itself, and models are unreliable
> narrators of their own identity.** Observed here: a turn served by `gemini-3.1-pro-preview`
> disclosed itself as `gemini-2.5-pro`, and asking `gemini-3.1-pro-preview` directly produced
> the same wrong answer — models tend to report a training-era identity rather than the model
> actually serving the request. This is precisely why `verify-vendor` matches at **vendor**
> level and not on the exact id: both of those ids map to `google`, so the turn verifies
> correctly, whereas exact-id matching would have hard-failed a perfectly legitimate review.
> Treat disclosure lines as provenance for *who answered*, not as a reliable model version.
> To find out which model actually served a request, read the API's server-reported
> `modelVersion` — not the model's own words.

**Independence tiers.** A cross-vendor reviewer (`codex`, `gemini`) gives *architectural*
independence: different vendor, different model family, separate reasoning. A same-vendor
reviewer (`fable`) gives fresh context and different weights, but shares a training lineage
with the Claude author — real value, weaker claim. `multi-review-reviewer.sh notice` reports a
same-vendor pairing so the distinction is visible when you are deciding rather than buried
here; the autonomous route surfaces it at the human gate automatically.

### Manual (two-session) route, per provider

The manual route is the dependency-free option — it needs no CLI and no plugin. It is not the
default (the unattended route is; see "Autonomous review"), but it is what you get via
`--attended`, on degradation, or by choice. You open the reviewer yourself and hand it the
doc's **canonical absolute path**. That rendezvous requirement is provider-independent — a
relative path breaks when the reviewer's session opens in a different checkout.

- **Codex/GPT** — install the bundled skill at `.agents/skills/multi-review/` in your repo and
  run Codex from the repo root, then give it the absolute doc path.
- **Claude (Fable 5)** — open a second Claude Code session, and paste the output of
  `scripts/multi-review-reviewer.sh prompt <doc> --reviewer fable`. It carries an explicit
  instruction to read the bundled protocol before editing, so no skill install is needed.
- **Gemini** — paste the output of
  `scripts/multi-review-reviewer.sh prompt <doc> --reviewer gemini` into a `gemini` session with
  write access to the repo. Same protocol, same human gate.

  > **Verified end to end — with one required setting.** A full review was driven through a
  > real `gemini` CLI (v0.51.0): it read the doc, wrote three findings, flipped the marker, and
  > passed reviewer-identity verification. Two prerequisites, neither of which this tool sets
  > for you:
  >
  > 1. **`.gemini/settings.json` must disable gitignore filtering** for review docs that are
  >    gitignored — which includes **all PR-mode scratch files** (`.multi-review/reviews/…`) and,
  >    in some repos, `docs/specs`/`docs/plans`. Without it Gemini refuses to read the doc at
  >    all (*"is ignored by configured ignore patterns"*):
  >
  >    ```json
  >    { "context": { "fileFiltering": { "respectGitIgnore": false } } }
  >    ```
  >
  > 2. **The workspace must be trusted.** Outside a trusted folder the CLI exits 55. Trust it
  >    interactively or set `GEMINI_CLI_TRUST_WORKSPACE=true`. This tool deliberately does
  >    **not** pass `--skip-trust` for you — trusted folders guard against repo content driving
  >    the agent, and disabling that is your call.
  >
  > Also worth knowing: export `GEMINI_API_KEY` (a key in `~/.gemini/.env` was not picked up for
  > `gemini -p` in our testing), and note the free tier allows only a handful of requests per day
  > — a multi-round review will exhaust it. Failure is clean throughout: doc untouched, marker
  > not flipped, and the autonomous route degrades to the manual flow with the reason stated.

**Write access is a trust contract, not a sandbox.** Any reviewer needs write access to the
doc to append findings and flip the marker. The "read only that document" scope limit is
carried in the prompt and relies on the reviewer honouring it — it is not enforced by a
sandbox. This is the same trade-off the Codex `--write` route has always made.

**Dependencies.** `codex` and `gemini` are optional external CLIs, each with its own auth and
billing. `fable` adds none. The manual route works with any of them.

## Layout

- `docs/multi-review.md` — the protocol contract
- `commands/multi-review.md` — the `/multi-review` author-mode command
- `.claude-plugin/plugin.json` — the Claude Code plugin manifest
- `.agents/skills/multi-review/` — the self-contained `/multi-review` reviewer skill, needed **only** for the `codex` provider (`fable`/`gemini` are pointed at the protocol by their prompt)
  (bundled copies of the protocol doc + reviewer scripts; not installed by the plugin — see
  "Reviewer setup" above)
- `CLAUDE.md` / `AGENTS.md` — this repo's own engineering working agreement, including the
  author/reviewer multi-review protocol pointer (§11)
- `scripts/multi-review-egress-guard.sh` — path/egress validation helper
- `scripts/multi-review-core.sh` — deterministic marker/thread logic
- `scripts/multi-review-watch.sh` — mtime watcher (backgrounded, wakes the author agent)
- `scripts/multi-review-wait.sh` — lock-free bounded marker wait (reviewer-side resume)
- `scripts/multi-review-pr.sh` — PR-URL mode: ingest a GitHub PR into a local scratch file, then publish the converged review
- `scripts/multi-review-peer.sh` — symmetric peer-review grammar (mode detect, open-findings, convergence) for PR-mode docs
- `scripts/multi-review-reviewer.sh` — the reviewer **provider registry**: which provider is
  selected (`resolve`), whether it's dispatchable (`check`), its reviewer prompt (`prompt`) and
  shell dispatch command (`command`), the same-vendor independence notice (`notice`), and
  post-turn reviewer-identity verification (`verify-vendor`)
- `scripts/multi-review-auto-step.sh` — per-round verdict (continue/terminal/stop) for the autonomous loop
- `scripts/multi-review-build-reviewer-bundle.sh` — regenerates the bundled reviewer skill from the canonical sources
- `scripts/multi-review-history-check.sh` — scans the full git history for internal/sensitive terms; the pre-publish safety gate (see `PUBLISHING.md`)
- `scripts/*.test.sh` — the test suite; one file per script, run by the gate under "Tests" below
- `scripts/fixtures/codex-prompt.golden.txt` — the byte-identity lock on the Codex reviewer prompt. Captured from the original emitter before it was retired, with the doc path normalised to `@@DOC@@`; it is now the only thing that would catch silent drift in that prompt, so regenerate it deliberately rather than to make a test pass
- `PUBLISHING.md` — how to take a fork/clone of this repo public safely (fresh-history export or history scrub)

## Usage (attended, two-session file-coordination)

> **The unattended route is the default** — see "Autonomous review" below. This section
> documents the **attended** flow: the manual, two-session handoff you get via `--attended`,
> or when the unattended route degrades. The mechanics below (marker, watcher, absolute-path
> rendezvous, worktree notes) are shared by both routes.

> **Paths in the examples below** (`scripts/…`, `docs/specs/…`) assume you have this repo
> cloned. Installed as a **plugin**, you don't run the scripts yourself — the `/multi-review`
> commands resolve their own bundled scripts via `${CLAUDE_PLUGIN_ROOT}` for you; you just run
> the slash command and copy the reviewer skill into your repo per **Reviewer setup** above.

In your Claude session:

    /multi-review docs/specs/2026-06-09-my-feature.md --attended

Claude arms author mode (inserts the status marker, starts a watcher) and waits, printing the
doc's canonical absolute path. Hand that path to your reviewer — **any** of the three works
here:

- **Codex/GPT** — in a second Codex session rooted in **your** repo (skill installed per
  **Reviewer setup** above), run `/multi-review <abs-path>`.
- **Claude (Fable 5)** or **Gemini** — no skill needed; paste the output of
  `scripts/multi-review-reviewer.sh prompt <doc> --reviewer fable` (or `--reviewer gemini`) into
  that session. The prompt carries the protocol contract's location and the absolute doc path.

The two sides converge through the file; Claude stops at a **human approval gate**. Any other
agent can play the reviewer too — `AGENTS.md` points it at the same protocol.

- **Config:** `MULTI_REVIEW_DOC_DIRS` (default `docs/specs docs/plans`),
  `MULTI_REVIEW_MAX_ROUNDS` (default `10`). The dir list is space-separated, so individual
  dirs must not contain spaces (the relative defaults are safe even in a repo whose absolute
  path has them).
- **Egress:** the command refuses to arm on any path outside `MULTI_REVIEW_DOC_DIRS`, a symlink,
  or a `../` escape. The reviewer reading only the doc is a trusted-reviewer protocol
  requirement (see `docs/multi-review.md`).
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
  looping `scripts/multi-review-wait.sh` between rounds (the skill's default — exit 9 just
  means "run it again"). Re-invoke `/multi-review <doc>` manually only if the reviewer's
  harness can't keep waiting. An author that wakes while the marker still says
  `awaiting-reviewer` is benign: the reviewer's mid-edit saves trip the watcher, and the
  marker check makes the author re-arm.

## Usage (PR review)

Point the author at a PR instead of a local doc:

    /multi-review https://github.com/<owner>/<repo>/pull/<n>

(Also accepts `<owner>/<repo>#<n>` and, for the current repo, `#<n>`.) The author fetches the
PR's description + diff via `gh` into a gitignored scratch file
`.multi-review/reviews/<owner>/<repo>/pr-<n>.md`, then the **same** marker/watcher/wait flow
converges with your reviewer on that local file. The reviewer never touches GitHub. On
convergence the author stops at the human gate; only on your approval does it post **one
neutral** `gh pr review --comment` back to the PR. Agreed findings that carry a
`> — at <path>:<line>` anchor (RIGHT-side new-file line numbers) post as GitHub inline
comments inside that single review; everything else — open, dissented, and un-anchorable
findings — stays in the top-level summary. Requires `gh` and `jq` authenticated with access
to the PR.

## Optional: drive the reviewer via the Codex plugin

The **autonomous route is the default** (see "Autonomous review" below): `/multi-review` already
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
`/multi-review` reviewer skill in its **own context** — so reviewer independence (a different
model family, separate reasoning) and the **human approval gate** are intact, and the
file-coordination protocol remains the source of truth.

**Manual vs plugin is not a setting — it's a per-turn choice.** There is no flag or marker that
selects between them; the author side keys only on the marker and cannot tell which transport
produced a reviewer turn. To use the manual route, open a separate session and run `/multi-review
<doc>`; to use the plugin, run the helper below and hand its prompt to `/codex:rescue`. You may
even switch between them across rounds on the same doc — the marker and threads are the only
state. (Distinct from the `asymmetric` vs `peer-review` *mode* reported by
`scripts/multi-review-peer.sh mode`, which the doc itself selects — see "Peer review" in
`docs/multi-review.md`.)

From the armed author session, get the canonical reviewer prompt and hand it to the plugin
(the author runs this in its plugin context, where `${CLAUDE_PLUGIN_ROOT}` is set; from a plain
clone, use the bare `scripts/…` path instead):

    ${CLAUDE_PLUGIN_ROOT}/scripts/multi-review-reviewer.sh prompt docs/specs/2026-06-09-my-feature.md

> **Migration:** `multi-review-codex-prompt.sh` was removed in favour of
> `multi-review-reviewer.sh prompt <doc>`, which emits the same prompt for Codex and a
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
`.agents/skills/multi-review/SKILL.md`. Re-run the helper each round (the abs path is stable).

**Trade-offs.** This folds an externally-versioned dependency (the plugin + Codex CLI + model
drift) into a flow the core deliberately keeps self-contained and offline, and Codex invocations
count against your Codex usage/billing. It is a convenience layer, not a replacement — the manual
second-session route remains fully supported for attended review.

## Autonomous review (`/multi-review`, unattended by default)

`/multi-review <doc-or-PR>` runs the **entire review loop unattended in one session** by
default — Claude takes the author turns and dispatches the reviewer for each reviewer turn —
until the marker reaches `converged`/`exhausted`, then stops at the **human gate** (and, in PR
mode, the human-gated publish). It covers both asymmetric and peer-review modes. Pass
`--attended` to fall back to the manual, two-session handoff instead.

    /multi-review docs/specs/2026-06-09-my-feature.md

The reviewer provider is selected with `MULTI_REVIEW_REVIEWER` (`codex`, `fable`, or `gemini`;
defaults to `codex`) or a per-invocation `--reviewer <id>` flag. Each provider's model comes
from the registry and can be overridden with `MULTI_REVIEW_REVIEWER_MODEL` — see "Which model
each provider runs" above. The `codex` default is non-empty on purpose: an unset model lets
the `codex:codex-rescue` agent's Claude `sonnet` wrapper answer instead of a GPT model.

If the chosen provider isn't available (e.g. the Codex CLI isn't installed or authenticated),
the command announces the reason and degrades to the attended, manual-handoff flow rather than
failing silently.

Safety — two different failures, handled two different ways, deliberately:

- **A turn that ran but cannot be trusted → the loop stops and surfaces.** No retry, no faked
  progress. That covers a reviewer that didn't flip the marker, an illegal marker transition,
  or a malformed doc (all enforced by `scripts/multi-review-auto-step.sh`), plus a
  **reviewer-identity mismatch**: after each turn, `multi-review-reviewer.sh verify-vendor`
  compares the `> — via` disclosures the turn added against the selected provider's vendor, so
  a turn taken by a different vendor's model than the one you chose halts the review rather
  than being silently accepted.
- **A provider that couldn't be invoked at all → degradation, not a stop.** A dispatch failure
  (CLI missing, unauthenticated, agent unavailable) announces its reason and drops to the
  attended, manual-handoff flow, as described above. Nothing ran, so there is nothing to
  distrust.

Nothing auto-merges or auto-posts in either case.

Independence note: Claude decides when to summon the reviewer and with what prompt, so this
narrows independence of *control* — the reviewer still reasons in its own context, from the
protocol contract (via its own skill for `codex`, or the protocol file the prompt points
skill-less providers at). For a maximally adversarial second opinion, the attended
(`--attended`) route remains fully supported.

## Tests

    ( for t in scripts/*.test.sh; do echo "== $t =="; bash "$t" || exit 1; done )
