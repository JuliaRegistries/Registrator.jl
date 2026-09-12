#!/usr/bin/env bash
#
# Look up a user or organization's immutable platform ID for use in the
# Registrator blocklist. Works for both users and organizations.
#
# Usage:
#   ./lookup_user_id.sh <name>                  # defaults to github
#   ./lookup_user_id.sh <name> github
#   ./lookup_user_id.sh <name> gitlab
#   ./lookup_user_id.sh <name> bitbucket
#
# Requires: curl, grep, sed
#
# For private GitHub repos or to avoid rate limits, set GITHUB_TOKEN:
#   GITHUB_TOKEN=ghp_... ./lookup_user_id.sh <name>
#
# Note: On GitHub, the same endpoint works for both users and organizations,
# since they share the same ID namespace.

set -euo pipefail

usage() {
    echo "Usage: $0 <username> [github|gitlab|bitbucket]"
    exit 1
}

[ $# -lt 1 ] && usage

USERNAME="$1"
PROVIDER="${2:-github}"

case "$PROVIDER" in
    github)
        AUTH_HEADER=""
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
        fi

        RESPONSE=$(curl -s ${AUTH_HEADER:+-H "$AUTH_HEADER"} \
            "https://api.github.com/users/${USERNAME}")

        ID=$(echo "$RESPONSE" | grep '"id":' | head -1 | sed 's/[^0-9]//g')

        if [ -z "$ID" ]; then
            echo "Error: Could not find GitHub user '$USERNAME'" >&2
            echo "$RESPONSE" >&2
            exit 1
        fi

        echo "Provider: GitHub"
        echo "Username: $USERNAME"
        echo "ID:       $ID"
        echo ""
        echo "Blocklist entry:"
        echo ""
        echo "[[blocked]]"
        echo "provider = \"github\""
        echo "id = $ID"
        echo "username = \"$USERNAME\""
        echo "reason = \"\""
        ;;

    gitlab)
        RESPONSE=$(curl -s "https://gitlab.com/api/v4/users?username=${USERNAME}")

        ID=$(echo "$RESPONSE" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://')

        if [ -z "$ID" ]; then
            echo "Error: Could not find GitLab user '$USERNAME'" >&2
            echo "$RESPONSE" >&2
            exit 1
        fi

        echo "Provider: GitLab"
        echo "Username: $USERNAME"
        echo "ID:       $ID"
        echo ""
        echo "Blocklist entry:"
        echo ""
        echo "[[blocked]]"
        echo "provider = \"gitlab\""
        echo "id = $ID"
        echo "username = \"$USERNAME\""
        echo "reason = \"\""
        ;;

    bitbucket)
        RESPONSE=$(curl -s "https://api.bitbucket.org/2.0/users/${USERNAME}")

        UUID=$(echo "$RESPONSE" | grep -o '"uuid": *"[^"]*"' | head -1 | sed 's/"uuid": *"//;s/"//')

        if [ -z "$UUID" ]; then
            echo "Error: Could not find Bitbucket user '$USERNAME'" >&2
            echo "$RESPONSE" >&2
            exit 1
        fi

        echo "Provider: Bitbucket"
        echo "Username: $USERNAME"
        echo "UUID:     $UUID"
        echo ""
        echo "Blocklist entry:"
        echo ""
        echo "[[blocked]]"
        echo "provider = \"bitbucket\""
        echo "id = \"$UUID\""
        echo "username = \"$USERNAME\""
        echo "reason = \"\""
        ;;

    *)
        echo "Error: Unknown provider '$PROVIDER'. Use github, gitlab, or bitbucket." >&2
        exit 1
        ;;
esac
