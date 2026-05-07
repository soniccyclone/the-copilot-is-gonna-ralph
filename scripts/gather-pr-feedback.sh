#!/usr/bin/env bash
#
# gather-pr-feedback.sh — collect all unresolved review comments and
# discussion comments on a PR (excluding pipeline bot comments) and emit a
# single markdown bundle suitable for handing to Copilot CLI as feedback.
#
# Usage:
#   gather-pr-feedback.sh <PR_NUMBER>
#
# Env:
#   GH_TOKEN — auth for `gh api`
#   GH_REPO  — owner/repo

# shellcheck disable=SC2016
# (single-quoted $vars in GraphQL queries are query variables, not shell.)

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <PR_NUMBER>" >&2
  exit 64
fi

PR_NUMBER="$1"

OWNER="${GH_REPO%%/*}"
REPO="${GH_REPO##*/}"

# Unresolved review-thread comments (the in-line "code review" kind).
unresolved=$(gh api graphql \
  -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{isResolved isOutdated comments(first:50){nodes{author{login} body path line url}}}}}}}' \
  -F o="${OWNER}" -F r="${REPO}" -F n="${PR_NUMBER}" \
  --jq '.data.repository.pullRequest.reviewThreads.nodes
        | map(select(.isResolved == false and .isOutdated == false))
        | map(.comments.nodes)
        | flatten
        | map(select(.author.login != "ralph-bot" and .author.login != "github-actions[bot]"))')

# Issue-level conversation comments on the PR (exclude bot comments and the
# triggering @ralph comment so we don't echo it back).
discussion=$(gh api "repos/${OWNER}/${REPO}/issues/${PR_NUMBER}/comments" --paginate \
  --jq 'map(select(.user.login != "ralph-bot" and .user.login != "github-actions[bot]"))
        | map(select(.body | startswith("@ralph") | not))
        | map({author: .user.login, body: .body, url: .html_url})')

if [[ "$(jq -n --argjson u "${unresolved}" --argjson d "${discussion}" '($u|length) + ($d|length)')" == "0" ]]; then
  echo "No unresolved review comments or discussion to address." >&2
  exit 0
fi

{
  echo "## Open feedback to address"
  echo

  if [[ "$(jq -n --argjson u "${unresolved}" '$u | length')" != "0" ]]; then
    echo "### Inline review comments"
    echo "${unresolved}" | jq -r '
      .[] |
      "- **\(.author.login)** on `\(.path):\(.line // "?")`:\n  > \(.body | gsub("\n"; "\n  > "))\n  \(.url)\n"
    '
    echo
  fi

  if [[ "$(jq -n --argjson d "${discussion}" '$d | length')" != "0" ]]; then
    echo "### PR discussion"
    echo "${discussion}" | jq -r '
      .[] |
      "- **\(.author)**:\n  > \(.body | gsub("\n"; "\n  > "))\n  \(.url)\n"
    '
  fi
}
