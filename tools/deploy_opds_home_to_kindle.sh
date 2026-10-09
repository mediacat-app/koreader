#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

kindle_host="${KINDLE_HOST:-192.168.0.58}"
kindle_port="${KINDLE_PORT:-2222}"
kindle_user="${KINDLE_USER:-root}"
koreader_dir="${KINDLE_KOREADER_DIR:-/mnt/us/koreader}"
kindle_key="${KINDLE_SSH_KEY:-$HOME/.ssh/id_ed25519_koreader_kindle}"

if ! command -v sftp >/dev/null 2>&1; then
    echo "sftp is required (install OpenSSH client tools)." >&2
    exit 1
fi

case "$koreader_dir" in
    ""|*[!A-Za-z0-9_./-]*)
        echo "KINDLE_KOREADER_DIR may contain only letters, numbers, '_', '.', '/', and '-'." >&2
        exit 1
        ;;
esac

remote_plugins="$koreader_dir/plugins"
remote_mediacat="$remote_plugins/mediacat.koplugin"
remote_legacy="$remote_plugins/opds_home.koplugin"

# Quote paths for the SFTP batch command language.
sftp_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

batch_file="$(mktemp)"
trap 'rm -f "$batch_file"' EXIT
{
    # Remove the previous plugin directory name to avoid loading both copies.
    for file in _meta.lua main.lua README.md; do
        printf '%s\n' "-rm $(sftp_quote "$remote_legacy/$file")"
    done
    printf '%s\n' "-rmdir $(sftp_quote "$remote_legacy")"
    # The plugins directory should exist in a KOReader install. Ignore the
    # expected "already exists" result for the MediaCat directory.
    printf '%s\n' "-mkdir $(sftp_quote "$remote_mediacat")"
    printf 'put %s %s\n' \
        "$(sftp_quote "$repo_root/plugins/mediacat.koplugin/_meta.lua")" \
        "$(sftp_quote "$remote_mediacat/_meta.lua")"
    printf 'put %s %s\n' \
        "$(sftp_quote "$repo_root/plugins/mediacat.koplugin/main.lua")" \
        "$(sftp_quote "$remote_mediacat/main.lua")"
    printf 'put %s %s\n' \
        "$(sftp_quote "$repo_root/plugins/mediacat.koplugin/README.md")" \
        "$(sftp_quote "$remote_mediacat/README.md")"
} > "$batch_file"

printf 'Syncing MediaCat to %s@%s:%s over SFTP port %s\n' \
    "$kindle_user" "$kindle_host" "$koreader_dir" "$kindle_port"
kindle_password="${KINDLE_PASSWORD:-}"
if [[ -z "$kindle_password" && ! -f "$kindle_key" && -r /dev/tty ]] && command -v sshpass >/dev/null 2>&1; then
    read -r -s -p "Kindle SSH password (press Enter for key/passwordless login): " \
        kindle_password </dev/tty
    printf '\n' >/dev/tty
fi

sftp_args=(-P "$kindle_port" -oConnectTimeout=8)
if [[ -f "$kindle_key" ]]; then
    sftp_args+=(-i "$kindle_key" -oIdentitiesOnly=yes)
fi
sftp_args+=(-b "$batch_file" "$kindle_user@$kindle_host")
if [[ -n "$kindle_password" ]]; then
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "sshpass is required for password authentication. Install it or use SSH key/passwordless login." >&2
        exit 1
    fi
    SSHPASS="$kindle_password" sshpass -e sftp "${sftp_args[@]}"
else
    sftp -oBatchMode=yes "${sftp_args[@]}"
fi
unset kindle_password
unset KINDLE_PASSWORD

echo "Deployment complete. Restart KOReader on the Kindle to load the updated plugin."
