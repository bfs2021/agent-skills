#!/usr/bin/env bash
# pr-ready.sh [--codex] <pr-number>
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
# - Review (default): the other-family review is a comment the orchestrator posts with
#   post-review.sh, from the account gh is signed in as. The newest such comment naming the head
#   sha decides: it passes when it says "Open findings: 0". A comment that names an older sha is
#   stale (a push landed after the review), and no comment at all is "not posted". Comments from
#   anyone else are ignored, so nobody else can forge a pass.
# - Review (--codex): for repos whose second reviewer is the Codex bot. The summary marker
#   comment exists and every row of its table says Completed. The bot reviews when a PR opens, is
#   marked ready, or is asked to (@codex review), not on every push.
# - Findings: every inline thread Codex started that is still unresolved, in either mode, since
#   the bot's GitHub app may still post. An outdated one (a push changed the commented lines) is
#   flagged, not dropped: GitHub marks a thread outdated whether or not the push fixed it, and
#   the bot doesn't re-review, so a thread only clears when someone verifies the fix (or that
#   the finding isn't real) and resolves it. Each finding carries its thread id for
#   resolve-thread.sh, which is the narrow way to do that.
# - The bot is matched by exact login and the Bot account type, so a lookalike account can't forge
#   the summary or a finding.

set -u
set -o pipefail

CODEX_LOGIN="chatgpt-codex-connector"
SUMMARY_MARKER="<!-- codex-pull-request-review-summary -->"
FINDING_CHARS=120

die() {
  echo "pr-ready: $*" >&2
  exit 2
}

mode="comment"
if [ "${1:-}" = "--codex" ]; then
  mode="codex"
  shift
fi
pr="${1:-}"
case "$pr" in
  '' | *[!0-9]*) die "usage: pr-ready.sh [--codex] <pr-number>" ;;
esac

repo=$(gh api 'repos/{owner}/{repo}' --jq .full_name) || die "can't resolve owner/repo"
owner="${repo%%/*}"
name="${repo#*/}"

# gojq (inside gh --jq) prints strings raw; each output line is TAB-separated, with no empty fields.
pr_jq='
def codex: .author.__typename == "Bot" and .author.login == "'"$CODEX_LOGIN"'";
def line($re): map(select(test($re))) | .[0];
def review:
  (.body | split("\n")) as $l
  | ($l | line("^Reviewed sha: [0-9a-f]{7,40}[ ]*$")) as $s
  | ($l | line("^Open findings: [0-9]+[ ]*$")) as $o
  | ($l | line("^Reviewer: .+$")) as $r
  | if $s == null or $o == null then empty
    else {sha: ($s | capture("(?<x>[0-9a-f]{7,40})").x),
          open: ($o | capture("(?<n>[0-9]+)").n | tonumber),
          who: (if $r == null then "-" else ($r | sub("^Reviewer: "; "") | sub("[ ]+$"; "")) end)}
    end;
.data.viewer.login as $me
| .data.repository.pullRequest
| .headRefOid as $head
| "head\t\(.headRefOid)",
  "state\t\(.state)",
  "draft\t\(.isDraft)",
  "merge\t\(.mergeable)\t\(.mergeStateStatus)",
  ( [.comments.nodes[] | select(codex and (.body | contains("'"$SUMMARY_MARKER"'")))] | last // null
    | if . == null then "summary\tnone\t-"
      else (.body | split("\n") | map(select(startswith("| ") and contains("**")))) as $rows
        | "summary\t\(if ($rows | length) > 0 and ($rows | all(contains("**Completed**"))) then "complete" else "running" end)\t\(([$rows[] | capture("`(?<s>[0-9a-f]{7,40})`") | .s] | last) // "-")"
      end ),
  ( [.comments.nodes[] | select(.author.login == $me) | review] as $revs
    | ([$revs[] | select(.sha as $x | $head | startswith($x))] | last) as $cur
    | if $cur != null then "review\tcurrent\t\($cur.sha[0:10])\t\($cur.open)\t\($cur.who)"
      elif ($revs | length) > 0 then "review\tstale\t\($revs | last | .sha[0:10])\t0\t-"
      else "review\tnone\t-\t0\t-" end ),
  "threads\t\(.reviewThreads.pageInfo.hasNextPage)",
  ( .reviewThreads.nodes[]
    | select((.isResolved | not) and (.comments.nodes[0] | codex))
    | .comments.nodes[0].body as $b
    | "finding\t\(.path):\(.line // .originalLine)\t\((($b | capture("!\\[(?<p>P[0-9]+) Badge\\]") | .p) // "P?"))\t\(.id)\t\(if .isOutdated then "(outdated) " else "" end)\($b | split("\n")[0] | gsub("<[^>]*>|!\\[[^\\]]*\\]\\([^)]*\\)|\\*\\*"; "") | gsub("^\\s+|\\s+$"; "") | .[0:'"$FINDING_CHARS"'])" )
'

pr_query='
query($owner: String!, $name: String!, $num: Int!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    pullRequest(number: $num) {
      state isDraft mergeable mergeStateStatus headRefOid
      comments(last: 100) { nodes { body author { __typename login } } }
      reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes {
          id isResolved isOutdated path line originalLine
          comments(first: 1) { nodes { body author { __typename login } } }
        }
      }
    }
  }
}'

pr_lines=$(gh api graphql -f owner="$owner" -f name="$name" -F num="$pr" -f query="$pr_query" --jq "$pr_jq") \
  || die "can't read PR #$pr in $repo"

head_sha="" pr_state="" is_draft="" mergeable="" merge_state="" summary="none" summary_sha="-" threads_more="false"
rev_state="none" rev_sha="-" rev_open=0 rev_who="-"
findings=""
finding_count=0
while IFS=$'\t' read -r key f1 f2 f3 f4; do
  case "$key" in
    head) head_sha="$f1" ;;
    state) pr_state="$f1" ;;
    draft) is_draft="$f1" ;;
    merge) mergeable="$f1" merge_state="$f2" ;;
    summary) summary="$f1" summary_sha="$f2" ;;
    review) rev_state="$f1" rev_sha="$f2" rev_open="$f3" rev_who="$f4" ;;
    threads) threads_more="$f1" ;;
    finding)
      finding_count=$((finding_count + 1))
      if [ -n "$findings" ]; then findings="$findings | "; fi
      findings="$findings$f1 $f2 $f3 $f4"
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

if [ "$mode" = "codex" ]; then
  review_label="codex summary"
  case "$summary" in
    complete) review_out="posted, completed on ${summary_sha}" ;;
    running)
      review_out="posted, not marked Completed"
      ready=0
      ;;
    *)
      review_out="not posted"
      ready=0
      ;;
  esac
else
  review_label="review"
  case "$rev_state" in
    current)
      if [ "$rev_open" -eq 0 ]; then
        review_out="posted on ${rev_sha} by ${rev_who}, 0 open"
      else
        review_out="posted on ${rev_sha} by ${rev_who}, ${rev_open} open"
        ready=0
      fi
      ;;
    stale)
      review_out="stale (reviewed ${rev_sha}, head moved)"
      ready=0
      ;;
    *)
      review_out="not posted"
      ready=0
      ;;
  esac
fi

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
echo "$review_label: $review_out"
echo "findings: $findings_out"
echo "mergeable: $merge_out"

[ "$ready" -eq 1 ]
