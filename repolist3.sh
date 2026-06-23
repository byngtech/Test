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
OUTPUT_FILE="appid_results.csv"      # <-- output results file (CSV)
JENKINSFILE_PATH="Jenkinsfile"       # path of Jenkinsfile in repo root; change if nested
# Note: no branch is specified in the API call below, so GitHub automatically
# uses each repo's own default branch (matches plain `curl .../contents/Jenkinsfile`).

# Token: prefer environment variable GITHUB_TOKEN, fallback to hardcoded value below
TOKEN="${GITHUB_TOKEN:-PUT_YOUR_PAT_TOKEN_HERE}"

API_BASE="https://api.github.com"
DEBUG="${DEBUG:-false}"   # set DEBUG=true ./find_appid.sh to print each request/response to stderr

# WARNING: -k disables SSL certificate verification. This is insecure and
# should only be used if you've confirmed the failure is due to a local
# TLS/proxy/CA trust issue (e.g. corporate proxy doing TLS inspection) and
# you understand the risk. Prefer fixing your CA trust store instead.
CURL_INSECURE_FLAG="-k"
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

# Escapes a single field for safe CSV output (wraps in quotes, doubles any internal quotes)
csv_escape() {
    local field="$1"
    field="${field//\"/\"\"}"
    echo "\"${field}\""
}

# Clear/init output file with CSV header
echo "repo,status,appid" > "$OUTPUT_FILE"

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

    result=""
    access_denied_flag=false

    url="${API_BASE}/repos/${ORG}/${repo}/contents/${JENKINSFILE_PATH}"

    # Make the API call, capture HTTP status code and body separately
    response=$(curl -s ${CURL_INSECURE_FLAG} -w "\n%{http_code}" \
        -H "Authorization: token ${TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        "$url")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [[ "$DEBUG" == "true" ]]; then
        echo "DEBUG: repo='${repo}' url='${url}' http_code='${http_code}'" >&2
    fi

    if [[ "$http_code" == "200" ]]; then
        content_b64=$(echo "$body" | jq -r '.content // empty')
        if [[ -n "$content_b64" ]]; then
            decoded=$(echo "$content_b64" | base64 --decode 2>/dev/null)

            # Look for a line like: appid: 'something' / appId = "something" (case-insensitive,
            # tolerant of straight or curly quotes, trailing commas/semicolons, extra spaces)
            appid_line=$(echo "$decoded" | grep -i -m1 -E 'app[_]?id[[:space:]]*[:=]')
            if [[ -n "$appid_line" ]]; then
                appid_value=$(echo "$appid_line" \
                    | sed -E 's/.*[Aa][Pp][Pp][_]?[Ii][Dd][[:space:]]*[:=][[:space:]]*//' \
                    | sed -E 's/[,;][[:space:]]*$//' \
                    | sed "s/[\"'‘’“”]//g" \
                    | xargs)
                if [[ -n "$appid_value" ]]; then
                    result="$(csv_escape "$repo"),$(csv_escape "found"),$(csv_escape "$appid_value")"
                    found=$((found+1))
                else
                    result="$(csv_escape "$repo"),$(csv_escape "appid not found"),$(csv_escape "")"
                    no_appid=$((no_appid+1))
                fi
            else
                result="$(csv_escape "$repo"),$(csv_escape "appid not found"),$(csv_escape "")"
                no_appid=$((no_appid+1))
            fi
        else
            result="$(csv_escape "$repo"),$(csv_escape "Jenkinsfile not found"),$(csv_escape "")"
            no_jenkins=$((no_jenkins+1))
        fi
    elif [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
        result="$(csv_escape "$repo"),$(csv_escape "access denied to repo"),$(csv_escape "")"
        denied=$((denied+1))
    elif [[ "$http_code" == "404" ]]; then
        result="$(csv_escape "$repo"),$(csv_escape "Jenkinsfile not found"),$(csv_escape "")"
        no_jenkins=$((no_jenkins+1))
    else
        result="$(csv_escape "$repo"),$(csv_escape "access denied to repo (HTTP ${http_code})"),$(csv_escape "")"
        denied=$((denied+1))
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
}

echo "Done. Results written to $OUTPUT_FILE"
