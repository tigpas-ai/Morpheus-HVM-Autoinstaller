#!/usr/bin/env bash
# gen-netcfg.sh - generate the netcfg files (one per node) from a CSV file and a template.
#
# Usage:
#   gen-netcfg.sh -t TEMPLATE -o OUTPUT_DIR [-f] CSV_FILE
#
#   CSV_FILE       one header line, then one line per node; separator ","; no quoting
#   -t TEMPLATE    netplan YAML with placeholders @COLUMN@ (column name in upper case)
#   -o OUTPUT_DIR  directory for the <key>.yaml files (created if missing)
#   -f             overwrite existing files in OUTPUT_DIR
#
# Columns:
#   key        required. MAC address of any NIC of the node (":" or "-", any case) or its
#              DMI serial number. Becomes the file name, normalized to lower case with "-".
#   hostname   required. Host name (short or FQDN); written as "# HOSTNAME=<value>".
#   ntp        optional. NTP servers separated by ";"; written as "# NTP=<a>,<b>".
#   any other  free columns for the template, e.g. address -> @ADDRESS@. Inside a value, ";"
#              separates list items and is written as ", " (for YAML flow lists like [@DNS@]).
# Empty lines and lines starting with "#" are ignored. Every placeholder used in the template
# must be filled; the result is checked with check.sh.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-2}"; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

template="" outdir="" force=0
while getopts "t:o:fh" opt; do
  case "$opt" in
    t) template=$OPTARG ;;
    o) outdir=$OPTARG ;;
    f) force=1 ;;
    h) usage 0 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
if [ $# -ne 1 ] || [ -z "$template" ] || [ -z "$outdir" ]; then usage; fi
csv=$1
[ -f "$csv" ] || { echo "error: $csv not found" >&2; exit 1; }
[ -f "$template" ] || { echo "error: $template not found" >&2; exit 1; }

tpl=$(tr -d '\r' < "$template")
# Comment lines of a template copied from a node file are not taken over.
tpl=$(grep -Ev '^# (HOSTNAME|NTP)=' <<<"$tpl" || true)

trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

header=() lineno=0 count=0
declare -A seen=()
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line=${line%$'\r'}
  [ -n "$(trim "$line")" ] || continue
  [[ "$(trim "$line")" == \#* ]] && continue
  IFS=, read -r -a fields <<<"$line"
  if [ ${#header[@]} -eq 0 ]; then
    for f in "${fields[@]}"; do
      f=$(trim "$f")
      [[ "$f" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || { echo "error: $csv:$lineno: invalid column name '$f'" >&2; exit 1; }
      [[ " ${header[*]} " != *" ${f,,} "* ]] || { echo "error: $csv:$lineno: column '$f' twice" >&2; exit 1; }
      header+=("${f,,}")
    done
    if [[ " ${header[*]} " != *" key "* ]] || [[ " ${header[*]} " != *" hostname "* ]]; then
      echo "error: $csv: columns 'key' and 'hostname' are required" >&2
      exit 1
    fi
    continue
  fi
  [ ${#fields[@]} -le ${#header[@]} ] ||
    { echo "error: $csv:$lineno: ${#fields[@]} fields, header has ${#header[@]}" >&2; exit 1; }

  declare -A row=()
  for i in "${!header[@]}"; do row[${header[$i]}]=$(trim "${fields[$i]:-}"); done

  key=${row[key]}
  key=${key,,}
  key=${key//:/-}
  hn=${row[hostname]}
  [[ "$key" =~ ^[0-9a-z][0-9a-z._-]*$ ]] ||
    { echo "error: $csv:$lineno: invalid key '$key' (MAC address or serial number)" >&2; exit 1; }
  [ -n "$hn" ] || { echo "error: $csv:$lineno: empty hostname" >&2; exit 1; }
  [ -z "${seen[$key]:-}" ] || { echo "error: $csv:$lineno: key $key already in line ${seen[$key]}" >&2; exit 1; }
  seen[$key]=$lineno

  body=$tpl
  for col in "${header[@]}"; do
    val=${row[$col]}
    val=${val//;/, }
    body=${body//@${col^^}@/"$val"}
  done
  if left=$(grep -o '@[A-Z][A-Z0-9_]*@' <<<"$body" | sort -u | tr '\n' ' ') && [ -n "$left" ]; then
    echo "error: $csv:$lineno: placeholders without column: $left" >&2
    exit 1
  fi

  head="# HOSTNAME=$hn"
  ntp=${row[ntp]:-}
  if [ -n "$ntp" ]; then ntp=${ntp//;/,}; head+=$'\n'"# NTP=${ntp// /}"; fi

  mkdir -p "$outdir"
  file=$outdir/$key.yaml
  if [ -e "$file" ] && [ $force -eq 0 ]; then
    echo "error: $file exists (use -f to overwrite)" >&2
    exit 1
  fi
  printf '%s\n%s\n' "$head" "$body" > "$file"
  chmod 600 "$file"
  echo "wrote $file ($hn)"
  count=$((count + 1))
  unset row
done < "$csv"

[ $count -gt 0 ] || { echo "error: no node lines in $csv" >&2; exit 1; }
"$HERE/check.sh" "$outdir"
