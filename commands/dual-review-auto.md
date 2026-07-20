---
description: Autonomous dual-agent review — run the review loop unattended via the Codex plugin, ending at the human gate.
argument-hint: "[doc-path | PR-URL]"
---

You are the **author** driving an **autonomous** dual-agent review. You run the whole loop in
this session — taking author turns directly and summoning the Codex reviewer via the plugin —
with no human input until the marker is `converged`/`exhausted`. **Never advance past the human
gate.** Requires `codex-plugin-cc` installed and `/codex:setup` → ready.

## §0–§2 Classify, resolve, arm — exactly as `/dual-review`

Follow `dual-review.md` §0 (classify arg), §1 (resolve doc), and §2 (arm:
`dual-agent-egress-guard.sh` then `dual-agent-core.sh init`) **verbatim**, with ONE difference:
**do NOT arm a watcher.** This loop is synchronous — you observe each Codex turn's completion —
so the watcher/wait machinery is unused. After `init`, read the marker and enter §3.

## §3 The loop

Repeat until `dual-agent-auto-step.sh` returns `terminal` (§4) or `stop` (§5):

1. Record `prev_state` and `prev_round` from `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh marker "<doc>"`.
2. Branch on `prev_state`:
   - **`awaiting-author`** → take the author/peer turn **exactly as `dual-review.md §3`
     prescribes for the mode** (`${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-peer.sh mode "<doc>"`): asymmetric →
     resolve each open `[reviewer:]` thread; peer-review → respond to the **other model's**
     open findings only (resolve each open finding's `> — via` raiser; respond only where it
     is **not** `claude-opus-4-8`) and optionally raise your own as `> [finding:<id>|<sev>] <terse concern>` + `> — via
     claude-opus-4-8` + `> — risk: <short risk>` (`<sev>` ∈ high/med/low). When raising a new
     finding you MAY anchor it by adding a `> — at <path>:<line>` (or `<path>:<start>-<end>`) line
     immediately after the finding's `> — risk:` line, using RIGHT-side new-file line numbers
     from the `## Diff`. Optional; omit if unsure. Disclose every line
     `> — via claude-opus-4-8`. Then `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh next-marker "<doc>" author-done`.
   - **`awaiting-reviewer`** → run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-codex-prompt.sh "<doc>"`, then dispatch
     the **`codex:codex-rescue`** agent with `--model gpt-5.5 --write` followed by that prompt, and
     wait for it to complete. Both flags are runtime controls the agent forwards to Codex — stripped
     from the task text, never part of the reviewer's payload (see Egress). Pin `--model gpt-5.5` so
     the reviewer is the real GPT model rather than the agent's Claude (`sonnet`) wrapper, and so the
     `> — via` disclosure stays consistent. Pin `--write` because the reviewer MUST write into the
     scratch doc — it appends its findings and flips the status marker (`awaiting-reviewer` →
     `awaiting-author`/`converged`) as its final edit. Without it the `codex:codex-rescue` wrapper
     reads the review-shaped prompt ("Review EXACTLY this document… Read only that document") and
     selects a read-only sandbox, so the writes are silently rejected, the marker never flips, and
     `auto-step` dead-ends with `stop illegal-transition` at round 1 for a sandbox reason, not a
     review reason. The prompt is the entire review payload.
3. After the turn, run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-auto-step.sh "<doc>" "<prev_state>" "<prev_round>"`:
   - `continue …` (exit 0) → loop.
   - `terminal …` (exit 10) → go to §4.
   - `stop …` (exit 20) → go to §5.

## §4 Terminal — human gate

`auto-step` returns `terminal <state>`. Branch on `<state>` (`${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh marker
"<doc>"`) — `converged` and `exhausted` are NOT handled the same way:

- **`converged`** → run the matching convergence check (only one):
  - **asymmetric** → `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-core.sh check-converged "<doc>"`.
  - **peer-review** → `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-peer.sh check-converged "<doc>"`.
  If it passes, present the annotated doc + a round-by-round summary and tell the engineer:
  "converged — please review and approve before implementation or PR." In **PR mode**, ask
  whether to post; ONLY on explicit approval run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-pr.sh publish "<doc>"
  "claude-opus-4-8"`. If the check FAILS (an inconsistency), treat it as §5.
- **`exhausted`** → the round bound was reached WITHOUT convergence. This is a valid terminal,
  NOT an anomaly — do NOT run a convergence check (open concerns are expected). Present the
  annotated doc + round trail with the still-open concerns made explicit, and tell the engineer:
  "round bound reached without convergence — escalate to a human." In **PR mode**, you MAY offer
  to post the annotated review; ONLY on explicit approval run `${CLAUDE_PLUGIN_ROOT}/scripts/dual-agent-pr.sh publish
  "<doc>" "claude-opus-4-8"`.

STOP — never implement, commit, or open a PR from this command.

## §5 Anomaly stop — human gate

Print the `stop <reason>` from `auto-step` and the partial round trail, and STOP at the human
gate. **Do not retry, do not re-dispatch, do not edit the marker.** A `stop` means a turn was
non-conformant (e.g. Codex did not flip the marker, an illegal transition, or a malformed doc)
or a Codex dispatch failed — surface it for a human.

## Egress & guardrails

- Arming uses the same mechanical egress guard as `/dual-review`; no new arming path.
- The only payload handed to the plugin is the `dual-agent-codex-prompt.sh` output (canonical
  doc path + skill pointer). Inject no env, secrets, repo contents, or diffs. The `--model gpt-5.5`
  and `--write` flags on the dispatch are runtime controls (model selection + sandbox mode) that
  are stripped from the task text — they are NOT payload and do not widen this rule.
- The reviewer's *read only that document* scope limit is a **trust** contract carried in the
  prompt, unchanged. Note it is not sandbox-enforced: `--write` gives the reviewer a
  `workspace-write` sandbox (required so it can append findings and flip the marker), so the
  scope limit rests on the prompt, not the sandbox. Human gate is inviolable: no auto-merge, no
  auto-post.
- Turn-taking is the marker only. If `auto-step` says `stop`, the loop is over until a human acts.
