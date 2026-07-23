# Dual-Agent Review Protocol (file-coordination, opt-in)

> Opt-in. Two peer agents take turns editing ONE design doc. Coordination is an in-file
> status marker + id'd comment threads. Always ends at a **human approval gate**.

## Roles

- **Author** (Claude, via `/dual-review`): drafts/revises the doc, resolves concerns.
- **Reviewer** (any external agent you drive separately — Codex, Claude Fable 5, or Gemini):
  leaves concerns. Driven in its own session — or, optionally, summoned from the author's
  machine via `scripts/dual-agent-reviewer.sh prompt` (see the README).
- **Autonomous by default:** `/dual-review` runs the whole loop unattended, ending at the
  same human gate (see the README).

## Status marker (the single coordination signal)

One line near the top of the doc:

    <!-- dual-agent-review: <state> · round <n>/<max> -->

| State | Meaning | Whose turn |
|---|---|---|
| `awaiting-reviewer` | author's revisions are in | reviewer |
| `awaiting-author`   | reviewer left concerns    | author |
| `converged`         | reviewer has no open concerns (terminal) | human gate |
| `exhausted`         | round bound reached (terminal)          | human gate |

Act ONLY when the marker names your turn. The author keys turn-taking on the **marker
alone**, never on "did new text appear". `max` defaults to 10.

## Comment threads (the channel)

- Open a concern: `> [reviewer:<id>] <concern>` with a unique `<id>` (e.g. `r1`, `r2`).
- Close it:       `> [author: resolved:<id>] <how it was addressed>`.
- Disclosure (required): a following `> — via <model>` continuation line on each comment.
- A thread is **open** iff a `[reviewer:<id>]` has no matching `[author: resolved:<id>]`.
- Ids MUST be unique; reuse a NEW id for follow-ups. Duplicate ids are a hard error.
- Only top-level `> [..]` lines are control markers; nested `> > ...` is ignored.

## Peer review (PR mode only)

When the doc carries `<!-- dual-agent-mode: peer-review -->` in its header (a PR-mode scratch
file), the review is **symmetric** — both agents are reviewers; neither authored the PR.

- Raise a finding: `> [finding:<id>|<sev>] <concern>` + a required `> — via <model>` line, then a
  required `> — risk: <short risk>` line. `<sev>` is `high`, `med`, or `low`; the parser rejects any
  other token. Keep the concern to **one short line** and the risk to one clause — no paragraphs.
- Respond to the *other* agent's finding: `> [concur:<id>]` or `> [dispute:<id>] <why>`
  + `> — via <model>`. You may not respond to your own finding.
- Retract your own finding: `> [withdraw:<id>]` + `> — via <model>`.
- A finding is settled once the other agent responds (agreed/dissent) or the raiser withdraws
  (dropped). Converged = no finding awaits a response; dissent is allowed and does not block.
- Ids are unique; the `> — via <model>` line is mandatory and identifies you.
- Optionally anchor a finding to a changed line: a `> — at <path>:<line>` (or
  `> — at <path>:<start>-<end>`) line **immediately after** that finding's `> — risk:` line.
  Use new-file (RIGHT-side) line numbers read from the `## Diff` hunk headers. The anchor is
  optional — omit it if unsure; only **agreed** anchored findings post inline, and an anchor
  that does not land on a changed line degrades to the summary. Open, dissented, and
  un-anchorable findings stay in the summary.

**Scope (PR mode): diff-anchored, referenced files readable.** The reviewed artifact is a PR
diff. Every finding MUST trace to a changed hunk — a line the PR adds or removes. Pre-existing
issues the diff does not touch are out of scope; do not report them. But a changed hunk can
*introduce* a conflict with code or docs it references (e.g. a revised K01 claim that
contradicts K301's existing, unchanged behavior) — that conflict is diff-introduced and
therefore in scope. To evaluate it, the reviewer MAY read the **current bodies of repo files
the diff directly references**, solely to check the change is self-consistent. This is a
narrow, local-read allowance: no whole-corpus sweeps, no upload, and any finding it produces
must still name the changed hunk that introduces the conflict.

## Star review (multi-secondary)

When a copy carries `<!-- dual-agent-mode: star -->` in its header and the marker is
`awaiting-reviewer`, you are one **secondary** reviewing an isolated copy of a design doc. You
never see other secondaries or the primary's responses — that independence is the point.

- **Scope: the whole document body.** Star is NOT diff-scoped (unlike peer-review); there is no
  `## Diff`. Review the design on its merits, end to end.
- Raise a finding: `> [finding:<id>|<sev>] <concern>` + a required `> — via <model>` line + a
  required `> — risk: <short risk>` line. `<sev>` is `high`, `med`, or `low`. One short line per
  concern, one clause per risk.
- Use fresh short ids (`r1`, `r2`, …) scoped to this copy — the orchestrator namespaces them by
  provider and round (`<provider>-rd<N>-<id>`), so you never coordinate ids with anyone.
- You do not respond to findings and you do not converge — a secondary raises findings only. The
  primary ingests, agrees/disputes, and decides convergence.
- Flip the marker `awaiting-reviewer` → `awaiting-author` as your FINAL edit (the flip is the
  handoff). Read only this copy; do not implement, commit, or open a PR.

**Primary (star).** On the merged doc (marker `awaiting-primary`) the primary responds to every
merged finding with **exactly one** of these — NOT the asymmetric `> [author: resolved:<id>]`,
which star's `check-converged` ignores (using it would loop forever, never converging):

- `> [agree:<ns-id>]` + `> — via <primary-model-id>` — accept the finding and address it in the
  doc body, or
- `> [dispute:<ns-id>] <one-line reason>` + `> — via <primary-model-id>` — reject it, tersely. A
  dispute never forces a round.

Convergence is **coverage, not consensus**: every merged finding needs exactly one `agree`/`dispute`;
disputes are expected and do not block. The human gate settles disputes.

## Turn-taking discipline

- **Reviewer:** write all concerns first, then flip `awaiting-reviewer` → `awaiting-author`
  **last** (the flip is the atomic handoff). Set `converged` instead only when no
  `[reviewer:<id>]` lacks its `[author: resolved:<id>]`.
- **Author:** address each open id, append `[author: resolved:<id>]`, then advance the
  marker via the tooling. Stop at the round bound.

## Bounds & terminal state

Round = one reviewer pass + one author pass; the author increments on hand-back. At
`round > max` the marker becomes `exhausted`. Convergence or exhaustion both stop the loop
and present the annotated doc; a **human approves** before any implementation or PR.

## Egress

- **Mechanical (author side):** `/dual-review` refuses to arm on any path outside
  `DUAL_AGENT_DOC_DIRS` (default `docs/specs docs/plans`), or on a symlink/`../` escape.
- **Protocol requirement (reviewer side, trusted):** a conforming reviewer reads only the
  doc it is pointed at — plus, in PR mode, the current bodies of repo files that doc's diff
  directly references (a local read, for the diff-consistency checks described under "Scope"
  above) — captures no env/secrets, and uploads nothing beyond the doc content without explicit
  authorization. This is a trust contract, not a mechanical guarantee.
- **PR mode (author side):** the reviewed artifact is a GitHub PR, but coordination is still a
  local scratch file under `.dual-agent/reviews/`. Only the **author** touches GitHub — it
  reads the PR (`gh pr view`/`gh pr diff`) on ingest and posts **exactly one** neutral review
  (`gh pr review --comment`) on publish, and the publish is **human-gated**. The reviewer
  touches no GitHub: it reads the local scratch file (and, for diff-consistency, the local repo
  files its diff references — see "Scope" under Peer review) and uploads nothing.

## Supersedes

The earlier subprocess/exit-code protocol (`docs/specs/2026-06-08-dual-agent-review-design.md`)
is superseded for interactive use by the file-coordination model
(`docs/specs/2026-06-09-frictionless-dual-agent-review-design.md`).
