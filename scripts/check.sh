#!/usr/bin/env bash
# check.sh - validate netcfg files and a generated user-data before building media.
#
# Usage:
#   check.sh [-u USER_DATA] [-a ADDON_DIR]... [NETCFG_DIR]
#
#   -u USER_DATA  generated server/user-data: YAML syntax, no placeholders left,
#                 shell syntax of early-commands, late-commands and runcmd
#   -a ADDON_DIR  add-on folder (repeatable): a directory with install.sh, usable folder name,
#                 names unique (the folder is stored as server/addons/<name>/)
#   NETCFG_DIR    directory with <mac|serial>.yaml files: file names, "# HOSTNAME=" line,
#                 optional "# NTP=" line, YAML syntax and a top-level "network" key
#
# YAML syntax is checked with python3 and PyYAML when available (otherwise skipped with a
# warning). Exit code 0 = all checks passed, 1 = at least one error.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-2}"; }

user_data="" addons=()
while getopts "u:a:h" opt; do
  case "$opt" in
    u) user_data=$OPTARG ;;
    a) addons+=("$OPTARG") ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[ $# -le 1 ] || usage
netcfg=${1:-}
[ -n "$user_data" ] || [ -n "$netcfg" ] || [ ${#addons[@]} -gt 0 ] || usage

errors=0
err() { echo "ERROR: $*" >&2; errors=$((errors + 1)); }
ok() { echo "ok:    $*"; }

have_yaml=0
if command -v python3 >/dev/null && python3 -c 'import yaml' 2>/dev/null; then
  have_yaml=1
else
  echo "WARN:  python3 with PyYAML not found - YAML syntax is not checked" >&2
fi

# Prints a short error and returns 1 if the file is no valid YAML mapping with KEY.
yaml_has_key() {
  python3 - "$1" "$2" <<'PY'
import sys, yaml
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        doc = yaml.safe_load(f)
except yaml.YAMLError as e:
    print(str(e).splitlines()[0]); sys.exit(1)
if not isinstance(doc, dict) or key not in doc:
    print(f"no top-level '{key}' key"); sys.exit(1)
PY
}

if [ -n "$netcfg" ]; then
  [ -d "$netcfg" ] || { echo "error: $netcfg is no directory" >&2; exit 1; }
  shopt -s nullglob
  files=("$netcfg"/*)
  [ ${#files[@]} -gt 0 ] || err "$netcfg is empty"
  declare -A hosts=()
  for f in "${files[@]}"; do
    name=$(basename "$f")
    key=${name%.yaml}
    if [ "$key" = "$name" ]; then err "$name: not a .yaml file"; continue; fi
    if [[ ! "$key" =~ ^[0-9a-z][0-9a-z._-]*$ ]]; then
      err "$name: name must be a MAC address (lower case, '-' instead of ':') or a lower-case serial number"
      continue
    fi
    # Looks like a MAC address (hex pairs with "-") but is not a complete one: probably a typo.
    if [[ "$key" =~ ^[0-9a-f]{2}(-[0-9a-f]{2})+$ ]] && [[ ! "$key" =~ ^([0-9a-f]{2}-){5}[0-9a-f]{2}$ ]]; then
      err "$name: incomplete MAC address"; continue
    fi
    hn=$(sed -n 's/^# HOSTNAME=//p' "$f" | head -n 1 | tr -d ' \r')
    if [ -z "$hn" ]; then err "$name: no '# HOSTNAME=' line"; continue; fi
    if [[ ! "$hn" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]]; then
      err "$name: invalid host name '$hn'"; continue
    fi
    short=${hn%%.*}
    short=${short,,}
    if [ -n "${hosts[$short]:-}" ]; then err "$name: host name $short also used in ${hosts[$short]}"; fi
    hosts[$short]=$name
    ntp=$(sed -n 's/^# NTP=//p' "$f" | head -n 1 | tr -d ' \r')
    if [ -n "$ntp" ] && [[ ! "$ntp" =~ ^[A-Za-z0-9.:-]+(,[A-Za-z0-9.:-]+)*$ ]]; then
      err "$name: '# NTP=' must be a comma-separated list of servers"; continue
    fi
    if grep -q $'\r' "$f"; then err "$name: Windows line endings (CR LF)"; continue; fi
    if [ $have_yaml -eq 1 ] && ! msg=$(yaml_has_key "$f" network); then
      err "$name: $msg"; continue
    fi
    ok "$name -> $short${ntp:+ (NTP $ntp)}"
  done
fi

declare -A addon_names=()
for a in ${addons[@]+"${addons[@]}"}; do
  if [ ! -d "$a" ]; then err "add-on $a: not a directory"; continue; fi
  name=$(basename "$(realpath "$a")")
  if [[ ! "$name" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then err "add-on $a: unusable folder name '$name'"; continue; fi
  if [ ! -f "$a/install.sh" ]; then err "add-on $name: no install.sh"; continue; fi
  if [ -n "${addon_names[$name]:-}" ]; then err "add-on $name: folder name used twice"; continue; fi
  addon_names[$name]=1
  if ! out=$(bash -n "$a/install.sh" 2>&1); then err "add-on $name: install.sh: $out"; continue; fi
  ok "add-on $name"
done

if [ -n "$user_data" ]; then
  [ -f "$user_data" ] || { echo "error: $user_data not found" >&2; exit 1; }
  if grep -q '@[A-Z_]*@' "$user_data"; then err "$(basename "$user_data"): unfilled placeholder"; fi
  [ "$(head -n 1 "$user_data")" = "#cloud-config" ] || err "$(basename "$user_data"): first line must be #cloud-config"
  if [ $have_yaml -eq 1 ]; then
    if ! msg=$(yaml_has_key "$user_data" autoinstall); then
      err "$(basename "$user_data"): $msg"
    else
      # early-/late-commands run with sh, runcmd entries are bash -c '...' calls.
      tmpd=$(mktemp -d)
      trap 'rm -rf "$tmpd"' EXIT
      python3 - "$user_data" "$tmpd" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))["autoinstall"]
out = sys.argv[2]
parts = [("early", c) for c in doc.get("early-commands", [])]
parts += [("late", c) for c in doc.get("late-commands", [])]
parts += [("runcmd", c) for c in doc.get("user-data", {}).get("runcmd", [])]
for i, (kind, cmd) in enumerate(parts):
    if isinstance(cmd, list):
        cmd = " ".join(cmd)
    with open(f"{out}/{i:02d}-{kind}.sh", "w") as f:
        f.write(cmd + "\n")
PY
      before=$errors blocks=0
      for s in "$tmpd"/*.sh; do
        blocks=$((blocks + 1))
        case "$s" in *-runcmd.sh) shell="bash" ;; *) shell="sh" ;; esac
        if ! out=$($shell -n "$s" 2>&1); then err "$(basename "$user_data") $(basename "$s" .sh): $out"; fi
      done
      if [ $errors -eq "$before" ]; then
        ok "$(basename "$user_data"): YAML and shell syntax ($blocks command blocks)"
      fi
    fi
  fi
fi

if [ $errors -gt 0 ]; then echo "$errors error(s)" >&2; exit 1; fi
echo "all checks passed"
