#!/usr/bin/env bash
# pr-ready.sh <pr-number>
#
# One call that answers "is this PR ready to merge?" for the review gate. Prints at most 6 lines
# and exits 0 only when every line passes. Exit 1 means not ready, exit 2 means it couldn't tell
# (bad argument, gh failure); callers that gate a merge on this should treat both as a stop.
#
# Run it from a checkout of the repo; owner/repo come from the git remote (or GH_REPO).
# Needs only `gh`, authenticated, bash 3.2 or newer.
#
# What counts, and why:
# - CI: the newest check run per check name on the head sha (a re-run replaces the run it
#   re-ran), plus commit statuses. No checks reported yet is pending, not a pass or a failure.
# - Codex summary: the marker comment exists and every row of its table says Completed. The bot
#   reviews when a PR opens, is marked ready, or is asked to (@codex review), not on every push.
# - Codex findings: inline threads Codex started that are unresolved and not outdated. Outdated
#   means GitHub saw the commented lines change, so a pushed fix drops the finding. Matching
#   original_commit_id to the head instead would drop every finding after the first later push,
#   fixed or not, because the bot doesn't re-review. To clear a finding that isn't real, resolve
#   its thread.

set -u
set -o pipefail

CODEX_LOGIN="chatgpt-codex-connector"
SUMMARY_MARKER="<!-- codex-pull-request-review-summary -->"
FINDING_CHARS=120

die() {
  echo "pr-ready: $*" >&2
  exit 2
}

pr="${1:-}"
case "$pr" in
  '' | *[!0-9]*) die "usage: pr-ready.sh <pr-number>" ;;
esac

repo=$(gh api 'repos/{owner}/{repo}' --jq .full_name) || die "can't resolve owner/repo"
owner="${repo%%/*}"
name="${repo#*/}"

# gojq (inside gh --jq) prints strings raw; each output line is TAB-separated, with no empty fields.
pr_jq='
def codex: (.author.login // "") | startswith("'"$CODEX_LOGIN"'");
.data.repository.pullRequest
| "head\t\(.headRefOid)",
  "state\t\(.state)",
  "draft\t\(.isDraft)",
  "merge\t\(.mergeable)\t\(.mergeStateStatus)",
  ( [.comments.nodes[] | select(codex and (.body | contains("'"$SUMMARY_MARKER"'")))] | last // null
    | if . == null then "summary\tnone\t-"
      else (.body | split("\n") | map(select(startswith("| ") and contains("**")))) as $rows
        | "summary\t\(if ($rows | length) > 0 and ($rows | all(contains("**Completed**"))) then "complete" else "running" end)\t\(([$rows[] | capture("`(?<s>[0-9a-f]{7,40})`") | .s] | last) // "-")"
      end ),
  "threads\t\(.reviewThreads.pageInfo.hasNextPage)",
  ( .reviewThreads.nodes[]
    | select((.isResolved | not) and (.isOutdated | not) and (.comments.nodes[0] | codex))
    | .comments.nodes[0].body as $b
    | "finding\t\(.path):\(.line // .originalLine)\t\((($b | capture("!\\[(?<p>P[0-9]+) Badge\\]") | .p) // "P?"))\t\($b | split("\n")[0] | gsub("<[^>]*>|!\\[[^\\]]*\\]\\([^)]*\\)|\\*\\*"; "") | gsub("^\\s+|\\s+$"; "") | .[0:'"$FINDING_CHARS"'])" )
'

pr_query='
query($owner: String!, $name: String!, $num: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $num) {
      state isDraft mergeable mergeStateStatus headRefOid
      comments(last: 100) { nodes { body author { login } } }
      reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          isResolved isOutdated path line originalLine
          comments(first: 1) { nodes { body author { login } } }
        }
      }
    }
  }
}'

pr_lines=$(gh api graphql -F owner="$owner" -F name="$name" -F num="$pr" -f query="$pr_query" --jq "$pr_jq") \
  || die "can't read PR #$pr in $repo"

head_sha="" pr_state="" is_draft="" mergeable="" merge_state="" summary="none" summary_sha="-" threads_more="false"
findings=""
finding_count=0
while IFS=$'\t' read -r key f1 f2 f3; do
  case "$key" in
    head) head_sha="$f1" ;;
    state) pr_state="$f1" ;;
    draft) is_draft="$f1" ;;
    merge) mergeable="$f1" merge_state="$f2" ;;
    summary) summary="$f1" summary_sha="$f2" ;;
    threads) threads_more="$f1" ;;
    finding)
      finding_count=$((finding_count + 1))
      if [ -n "$findings" ]; then findings="$findings | "; fi
      findings="$findings$f1 $f2 $f3"
      ;;
  esac
done <<<"$pr_lines"
[ -n "$head_sha" ] || die "no head sha for PR #$pr in $repo"

ci_jq='
(if .total_count > (.check_runs | length) then "overflow\t-" else empty end),
(.check_runs | group_by(.name)[] | max_by(.id)
  | "\(if .status != "completed" then "pending" elif (.conclusion | IN("success", "neutral", "skipped")) then "pass" else "fail" end)\t\(.name)")'
status_jq='
.statuses[]
| "\(if .state == "success" then "pass" elif .state == "pending" then "pending" else "fail" end)\t\(.context)"'

ci_lines=$(gh api "repos/$repo/commits/$head_sha/check-runs?filter=all&per_page=100" --jq "$ci_jq") \
  || die "can't read check runs for $head_sha"
status_lines=$(gh api "repos/$repo/commits/$head_sha/status" --jq "$status_jq") \
  || die "can't read commit statuses for $head_sha"

ci_total=0 ci_failed="" ci_pending="" ci_overflow=0
while IFS=$'\t' read -r state check; do
  [ -n "$state" ] || continue
  case "$state" in
    overflow) ci_overflow=1 ;;
    fail)
      ci_total=$((ci_total + 1))
      ci_failed="${ci_failed:+$ci_failed, }$check"
      ;;
    pending)
      ci_total=$((ci_total + 1))
      ci_pending="${ci_pending:+$ci_pending, }$check"
      ;;
    pass) ci_total=$((ci_total + 1)) ;;
  esac
done <<<"$ci_lines
$status_lines"

ready=1

if [ -n "$ci_failed" ]; then
  ci_out="fail ($ci_failed)"
  ready=0
elif [ "$ci_overflow" -eq 1 ]; then
  ci_out="unknown (more than 100 check runs)"
  ready=0
elif [ -n "$ci_pending" ]; then
  ci_out="pending ($ci_pending)"
  ready=0
elif [ "$ci_total" -eq 0 ]; then
  ci_out="pending (no checks reported)"
  ready=0
else
  ci_out="pass (n=$ci_total)"
fi

if [ "$is_draft" = "true" ]; then
  draft_out="yes"
  ready=0
else
  draft_out="no"
fi

case "$summary" in
  complete) summary_out="posted, completed on ${summary_sha}" ;;
  running)
    summary_out="posted, not marked Completed"
    ready=0
    ;;
  *)
    summary_out="not posted"
    ready=0
    ;;
esac

if [ "$threads_more" = "true" ]; then
  findings_out="unknown (more than 100 review threads)"
  ready=0
elif [ "$finding_count" -gt 0 ]; then
  findings_out="$finding_count unresolved: $findings"
  ready=0
else
  findings_out="none"
fi

if [ "$pr_state" != "OPEN" ]; then
  merge_out="n/a, PR is $pr_state"
  ready=0
else
  merge_out="$mergeable ($merge_state)"
  case "$mergeable/$merge_state" in
    MERGEABLE/CLEAN | MERGEABLE/HAS_HOOKS) ;;
    *) ready=0 ;;
  esac
fi

echo "head: $head_sha"
echo "ci: $ci_out"
echo "draft: $draft_out"
echo "codex summary: $summary_out"
echo "codex findings: $findings_out"
echo "mergeable: $merge_out"

[ "$ready" -eq 1 ]
