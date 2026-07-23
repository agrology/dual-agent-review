# Publishing to a public repo

Removing files from the working tree does **not** remove them from git history. Before this
repo is made public, all history must be clean of internal references.

## Gate (must pass)

    bash scripts/multi-review-history-check.sh .

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
         --path .superpowers --path .multi-review --invert-paths
       bash scripts/multi-review-history-check.sh .

Only flip the GitHub repo to public after the gate passes.
