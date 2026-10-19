#!/usr/bin/env bash
# make-user-data.sh - build the autoinstall user-data from the original HPE file.
#
# Usage:
#   make-user-data.sh -o OUTPUT -u USERNAME [-p HASH_FILE] ORIGINAL_USER_DATA
#
#   ORIGINAL_USER_DATA  server/user-data from the original HPE HVM ISO (unchanged)
#   -o OUTPUT           file to write (the new server/user-data)
#   -u USERNAME         local admin user created by the installer
#   -p HASH_FILE        file holding the crypted password (e.g. from "mkpasswd -m sha-512"),
#                       "-" for stdin; default: environment variable PASSWORD_HASH
#
# Applies server/user-data.patch of this repository (no fuzz) and fills in the placeholders
# @USERNAME@ and @PASSWORD_HASH@. Warns if the original is not the 9.1.0-1 file and fails
# if the patch does not apply exactly (usually: different ISO version).
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-2}"; }

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PATCH_FILE="$REPO/server/user-data.patch"
# server/user-data of HPE_HVM_Install_26.04_S6E64-11270.iso (9.1.0-1)
KNOWN_SHA256=d4a488afa355759b0b4cd5af30597ccabf089c2c7ec46b692f65626aed12d1cc

out="" user="" hash_file=""
while getopts "o:u:p:h" opt; do
  case "$opt" in
    o) out=$OPTARG ;;
    u) user=$OPTARG ;;
    p) hash_file=$OPTARG ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] && [ -n "$out" ] && [ -n "$user" ] || usage
orig=$1

[ -f "$orig" ] || { echo "error: $orig not found" >&2; exit 1; }
[[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "error: invalid user name '$user'" >&2; exit 1; }

if [ -n "$hash_file" ]; then
  if [ "$hash_file" = "-" ]; then hash=$(cat); else hash=$(cat "$hash_file"); fi
else
  hash=${PASSWORD_HASH:-}
fi
hash=$(printf '%s' "$hash" | tr -d '\r\n')
[[ "$hash" =~ ^\$[0-9a-z]+\$[./0-9A-Za-z$=,-]+$ ]] || {
  echo "error: no valid crypted password (expected e.g. \$6\$... from 'mkpasswd -m sha-512')" >&2
  exit 1
}

command -v patch >/dev/null || { echo "error: patch not found (package patch)" >&2; exit 1; }
sum=$(sha256sum "$orig" | cut -d' ' -f1)
if [ "$sum" != "$KNOWN_SHA256" ]; then
  echo "WARNING: $orig is not the server/user-data of HPE HVM 9.1.0-1 (SHA-256 $sum)." >&2
  echo "         Review the result, especially the 9.1.0-1 fixes." >&2
fi

tmp=$(mktemp)
trap 'rm -f "$tmp" "$tmp.orig" "$tmp.rej"' EXIT
if ! patch --quiet --forward --fuzz=0 --no-backup-if-mismatch -o "$tmp" "$orig" "$PATCH_FILE" >/dev/null; then
  echo "error: $PATCH_FILE does not apply to $orig (different ISO version?)" >&2
  exit 1
fi

content=$(cat "$tmp")
content=${content//@USERNAME@/"$user"}
content=${content//@PASSWORD_HASH@/"$hash"}
if grep -q '@[A-Z_]*@' <<<"$content"; then
  echo "error: unfilled placeholder left in output" >&2
  exit 1
fi
printf '%s\n' "$content" > "$out"
echo "wrote $out"
