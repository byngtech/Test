#!/usr/bin/env bash
#
# find_appid.sh
#
# Iterates through a list of GitHub repo names (same org), fetches each repo's
# Jenkinsfile via the GitHub API, and extracts the value of "appid:" if present.
#
# Usage:
#   ./find_appid.sh
#
# Requires:
#   - GITHUB_TOKEN env var (PAT) OR edit the TOKEN variable below
#   - curl, jq
#
# Config below: ORG name, input repo list file, output file, branch.

set -uo pipefail

# ---------------- CONFIG ----------------
ORG="your-org-name"                  # <-- set your GitHub org name
REPO_LIST="repos.txt"                # <-- file with one repo name per line
OUTPUT_FILE="appid_results.txt"      # <-- output results file
BRANCHES=("main" "master")           # <-- branches to try in order, first match wins
JENKINSFILE_PATH="Jenkinsfile"       # path of Jenkinsfile in repo root; change if nested

# Token: prefer environment variable GITHUB_TOKEN, fallback to hardcoded value below
TOKEN="${GITHUB_TOKEN:-PUT_YOUR_PAT_TOKEN_HERE}"

API_BASE="https://api.github.com"
DEBUG="${DEBUG:-false}"   # set DEBUG=true ./find_appid.sh to print each request/response to stderr
# -----------------------------------------

# Basic sanity checks
if [[ ! -f "$REPO_LIST" ]]; then
    echo "ERROR: Repo list file '$REPO_LIST' not found." >&2
    exit 1
fi

if [[ -z "$TOKEN" || "$TOKEN" == "PUT_YOUR_PAT_TOKEN_HERE" ]]; then
    echo "ERROR: No GitHub token set. Export GITHUB_TOKEN or edit the script." >&2
    exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required but not installed." >&2; exit 1; }

# Clear/init output file with a header
{
    echo "AppID extraction results"
    echo "Run date: $(date)"
    echo "Org: $ORG"
    echo "----------------------------------------"
} > "$OUTPUT_FILE"

total=0
found=0
no_appid=0
no_jenkins=0
denied=0

while IFS= read -r repo || [[ -n "$repo" ]]; do
    # skip blank lines / comments
    [[ -z "$repo" ]] && continue
    [[ "$repo" =~ ^# ]] && continue

    repo="$(echo "$repo" | tr -d '\r' | xargs)"  # strip CR (Windows line endings) and trim whitespace
    total=$((total+1))

    result=""        # final result line content for this repo (set inside loop below)
    matched_branch="" # which branch the Jenkinsfile was actually found on
    jenkins_missing_all=true
    access_denied_flag=false

    for branch in "${BRANCHES[@]}"; do
        url="${API_BASE}/repos/${ORG}/${repo}/contents/${JENKINSFILE_PATH}?ref=${branch}"

        # Make the API call, capture HTTP status code and body separately
        response=$(curl -s -w "\n%{http_code}" \
            -H "Authorization: token ${TOKEN}" \
            -H "Accept: application/vnd.github.v3+json" \
            "$url")

        http_code=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')

        if [[ "$DEBUG" == "true" ]]; then
            echo "DEBUG: repo='${repo}' branch='${branch}' url='${url}' http_code='${http_code}'" >&2
        fi

        if [[ "$http_code" == "200" ]]; then
            content_b64=$(echo "$body" | jq -r '.content // empty')
            if [[ -n "$content_b64" ]]; then
                jenkins_missing_all=false
                matched_branch="$branch"
                decoded=$(echo "$content_b64" | base64 --decode 2>/dev/null)

                # Look for a line like: appid: something  (case-insensitive, allow quotes)
                appid_line=$(echo "$decoded" | grep -i -m1 -E 'appid[[:space:]]*[:=]')
                if [[ -n "$appid_line" ]]; then
                    appid_value=$(echo "$appid_line" | sed -E 's/.*appid[[:space:]]*[:=][[:space:]]*//I' | tr -d "\"'" | xargs)
                    if [[ -n "$appid_value" ]]; then
                        result="${repo}: appid = ${appid_value} (branch: ${branch})"
                        found=$((found+1))
                    else
                        result="${repo}: appid not found (branch: ${branch})"
                        no_appid=$((no_appid+1))
                    fi
                else
                    result="${repo}: appid not found (branch: ${branch})"
                    no_appid=$((no_appid+1))
                fi
                break  # found the Jenkinsfile on this branch, stop trying other branches
            fi
        elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
            access_denied_flag=true
            break  # no point trying other branches if access is denied
        fi
        # 404 or anything else: fall through and try next branch

        sleep 0.3
    done

    if [[ "$access_denied_flag" == true ]]; then
        result="${repo}: access denied to repo"
        denied=$((denied+1))
    elif [[ "$jenkins_missing_all" == true ]]; then
        result="${repo}: Jenkinsfile not found"
        no_jenkins=$((no_jenkins+1))
    fi

    echo "$result" >> "$OUTPUT_FILE"

    # Be gentle with the GitHub API rate limit
    sleep 0.3

done < "$REPO_LIST"

{
    echo "----------------------------------------"
    echo "Summary:"
    echo "Total repos processed : $total"
    echo "AppID found           : $found"
    echo "AppID not found        : $no_appid"
    echo "Jenkinsfile not found  : $no_jenkins"
    echo "Access denied          : $denied"
} >> "$OUTPUT_FILE"

echo "Done. Results written to $OUTPUT_FILE"
