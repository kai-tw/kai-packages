#!/usr/bin/env bash
# add_lines takes a file's path as a label while reading the file on stdin;
# nothing writes to it.
# shellcheck disable=SC2094
#
# disclosure_check.sh —catch private-app details before they reach this
# public repo.
#
# WHY: everything here is public, and the apps that consume these packages
# are not (see CLAUDE.md, "This repo is PUBLIC"). The surfaces that leak are
# the ones that feel like conversation — commit messages, PR titles and
# bodies — plus CHANGELOGs, READMEs and doc comments. Retracting any of them
# is far more expensive than not writing it, so this runs before the text
# leaves the machine: commit-msg and pre-push hooks, and a Claude Code hook
# on `gh pr create` and friends. CI repeats it on every PR as a backstop,
# which catches what slipped past but can't un-publish it.
#
# TWO CHECKS
#   1. Private terms. Class, widget and file names, UI copy, feature names —
#      anything lifted from a private app. The list can't live in this repo,
#      since the list itself would be the leak, so it's read from an
#      ignored file, .claude/private-terms.txt in the main checkout (or
#      $KAI_PRIVATE_TERMS_FILE), and in CI from the PRIVATE_TERMS repository
#      secret. A worktree reads the main checkout's copy, so there's one list
#      per clone. One term per line, `#` starts a comment, matched as whole
#      words, case and all. `seed` below prints candidates from an app's
#      source, and `sync-secret` copies the list to the secret.
#   2. Links to repositories a stranger can't open. Every
#      `github.com/<owner>/<repo>` and `<owner>/<repo>#N` reference is looked
#      up with `gh api`; anything that isn't public is reported. No list is
#      needed for this one.
#
# Usage:
#   tool/disclosure_check.sh text [FILE|-]      check a commit message, PR text, …
#   tool/disclosure_check.sh range BASE..HEAD   check the commit messages and the
#                                               added lines of a range
#   tool/disclosure_check.sh hook               Claude Code PreToolUse hook
#                                               (reads the tool call on stdin)
#   tool/disclosure_check.sh seed APP_DIR       print candidate private terms:
#                                               type names declared in APP_DIR/lib
#                                               that this repo never mentions
#   tool/disclosure_check.sh sync-secret        copy the term list to the
#                                               PRIVATE_TERMS secret, gzipped
#                                               and base64-encoded: a secret
#                                               holds at most 48 KB
#
# Exit status: 0 clean, 1 findings (2 in `hook` mode, which tells Claude Code
# to block the call), 64 usage error.

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=$PWD
# The main checkout, even from a worktree: the common git dir sits inside it.
main_root=$(cd "$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd) ||
  main_root=$repo_root
terms_file=${KAI_PRIVATE_TERMS_FILE:-$main_root/.claude/private-terms.txt}

work=$(mktemp -d "${TMPDIR:-/tmp}/disclosure_check.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# Each unit of input becomes one line in $texts, with where it came from on the
# same line of $locations, so a match can be reported as file:line.
texts=$work/texts
locations=$work/locations
: >"$texts"
: >"$locations"

add_lines() { # $1 location prefix; stdin: text, one line at a time
  local n=0 line
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    printf '%s\n' "$line" >>"$texts"
    printf '%s:%s\n' "$1" "$n" >>"$locations"
  done
}

add_diff() { # $1 range; adds every added line as file:line
  git -C "$repo_root" diff -U0 --no-color --no-ext-diff "$1" | awk -v texts="$texts" -v locs="$locations" '
    /^\+\+\+ / { file = substr($0, 5); sub(/^b\//, "", file); next }
    /^@@ / { if (match($0, /\+[0-9]+/)) n = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    /^\+/ && file != "/dev/null" {
      print substr($0, 2) >> texts
      print file ":" n >> locs
      n++
    }
  '
}

findings=$work/findings
: >"$findings"

report() { printf '%s\n' "$1" >>"$findings"; }

location_of() { sed -n "${1}p" "$locations"; }

check_terms() {
  local patterns=$work/patterns
  if [ ! -r "$terms_file" ]; then
    echo "disclosure_check: no private-terms list at $terms_file; only links are checked." >&2
    return
  fi
  # A tracked list is about to become public: stop everything until it isn't.
  if git -C "$main_root" ls-files --error-unmatch -- "$terms_file" >/dev/null 2>&1; then
    report "$terms_file: the private-terms list is tracked by git. Untrack it: git rm --cached"
    return
  fi
  # An empty pattern matches every line, so blank lines and comments go first.
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$terms_file" |
    grep -v '^$' >"$patterns" || true
  [ -s "$patterns" ] || return
  local hit n term
  while IFS= read -r hit; do
    n=${hit%%:*}
    term=${hit#*:}
    if [ -n "${CI:-}" ]; then
      # A public CI log would repeat the term; the location is enough.
      report "$(location_of "$n"): a term from the private list"
    else
      report "$(location_of "$n"): private term \"$term\""
    fi
  done < <(grep -n -o -w -F -f "$patterns" "$texts")
}

own_repo() {
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    echo "$GITHUB_REPOSITORY"
    return
  fi
  git -C "$repo_root" remote get-url origin 2>/dev/null |
    sed -E -e 's#\.git$##' -e 's#^.*github\.com[:/]##'
}

# Prints "public", "private" (not visible to this token: private, or gone) or
# "unknown" (couldn't ask). Cached per run.
visibility() {
  local cache=$work/visibility answer
  answer=$(grep -i "^$1 " "$cache" 2>/dev/null | head -1 | cut -d' ' -f2)
  if [ -z "$answer" ]; then
    local out
    if out=$(gh api "repos/$1" --jq .visibility 2>&1); then
      answer=$out
    elif printf '%s' "$out" | grep -q 'Not Found\|HTTP 404'; then
      answer=private
    else
      answer=unknown
    fi
    echo "$1 $answer" >>"$cache"
  fi
  echo "$answer"
}

check_links() {
  local own hit n ref repo state
  own=$(own_repo | tr '[:upper:]' '[:lower:]')
  while IFS= read -r hit; do
    n=${hit%%:*}
    ref=${hit#*:}
    repo=${ref#github.com/}
    repo=${repo%%#*}
    repo=${repo%.git}
    case "${repo%%/*}" in
      orgs | settings | apps | marketplace | features | sponsors | topics | users | enterprises | notifications | login) continue ;;
    esac
    [ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" = "$own" ] && continue
    state=$(visibility "$repo")
    case "$state" in
      public) ;;
      unknown) echo "disclosure_check: couldn't check whether $repo is public (is gh signed in?)" >&2 ;;
      *) report "$(location_of "$n"): link to $repo, which a public reader can't open" ;;
    esac
  done < <(grep -n -o -E 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+' "$texts")
}

finish() { # $1 exit status on findings
  check_terms
  check_links
  [ -s "$findings" ] || return 0
  {
    echo "BLOCKED by disclosure_check: this text would put private-app details in a public repo."
    sed 's/^/  /' "$findings"
    echo "Generalise it: \"a consuming app\", neutral example names, no private links."
    echo "If a term is a false positive, remove it from $terms_file."
  } >&2
  return "$1"
}

seed() { # $1 app directory
  local app=$1
  [ -d "$app/lib" ] || {
    echo "disclosure_check: $app has no lib/ directory" >&2
    return 64
  }
  find "$app/lib" -name '*.dart' ! -name '*.g.dart' ! -name '*.freezed.dart' -print0 |
    xargs -0 grep -h -o -E '\b(class|enum|mixin|typedef|extension( type)?) [A-Z][A-Za-z0-9_]*' |
    awk '{ print $NF }' | sort -u >"$work/declared"
  git -C "$repo_root" grep -h -o -w -E '[A-Z][A-Za-z0-9_]*' | sort -u >"$work/mentioned"
  echo "# Declared in $app/lib and not mentioned anywhere in this repo."
  echo "# Review before adding: drop names too generic to be telling."
  comm -23 "$work/declared" "$work/mentioned"
}

hook() {
  local input command file
  input=$(cat)
  command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
  # Only commands that publish text: PR and issue text, comments, releases.
  printf '%s' "$command" |
    grep -q -E '\bgh (pr|issue) (create|edit|comment|review)\b|\bgh api\b|\bgh release (create|edit)\b' ||
    return 0
  printf '%s\n' "$command" | add_lines "command"
  # --body-file / -F name a file whose contents are published too.
  while IFS= read -r file; do
    [ -f "$file" ] && add_lines "$file" <"$file"
  done < <(printf '%s' "$command" | grep -o -E '(--body-file|-F)[= ][^ ]+' | sed -E 's/^(--body-file|-F)[= ]//')
  finish 2
}

case "${1:-}" in
  text)
    if [ "${2:--}" = "-" ]; then
      add_lines "text"
    else
      add_lines "$2" <"$2"
    fi
    finish 1
    ;;
  range)
    [ -n "${2:-}" ] || {
      echo "usage: $0 range BASE..HEAD" >&2
      exit 64
    }
    for sha in $(git -C "$repo_root" rev-list "$2"); do
      git -C "$repo_root" log -1 --format=%B "$sha" | add_lines "commit ${sha:0:7} message"
    done
    add_diff "$2"
    finish 1
    ;;
  hook) hook ;;
  seed) seed "${2:?usage: $0 seed APP_DIR}" ;;
  sync-secret)
    [ -r "$terms_file" ] || {
      echo "disclosure_check: no list at $terms_file to sync" >&2
      exit 1
    }
    # Piped straight from the file, so the terms never reach an argv or a log.
    gzip -9c "$terms_file" | base64 | tr -d '\n' |
      gh secret set PRIVATE_TERMS --repo "$(own_repo)"
    ;;
  *)
    sed -n '/^# Usage:/,/^# Exit status/p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 64
    ;;
esac
