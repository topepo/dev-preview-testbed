#!/usr/bin/env bash
#
# publish-dev.sh -- publish a *dev preview* of this book to the staging site.
#
# Each preview gets its own subdirectory of the staging site, so any number of
# them can coexist: one per branch, one per PR, one per experiment.
#
#     ./publish-dev.sh pr-123       ->  https://dev.aml4td.org/pr-123/
#     ./publish-dev.sh cls-linear   ->  https://dev.aml4td.org/cls-linear/
#     ./publish-dev.sh              ->  slug derived from the current branch
#
# Retire one with:  ./cleanup-dev.sh --unpublish pr-123
# List them with:   ./cleanup-dev.sh --list
#
#
# WHY THIS EXISTS INSTEAD OF `quarto publish gh-pages`
# ----------------------------------------------------
# `quarto publish gh-pages` always pushes to the *origin* remote's *gh-pages*
# branch. Both are hardcoded, with no --remote/--branch flag. Production
# (aml4td.org) owns that slot already, and GitHub Pages serves exactly one site
# per repository, so previews have to live somewhere else. This script renders
# with Quarto and then does the push itself, with plain git, aimed at a separate
# staging repository.
#
# It also fixes one thing `quarto publish` gets wrong for long-lived sites: that
# command copies render output over the existing branch without cleaning it, so
# files belonging to deleted chapters linger indefinitely. The rsync --delete in
# step 5 removes them.
#
#
# WHAT IT TOUCHES  (cleanup-dev.sh can undo all of it)
# ----------------------------------------------------
#   1. Writes a temporary Quarto profile, _quarto-dev-<slug>.yml, in the project
#      root. A profile is the only way to override site-url and
#      google-analytics for one build: `--metadata-file` does not reach
#      project-level config, it only lands in *format* metadata, so it cannot
#      set book.site-url. The EXIT trap below removes the file even on Ctrl-C or
#      a failed render.
#   2. Renders into _book-dev/<slug>/ (git-ignored). Production's _book/ is
#      never touched, so this is safe to run with a production build in place.
#   3. Maintains a persistent clone of the staging repo at $DEV_CLONE_DIR,
#      outside this repository.
#
#   NOT undone, on purpose: rendering may update the *tracked* _freeze/
#   directory. That is normal Quarto behaviour and reverting it would throw away
#   real computation, so `git status` may show changes after a dev build.
#
#
# ONE-TIME SETUP
# --------------
#   gh repo create aml4td/dev --public
#   gh api -X POST repos/aml4td/dev/pages \
#       -f 'source[branch]=gh-pages' -f 'source[path]=/'
#   # for the custom domain, add a DNS CNAME: dev.aml4td.org -> aml4td.github.io
#
# ---------------------------------------------------------------------------

# -e            stop at the first failing command, so a broken render is never
#               published.
# -u            an unset variable is an error, which catches config typos.
# -o pipefail   a failure anywhere in a pipeline fails the whole pipeline.
set -euo pipefail

# Load shared configuration and helpers from next to this script, so it works
# regardless of the directory it is invoked from.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dev-site-common.sh
source "$script_dir/dev-site-common.sh"

# Quarto resolves _quarto.yml and profile files relative to the project root,
# so work from there throughout.
project_root="$(dev_project_root)"
cd "$project_root"

# ---------------------------------------------------------------------------
# Work out the slug: this preview's subdirectory name and URL path segment.
# ---------------------------------------------------------------------------
branch="$(git rev-parse --abbrev-ref HEAD)"
short_sha="$(git rev-parse --short HEAD)"

# An explicit argument wins; otherwise name the preview after the branch.
raw_slug="${1:-$branch}"
slug="$(dev_slugify "$raw_slug")"

if [[ -z $slug ]]; then
  echo "publish-dev.sh: could not derive a usable slug from '$raw_slug'" >&2
  exit 1
fi

# Derived names. profile_name is what goes in QUARTO_PROFILE; profile_file is
# the file Quarto then looks for.
profile_name="${DEV_PROFILE_PREFIX}${slug}"
profile_file="_quarto-${profile_name}.yml"
out_dir="$DEV_OUT_ROOT/$slug"
preview_url="$DEV_BASE_URL/$slug/"

# ---------------------------------------------------------------------------
# Cleanup trap: runs on normal exit, on error (via set -e), and on Ctrl-C, so
# the generated profile never outlives the run.
#
# $? is captured first because the commands inside the trap would overwrite it;
# `return $rc` then preserves the script's real exit status.
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  rm -f "$project_root/$profile_file"
  if (( rc != 0 )); then
    echo ""
    echo "publish-dev.sh: failed (exit $rc) -- nothing was pushed."
    echo "  Removed the temporary profile $profile_file."
    echo "  For a fuller reset (stale profiles, output dirs, staging clone):"
    echo "      ./cleanup-dev.sh --all"
  fi
  return $rc
}
trap cleanup EXIT INT TERM

echo "==> preview '$slug' from branch '$branch' ($short_sha)"
echo "    URL: $preview_url"

# ---------------------------------------------------------------------------
# Step 1. Generate this preview's temporary Quarto profile.
#
# site-url          each preview sits at its own path, and site-url is what
#                   feeds sitemap.xml plus the canonical and og:url tags.
#                   `quarto publish` only fixes site-url up automatically when
#                   *it* runs the render, so with a separate render step
#                   nothing else sets it.
# google-analytics  the empty string switches analytics off: it is falsy in
#                   Quarto's analytics check, so no gtag snippet is emitted.
#                   `null` or `false` would fail schema validation instead of
#                   disabling it.
#
# CNAME cannot be handled here. Profile `resources:` lists are *concatenated*
# with the base config's rather than replacing them, so the production CNAME
# ships no matter what this file says; step 3 deletes it from the output.
# ---------------------------------------------------------------------------
cat > "$profile_file" <<YAML
# Generated by publish-dev.sh for the '$slug' preview. Safe to delete.
book:
  site-url: $preview_url
  google-analytics: ""
YAML

# ---------------------------------------------------------------------------
# Step 2. Render. The profile supplies the dev metadata; --output-dir keeps the
# build out of production's _book/. Committed _freeze/ results are reused, so
# this is normally far faster than a cold render.
# ---------------------------------------------------------------------------
echo "==> rendering with profile '$profile_name' into $out_dir/"
QUARTO_PROFILE="$profile_name" quarto render --output-dir "$out_dir"

# ---------------------------------------------------------------------------
# Step 3. Fix up the rendered output.
#
# Dropping CNAME matters: it contains "aml4td.org", and a CNAME naming the
# production domain inside the staging repository would make that repo try to
# claim aml4td.org, breaking one of the two sites. The staging site's own CNAME
# is written once at the branch root, by dev_write_root_files in step 6.
# ---------------------------------------------------------------------------
rm -f "$out_dir/CNAME"

# ---------------------------------------------------------------------------
# Step 4. Put the staging clone into a pristine mirror of the remote branch,
# cloning it on first use. (See dev_refresh_clone for why it also runs
# `git clean` -- that is what makes a previously interrupted run harmless.)
# ---------------------------------------------------------------------------
dev_refresh_clone

# ---------------------------------------------------------------------------
# Step 5. Copy this preview into its own subdirectory of the staging branch.
#
# --delete is scoped to $slug/, so stale files from a deleted chapter go away
# while every *other* preview is left untouched.
# ---------------------------------------------------------------------------
echo "==> syncing $out_dir/ -> $DEV_BRANCH:$slug/"
mkdir -p "$DEV_CLONE_DIR/$slug"
rsync -a --delete --exclude '.git' "$out_dir/" "$DEV_CLONE_DIR/$slug/"

# ---------------------------------------------------------------------------
# Step 6. Refresh the staging root (.nojekyll, CNAME, robots.txt, preview
# index), then commit and push.
# ---------------------------------------------------------------------------
dev_write_root_files
dev_commit_and_push "dev preview: $slug from $branch@$short_sha"

echo ""
echo "==> published: $preview_url"
echo "    GitHub Pages usually needs a minute, and caches aggressively -- a"
echo "    hard refresh may be required to see changes."
