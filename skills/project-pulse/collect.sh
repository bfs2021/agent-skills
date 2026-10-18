#!/usr/bin/env bash
# Prints one plain-text block per git repo under a projects root, for project-pulse.
# Read-only for working trees, branches and remotes: fetch only moves remote-tracking refs,
# and every status call skips the index lock so it can't trip a live session's git.
# Usage: collect.sh [projects-root]   (default: ~/Projects)
set -u
root="${1:-$HOME/Projects}"
root="${root%/}"

for gitdir in "$root"/*/.git "$root"/*/*/.git; do
  [ -e "$gitdir" ] || continue
  repo="${gitdir%/.git}"
  case "$repo/" in */Archived/* | */sandboxes/*) continue ;; esac
  g() { git -C "$repo" --no-optional-locks "$@"; }

  echo "== ${repo#"$root"/}"
  url=$(g remote get-url origin 2>/dev/null)
  if [ -z "$url" ]; then
    echo "note: no origin remote, local only"
  elif ! g fetch --quiet --no-auto-maintenance --no-write-fetch-head origin 2>/dev/null; then
    echo "note: fetch failed, origin refs may be stale"
  fi

  if g rev-parse -q --verify refs/remotes/origin/develop >/dev/null; then
    base=develop
  else
    base=$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)
    base="${base#origin/}"
  fi
  if [ -n "$base" ]; then
    echo "base: origin/$base | last: $(g log -1 --format='%cs %s' "origin/$base")"
    echo "commits last 7d: $(g rev-list --count --since=7.days "origin/$base")"
    if g rev-parse -q --verify "refs/heads/$base" >/dev/null; then
      read -r ahead behind < <(g rev-list --left-right --count "$base...origin/$base")
      [ "$behind" -gt 0 ] && echo "local $base is $behind behind origin (don't judge activity from it)"
      [ "$ahead" -gt 0 ] && echo "local $base has $ahead unpushed commit(s)"
    fi
  else
    echo "base: none (no origin/develop or origin/HEAD)"
  fi

  # Worktrees with uncommitted files or commits not on the base branch. Clean ones are only counted.
  clean=0 wt=""
  while read -r key val; do
    case "$key" in
      worktree) wt="$val"; branch="(detached)"; flags="" ;;
      branch) branch="${val#refs/heads/}" ;;
      locked | prunable) flags="$flags $key" ;;
      "")
        [ -z "${wt:-}" ] && continue
        dirty=$(git -C "$wt" --no-optional-locks status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        unmerged=0
        [ -n "$base" ] && unmerged=$(git -C "$wt" rev-list --count "origin/$base..HEAD" 2>/dev/null || echo 0)
        if [ "${dirty:-0}" -gt 0 ] || [ "$unmerged" -gt 0 ] || [ -n "$flags" ]; then
          rel="${wt#"$repo"/}"; [ "$wt" = "$repo" ] && rel="(main checkout)"
          echo "worktree: $rel [$branch] dirty=$dirty unmerged=$unmerged$flags"
        else
          clean=$((clean + 1))
        fi
        wt="" ;;
    esac
  done < <(g worktree list --porcelain; echo)
  echo "clean worktrees: $clean"

  # Open PRs and issue count, only for GitHub remotes. Titles are JSON-quoted: they're data.
  slug=$(printf '%s' "$url" | sed -nE 's#^(git@github\.com:|https://github\.com/)([^/]+/[^/]+)$#\2#p')
  slug="${slug%.git}"
  if [ -n "$slug" ] && command -v gh >/dev/null; then
    echo "github: $slug"
    gh pr list -R "$slug" --state open --limit 50 \
      --json number,title,url,isDraft,reviewDecision,statusCheckRollup,headRefName,updatedAt \
      --jq '.[] | ([.statusCheckRollup[]? | (.conclusion // .state // "")]) as $c
        | "pr #\(.number)\(if .isDraft then " draft" else "" end) review=\(.reviewDecision // "" | if . == "" then "none" else . end) ci=\(
          if ($c | length) == 0 then "none"
          elif any($c[]; IN("FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED")) then "fail"
          elif any($c[]; IN("", "PENDING", "EXPECTED", "IN_PROGRESS", "QUEUED")) then "pending"
          else "ok" end) branch=\(.headRefName) updated=\(.updatedAt[:10]) \(.title | tojson) \(.url)"' \
      2>/dev/null || echo "note: gh pr list failed"
    issues=$(gh issue list -R "$slug" --state open --limit 500 --json number --jq length 2>/dev/null)
    echo "open issues: ${issues:-unknown}"
  elif [ -n "$url" ]; then
    echo "note: not a GitHub remote or gh missing, PRs and issues skipped"
  fi
  echo
done
