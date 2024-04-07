#!/bin/bash
#
# if the branch is 'dependabot/*' but the author is not dependabot[bot] then skip the rest of the steps
author=$(git log -1 --pretty=format:'%an')
if [ "$author" != "dependabot[bot]" ]; then
  echo "PR is not from dependabot! Skipping..."
  # ending job without failure
  circleci step halt
fi

max_retries=3
retry_delay=3
retry_count=0

check_mergeable() {
    gh pr view --json mergeable | jq -r .mergeable
}

mergeable=$(check_mergeable)
echo "Mergeable status is: $mergeable"

while [ "$mergeable" != "MERGEABLE" ]; do
    if [ "$retry_count" -eq "$max_retries" ]; then
        echo "Maximum retries exceeded. PR status is: $mergeable instead of MERGEABLE! Aborting..."
        exit 1
    fi

    # Sometimes mergeable status is UNKNOWN, if something has just been merged into the base branch
    if [ "$mergeable" == "UNKNOWN" ]; then
        echo "Retrying..."
        sleep "$retry_delay"
        mergeable=$(check_mergeable)
        ((retry_count++))
        retry_delay=$((retry_delay * 2))  # Exponential backoff
    else
        echo "PR status is: $mergeable instead of MERGEABLE! Aborting..."
        exit 1
    fi
done

merge_state_status=$(gh pr view --json mergeStateStatus | jq -r .mergeStateStatus)
echo "Merge state status is: $merge_state_status"


# if the PR merge state status is 'BLOCKED', then it's waiting for reviews
# or some of the non-required status checks are (approve jobs) are waiting
if [ "$merge_state_status" != "BLOCKED" ]; then
  echo "PR can't be merged at the moment! Merge state status is: $merge_state_status. Aborting..."
  exit 1
fi

patch=$1
minor=$2
pr_title=$(gh pr view --json title | jq -r .title)

# echo the parameters and current PR title (useful for debugging)
echo "patch: $patch"
echo "minor: $minor"
echo "pr_title: $pr_title"

# Function to check if PR title contains specified keywords
contains_keywords() {
  local title="$1"
  shift
  local keywords=("$@")

  for keyword in "${keywords[@]}"; do
    if [[ "$title" == *"$keyword"* ]]; then
      return 0
    fi
  done

  return 1
}

# these keywords are from the grouping in the dependabot.yml config file
patch_keywords=("production-patch" "development-patch")
minor_keywords=("production-minor" "development-minor")

# if patch is true and PR title contains patch keywords, then proceed with the job (auto merge)
if ( [ "$patch" == "true" ] && contains_keywords "$pr_title" "${patch_keywords[@]}" ); then
    echo "Patch update detected. Proceeding with the job."
    exit 0
fi

# if minor is true and PR title contains minor keywords, then proceed with the job (auto merge)
if ( [ "$minor" == "true" ] && contains_keywords "$pr_title" "${minor_keywords[@]}" ); then
    echo "Minor update detected. Proceeding with the job."
    exit 0
fi

echo "Skipping job. None of the conditions have been met."
circleci-agent step halt
