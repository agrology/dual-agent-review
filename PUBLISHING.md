# Publishing to a public repo

Removing files from the working tree does **not** remove them from git history. Before this
repo is made public, all history must be clean of internal references.

## Gate (must pass)

    bash scripts/dual-agent-history-check.sh .

Exit 0 = safe. Non-zero prints the offending commits/blobs — do not publish until clean.

## Two safe routes

1. **Fresh-history export (preferred).** Publish the cleaned tree to a NEW public repo with no
   inherited history:

       git checkout --orphan public-main
       git commit -m "Initial public release"
       # push public-main to the new public remote as its main branch

2. **History scrub.** Use `git filter-repo` to purge the excluded paths and the sensitivity
   terms from ALL refs, then re-run the gate:

       git filter-repo --path docs/specs --path docs/plans --path docs/superpowers \
         --path .superpowers --path .dual-agent --invert-paths
       bash scripts/dual-agent-history-check.sh .

Only flip the GitHub repo to public after the gate passes.

---

## Distributing via a plugin marketplace

Once the repo is public it is installable directly (`/plugin install agrology/dual-agent-review`).
To make it **discoverable** — browsable in the plugin UI's Discover tab, with version tracking
and update prompts — this repo also ships a self-hosted marketplace at
`.claude-plugin/marketplace.json`. Users add it with:

    /plugin marketplace add agrology/dual-agent-review
    /plugin install dual-agent-review@agrology

The marketplace is self-hosted: the same repo is both the plugin and its catalog, so there is
nothing else to maintain. The plugin entry uses a `github` source (not a relative path) so it
resolves regardless of how a user adds the marketplace — see the Claude Code docs on
[plugin marketplaces](https://code.claude.com/docs/en/plugin-marketplaces) and
[discovering plugins](https://code.claude.com/docs/en/discover-plugins).

The marketplace `name` (`agrology`) must not collide with the reserved Anthropic names; the
packaging test (`scripts/dual-agent-packaging.test.sh`) enforces that, along with the required
manifest keys and that every plugin entry carries a `name` and `source`.

**Submitting to Anthropic's directory (optional, separate, human decision).** There are two
Anthropic marketplaces. `claude-plugins-official` is Anthropic-curated with **no** submission
process — inclusion is at their discretion. `anthropics/claude-plugins-community` accepts
reviewed third-party submissions via Anthropic's plugin-submission form. Submitting is an
outward-facing publishing decision for a maintainer to make deliberately; it is not part of
this repo's automation. Verify the current submission URL and review criteria in Anthropic's
own docs before submitting — do not rely on a link pasted here going stale.
