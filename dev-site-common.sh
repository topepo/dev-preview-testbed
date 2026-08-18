#!/usr/bin/env bash
#
# dev-site-common.sh -- shared configuration and helpers for the dev preview
# scripts. Sourced by publish-dev.sh and cleanup-dev.sh; not meant to be run
# directly.
#
# Everything that both scripts need to agree on lives here, so that a change to
# (say) the staging remote or the slug rules can't leave the publisher and the
# cleaner with different ideas about where things are.
#
# ---------------------------------------------------------------------------
# Configuration. Every value can be overridden from the environment:
#
#     DEV_DOMAIN= ./publish-dev.sh pr-9     # use aml4td.github.io/dev instead
#     DEV_REMOTE=git@github.com:me/scratch.git ./publish-dev.sh
# ---------------------------------------------------------------------------

# Staging repository that hosts the previews. This is NOT the book's origin --
# GitHub Pages serves one site per repo, and origin's gh-pages is production.
DEV_REMOTE="${DEV_REMOTE:-git@github.com:aml4td/dev.git}"

# Custom domain for the staging site. Set to empty to serve from the default
# github.io address instead (DEV_BASE_URL then falls back to match).
DEV_DOMAIN="${DEV_DOMAIN:-dev.aml4td.org}"

# Public root of the staging site; each preview hangs off this. No trailing slash.
DEV_BASE_URL="${DEV_BASE_URL:-https://${DEV_DOMAIN:-aml4td.github.io/dev}}"

# Branch that GitHub Pages serves in the staging repository.
DEV_BRANCH="${DEV_BRANCH:-gh-pages}"

# Persistent working clone of the staging repo. Deliberately outside the project
# (and outside $TMPDIR, which macOS prunes) so that pushes stay incremental
# rather than re-uploading the entire site every run.
DEV_CLONE_DIR="${DEV_CLONE_DIR:-$HOME/.cache/aml4td-dev-pages}"

# Parent directory for dev render output. Add /_book-dev/ to .gitignore.
DEV_OUT_ROOT="${DEV_OUT_ROOT:-_book-dev}"

# Prefix for the temporary per-preview Quarto profiles. A profile named
# "dev-pr-123" is read by Quarto from the file "_quarto-dev-pr-123.yml".
DEV_PROFILE_PREFIX="${DEV_PROFILE_PREFIX:-dev-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# dev_project_root
#   Absolute path to the top of the book repository, so either script can be
#   run from any subdirectory.
dev_project_root() {
  git rev-parse --show-toplevel
}

# dev_slugify <text>
#   Turn arbitrary text (usually a branch name) into something safe to use as
#   both a directory name and a URL path segment: lowercase, with every run of
#   characters outside [a-z0-9._-] collapsed to a single dash, and no leading or
#   trailing dashes/dots.
#
#   This is what maps a branch like "feature/Fix Typos" to "feature-fix-typos".
#   It is also a safety check: it defuses path traversal such as "../.." before
#   the value is ever used to build a path.
dev_slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9._-]\{1,\}/-/g' -e 's/^[-.]\{1,\}//' -e 's/[-.]\{1,\}$//'
}

# dev_refresh_clone
#   Bring $DEV_CLONE_DIR to a pristine mirror of the staging branch, cloning it
#   first if necessary.
#
#   The `git clean -fdx` is the important part for interrupt safety: `reset
#   --hard` only restores *tracked* files, so an rsync that died halfway leaves
#   stray untracked files behind, and a later `git add -A` would happily commit
#   them. Cleaning first guarantees every run starts from exactly what the
#   remote has.
dev_refresh_clone() {
  if [[ -d $DEV_CLONE_DIR/.git ]]; then
    echo "==> refreshing staging clone at $DEV_CLONE_DIR"
    git -C "$DEV_CLONE_DIR" fetch --quiet origin "$DEV_BRANCH"
    git -C "$DEV_CLONE_DIR" reset --quiet --hard FETCH_HEAD
    git -C "$DEV_CLONE_DIR" clean --quiet -fdx
  else
    echo "==> cloning staging repo into $DEV_CLONE_DIR"
    mkdir -p "$(dirname "$DEV_CLONE_DIR")"
    # A brand-new staging repo has no gh-pages branch yet, so the clone fails.
    # Fall back to an empty repo with the branch created locally; the first
    # push then publishes it.
    if ! git clone --quiet --single-branch --branch "$DEV_BRANCH" \
          "$DEV_REMOTE" "$DEV_CLONE_DIR" 2>/dev/null; then
      echo "    (no '$DEV_BRANCH' branch on the remote yet -- creating it)"
      git init --quiet "$DEV_CLONE_DIR"
      git -C "$DEV_CLONE_DIR" checkout --quiet -b "$DEV_BRANCH"
      git -C "$DEV_CLONE_DIR" remote add origin "$DEV_REMOTE"
    fi
  fi
}

# dev_list_previews
#   Names of the previews currently present in the staging clone: every
#   top-level directory except .git.
dev_list_previews() {
  local dir name
  for dir in "$DEV_CLONE_DIR"/*/; do
    [[ -d $dir ]] || continue                 # no matches -> the glob itself
    name="$(basename "$dir")"
    [[ $name == ".git" ]] && continue
    printf '%s\n' "$name"
  done
}

# dev_write_root_files
#   (Re)write the files that belong at the root of the staging site. Called
#   after any change to the set of previews -- by publish-dev.sh when adding
#   one, and by cleanup-dev.sh when retiring one -- so the index never points
#   at a preview that is no longer there.
dev_write_root_files() {
  # .nojekyll stops GitHub Pages from running Jekyll, which would otherwise
  # hide every directory whose name starts with an underscore.
  touch "$DEV_CLONE_DIR/.nojekyll"

  # Claim the staging domain, or drop a stale CNAME if DEV_DOMAIN was cleared.
  #
  # Note this is the *staging* domain. The book's own CNAME (aml4td.org) is
  # listed under `resources:` in _quarto.yml and so gets copied into every
  # render; publish-dev.sh deletes it from the output before syncing, because a
  # CNAME naming the production domain in this repo would make it try to claim
  # aml4td.org and break one of the two sites.
  if [[ -n $DEV_DOMAIN ]]; then
    printf '%s\n' "$DEV_DOMAIN" > "$DEV_CLONE_DIR/CNAME"
  else
    rm -f "$DEV_CLONE_DIR/CNAME"
  fi

  # Keep previews out of search results: they are drafts of a site that already
  # ranks, so indexing them invites duplicate-content competition with
  # aml4td.org. Only the root robots.txt is honoured by crawlers, so the
  # per-preview ones Quarto generates alongside each sitemap are harmless.
  printf 'User-agent: *\nDisallow: /\n' > "$DEV_CLONE_DIR/robots.txt"

  # A plain index listing the live previews, so they stay discoverable without
  # anyone having to keep notes on which slugs exist.
  {
    echo '<!doctype html>'
    echo '<meta charset="utf-8">'
    echo '<meta name="robots" content="noindex">'
    echo '<title>aml4td dev previews</title>'
    echo '<h1>Dev previews</h1>'
    echo '<ul>'
    local name
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      printf '  <li><a href="%s/">%s</a></li>\n' "$name" "$name"
    done < <(dev_list_previews)
    echo '</ul>'
    printf '<p>Updated %s</p>\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
  } > "$DEV_CLONE_DIR/index.html"
}

# dev_commit_and_push <message>
#   Stage everything in the staging clone and push, treating "nothing changed"
#   as success rather than failure.
#
#   The push is deliberately NOT forced: dev_refresh_clone already reset the
#   clone onto the remote tip, so this is a fast-forward. If it is somehow
#   rejected that is a real conflict worth seeing, not something to overwrite.
dev_commit_and_push() {
  local message="$1"

  git -C "$DEV_CLONE_DIR" add -A

  if git -C "$DEV_CLONE_DIR" diff --cached --quiet; then
    echo "==> no changes to publish"
    return 0
  fi

  git -C "$DEV_CLONE_DIR" commit --quiet -m "$message"
  echo "==> pushing to $DEV_REMOTE ($DEV_BRANCH)"
  git -C "$DEV_CLONE_DIR" push --quiet --set-upstream origin "$DEV_BRANCH"
}
