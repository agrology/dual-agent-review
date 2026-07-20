---
name: dual-review
description: >-
  Review a dual-agent review document as the Codex/GPT reviewer. Use when asked
  to review a doc under the file-coordination dual-agent protocol, especially
  docs with a `<!-- dual-agent-review: ... -->` marker or requests like
  "dual-review <doc>".
---

# Dual Review

## Purpose

Act as the reviewer in this repo's dual-agent review protocol. The author side is Claude's `/dual-review`; the Codex/GPT side is this `/dual-review` skill.

## Workflow

> Setup assumption: this skill lives at `.agents/skills/dual-review/` in the repo Codex is
> running in; all helper/protocol paths below are relative to the repo root.

1. Read the bundled protocol contract: `.agents/skills/dual-review/protocol/dual-agent-review.md`.
2. Resolve the target to ONE canonical absolute path before reviewing anything. Worktrees
   mean a repo can hold several same-named copies of the doc; reviewing the wrong one
   deadlocks both agents silently.
   - Canonicalize the path you were given (resolve relative segments and symlinks) and
     use the result everywhere below. Prefer being handed an absolute path by the author.
   - If that path is missing, or exists but carries no marker, the live copy may be in
     another checkout: run `git worktree list` and inspect each checkout for the same
     repo-relative doc.
   - A copy is a CANDIDATE only if its marker is in a non-terminal state
     (`awaiting-reviewer` or `awaiting-author`); `converged`/`exhausted` copies never are.
   - Proceed only when EXACTLY ONE candidate exists. Zero candidates: stop and report the
     doc is not armed. Two or more: stop and ask the user which copy is live. Never guess.
3. Read only the target document unless the user explicitly authorizes broader repo context.
4. Find the marker line:
   `<!-- dual-agent-review: <state> · round <n>/<max> -->`
5. Act only when the state is `awaiting-reviewer`.
   - If it is `awaiting-author`, it is the author's turn — wait for the hand-back (see
     "Waiting for your turn"), then review.
   - If it is `converged` or `exhausted`, stop at the human gate. (In peer-review mode this is
     all you do — only the author side can post to the PR; you never call `gh`.)
   - If the marker is missing or malformed, stop and report that the doc is not armed.

**First, determine the review mode:** run `.agents/skills/dual-review/scripts/dual-agent-peer.sh mode "<doc>"`.

- **`asymmetric`** (local spec/plan doc) — the existing workflow: leave `> [reviewer:<id>]`
  concerns (+ `> — via <model>`), and set `converged` when no `[reviewer:]` lacks its
  `[author: resolved:]`. (Steps below.)

- **`peer-review`** (PR-mode doc, header `<!-- dual-agent-mode: peer-review -->`) — you are a
  **peer reviewer**, not a one-sided commenter. On your turn:
  1. `.agents/skills/dual-review/scripts/dual-agent-peer.sh open-findings "<doc>"` — the other agent's findings awaiting
     your response (a hard error means a malformed doc — stop and surface, don't guess).
  2. For each, append in the `## Review` section `> [concur:<id>]` or `> [dispute:<id>] <why>`,
     each followed by `> — via <your-model-id>`.
  3. Add your own new findings: `> [finding:<new-id>|<sev>] <concern>` + `> — via <your-model-id>`
     + `> — risk: <short risk>` (unique ids; `<sev>` ∈ high/med/low; one terse line + one risk clause).
  4. Optionally `> [withdraw:<id>]` + `> — via <your-model-id>` for findings YOU raised.
  5. **Convergence:** set the marker to `converged` only when
     `.agents/skills/dual-review/scripts/dual-agent-peer.sh check-converged "<doc>"` passes (every finding settled, none
     open; dissent is fine). Otherwise flip to `awaiting-author` to hand back.
  6. **Never** use `[reviewer:]` or `[author: resolved:]` in a peer-review doc; identity is the
     `> — via <model-id>` line, and you may not respond to your own finding.

6. Review the document for unresolved design, safety, correctness, implementation-plan, or protocol concerns.
7. For each concern, append a top-level blockquote line using a unique id. Ids must match `[A-Za-z0-9_-]+`:
   `> [reviewer:<id>] <concern>`
8. Immediately after each reviewer line, add the required disclosure line:
   `> — via <your-model-id>`
9. Reuse no ids already present in `[reviewer:<id>]` or `[author: resolved:<id>]`.
10. Flip the marker last:
    - If any concern is open, including pre-existing unresolved concerns, change `awaiting-reviewer` to `awaiting-author`.
    - If no reviewer concerns are open, change it to `converged`.
11. Do not proceed to implementation, commits, or PR work.

## Review Standard

Prefer a small number of high-signal concerns over exhaustive commentary. A good concern is actionable, tied to the doc's stated goal, and explains the failure mode or ambiguity the author should resolve.

Use ids like `r1`, `r2`, or `missing-timeout` when the doc already has numbered ids. Preserve existing author and reviewer comments.

## Waiting for your turn (default — do this unless the user says otherwise)

Nothing wakes this session when the author hands the doc back, so after flipping to
`awaiting-author` (and whenever you find the doc in that state), wait for your turn:

    bash .agents/skills/dual-review/scripts/dual-agent-wait.sh "<doc>" awaiting-reviewer

Branch on its exit code:

- **0** — your turn again: re-read the doc and review (step 6 onward).
- **9** — bound hit, nothing happened yet: run the same command again. Chain as many
  waits as your harness allows; tell the user to re-invoke `/dual-review <doc>` only if
  you cannot keep waiting.
- **10** — the review reached `converged`/`exhausted`: stop at the human gate.

The wait script is lock-free and read-only, so it cannot disturb the author's watcher.
NEVER run `.agents/skills/dual-review/scripts/dual-agent-watch.sh` yourself — its lock takeover would kill the
author's watcher.

## Output

After each round, summarize:

- Whether concerns were added or the doc converged.
- The ids added.
- That the marker was flipped as the final edit.
- That you are now waiting for the author (or, if you cannot keep waiting, that the user
  should re-invoke `/dual-review <doc>` for the next round). Skip when converged or
  exhausted.
