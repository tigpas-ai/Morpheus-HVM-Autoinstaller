#!/usr/bin/env bash
# build-iso.sh - create an autoinstall ISO from the original HPE HVM installation ISO.
#
# Usage:
#   build-iso.sh -u USERNAME [-p HASH_FILE] -n NETCFG_DIR [-f] ORIGINAL_ISO OUTPUT_ISO
#
#   ORIGINAL_ISO   original HPE HVM ISO (only read, never changed)
#   OUTPUT_ISO     new ISO to write (must not exist unless -f is given)
#   -u USERNAME    local admin user created by the installer
#   -p HASH_FILE   file holding the crypted password ("-" = stdin);
#                  default: environment variable PASSWORD_HASH
#   -n NETCFG_DIR  directory with one <mac|serial>.yaml per node (see docs/netcfg.md)
#   -f             overwrite OUTPUT_ISO
#
# The new ISO is the original plus:
#   /server/user-data           original + server/user-data.patch (placeholders filled in)
#   /server/user-data-original  the unchanged original, for reference
#   /server/netcfg/             the node files from NETCFG_DIR
# Boot records (BIOS and UEFI El Torito, hybrid MBR/GPT) are replayed from the original.
# Requires: xorriso, patch; python3 with PyYAML for the full syntax check (optional).
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-2}"; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

user="" hash_file="" netcfg="" force=0
while getopts "u:p:n:fh" opt; do
  case "$opt" in
    u) user=$OPTARG ;;
    p) hash_file=$OPTARG ;;
    n) netcfg=$OPTARG ;;
    f) force=1 ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
if [ $# -ne 2 ] || [ -z "$user" ] || [ -z "$netcfg" ]; then usage; fi
iso=$1 out=$2

command -v xorriso >/dev/null || { echo "error: xorriso not found (package xorriso)" >&2; exit 1; }
[ -f "$iso" ] || { echo "error: $iso not found" >&2; exit 1; }
if [ -e "$out" ]; then
  [ "$(realpath "$out")" != "$(realpath "$iso")" ] || { echo "error: OUTPUT_ISO is the original" >&2; exit 1; }
  [ $force -eq 1 ] || { echo "error: $out exists (use -f to overwrite)" >&2; exit 1; }
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "== checking $netcfg"
"$HERE/check.sh" "$netcfg"

echo "== extracting /server/user-data from $iso"
if ! xorriso -osirrox on -indev "$iso" -extract /server/user-data "$work/user-data-original" \
    >"$work/xorriso.log" 2>&1 || [ ! -f "$work/user-data-original" ]; then
  tail -n 5 "$work/xorriso.log" >&2
  echo "error: no /server/user-data in $iso (not an HPE HVM ISO?)" >&2
  exit 1
fi
chmod u+w "$work/user-data-original"
mkdir "$work/netcfg"
cp "$netcfg"/*.yaml "$work/netcfg/"

echo "== building user-data"
args=(-o "$work/user-data" -u "$user")
[ -z "$hash_file" ] || args+=(-p "$hash_file")
"$HERE/make-user-data.sh" "${args[@]}" "$work/user-data-original"
"$HERE/check.sh" -u "$work/user-data"

echo "== writing $out"
rm -f "$out"
if ! xorriso -indev "$iso" -outdev "$out" \
    -map "$work/user-data" /server/user-data \
    -map "$work/user-data-original" /server/user-data-original \
    -map "$work/netcfg" /server/netcfg \
    -boot_image any replay >"$work/xorriso.log" 2>&1; then
  tail -n 20 "$work/xorriso.log" >&2
  rm -f "$out"
  echo "error: xorriso failed" >&2
  exit 1
fi
grep -E '^xorriso : (SORRY|WARNING)' "$work/xorriso.log" >&2 || true

echo "== done: $out"
xorriso -indev "$out" -report_el_torito plain 2>/dev/null | grep -E '^El Torito boot img' || true
echo "netcfg files: $(find "$work/netcfg" -name '*.yaml' | wc -l)"
