#!/usr/bin/env bash
# update-stick.sh - turn a writable USB stick made from the original ISO into an autoinstaller.
#
# Usage:
#   update-stick.sh -u USERNAME [-p HASH_FILE] -n NETCFG_DIR STICK_MOUNTPOINT
#
#   STICK_MOUNTPOINT  mounted file system of a stick written from the original ISO with a tool
#                     that produces a writable file system (e.g. Rufus, FAT32 / ISO mode)
#   -u USERNAME       local admin user created by the installer
#   -p HASH_FILE      file holding the crypted password ("-" = stdin);
#                     default: environment variable PASSWORD_HASH
#   -n NETCFG_DIR     directory with one <mac|serial>.yaml per node (see docs/netcfg.md)
#
# On the stick: server/user-data is moved to server/user-data-original (only the first time;
# afterwards that file is the source), the new server/user-data is written and server/netcfg/
# is replaced by the contents of NETCFG_DIR. A stick written with dd from an ISO is read-only
# (ISO 9660) - use build-iso.sh for that case.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-2}"; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

user="" hash_file="" netcfg=""
while getopts "u:p:n:h" opt; do
  case "$opt" in
    u) user=$OPTARG ;;
    p) hash_file=$OPTARG ;;
    n) netcfg=$OPTARG ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
if [ $# -ne 1 ] || [ -z "$user" ] || [ -z "$netcfg" ]; then usage; fi
stick=$1
srv=$stick/server

if [ ! -f "$srv/user-data" ] || [ ! -f "$stick/casper/vmlinuz" ]; then
  echo "error: $stick does not look like a stick made from the HPE HVM ISO" >&2
  exit 1
fi
[ -w "$srv" ] || { echo "error: $srv is not writable" >&2; exit 1; }

echo "== checking $netcfg"
"$HERE/check.sh" "$netcfg"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

orig=$srv/user-data-original
[ -f "$orig" ] || orig=$srv/user-data
cp "$orig" "$work/user-data-original"

echo "== building user-data"
args=(-o "$work/user-data" -u "$user")
[ -z "$hash_file" ] || args+=(-p "$hash_file")
"$HERE/make-user-data.sh" "${args[@]}" "$work/user-data-original"
"$HERE/check.sh" -u "$work/user-data"

echo "== writing to $stick"
[ -f "$srv/user-data-original" ] || mv "$srv/user-data" "$srv/user-data-original"
cp "$work/user-data" "$srv/user-data"
rm -rf "$srv/netcfg"
mkdir "$srv/netcfg"
cp "$netcfg"/*.yaml "$srv/netcfg/"
sync
echo "== done: $(find "$srv/netcfg" -name '*.yaml' | wc -l) netcfg file(s) on $stick"
