#!/usr/bin/env bash
# run.sh - tests for the scripts of this repository.
#
# Usage:
#   tests/run.sh
#
# Environment (optional):
#   ORIGINAL_ISO   original HPE HVM ISO: also test the patch against its server/user-data
#                  and update-stick.sh (needs xorriso)
#   BUILD_ISO_DIR  directory with about 4 GB free space: also build an ISO with build-iso.sh
#                  into a temporary subdirectory and inspect it (needs ORIGINAL_ISO)
#
# Writes only to temporary directories, which are removed at the end.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-2}"; }
case "${1:-}" in -h) usage 0 ;; "") ;; *) usage ;; esac

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS=$REPO/scripts
T=$(mktemp -d)
cleanup() { rm -rf "$T" "${ISO_TMP:-}"; }
trap cleanup EXIT

pass=0 fail=0 skip=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ko() { echo "FAIL  $1"; fail=$((fail + 1)); }
sk() { echo "SKIP  $1"; skip=$((skip + 1)); }
# expect_ok NAME CMD... / expect_fail NAME CMD... - run quietly, compare the exit code.
expect_ok() { local n=$1; shift; if "$@" >"$T/out" 2>&1; then ok "$n"; else ko "$n"; sed 's/^/      /' "$T/out"; fi; }
expect_fail() { local n=$1; shift; if "$@" >"$T/out" 2>&1; then ko "$n (succeeded)"; else ok "$n"; fi; cp "$T/out" "$T/last"; }

have_yaml=0
python3 -c 'import yaml' 2>/dev/null && have_yaml=1

# --- shellcheck -------------------------------------------------------------------------
if command -v shellcheck >/dev/null; then
  expect_ok "shellcheck" shellcheck "$SCRIPTS"/*.sh "$REPO"/tests/*.sh
else
  sk "shellcheck (not installed)"
fi

# --- gen-netcfg.sh ----------------------------------------------------------------------
G=$T/gen
expect_ok "gen-netcfg: example CSV" "$SCRIPTS/gen-netcfg.sh" -t "$REPO/examples/netcfg-template.yaml" -o "$G" "$REPO/examples/nodes.csv"
expect_ok "gen-netcfg: output equals examples/netcfg" diff -r "$REPO/examples/netcfg" "$G"
expect_fail "gen-netcfg: refuses to overwrite" "$SCRIPTS/gen-netcfg.sh" -t "$REPO/examples/netcfg-template.yaml" -o "$G" "$REPO/examples/nodes.csv"
expect_ok "gen-netcfg: -f overwrites" "$SCRIPTS/gen-netcfg.sh" -f -t "$REPO/examples/netcfg-template.yaml" -o "$G" "$REPO/examples/nodes.csv"

f=$G/00-00-5e-00-53-01.yaml
expect_ok "gen-netcfg: key normalized, HOSTNAME line" grep -qx '# HOSTNAME=hvm-01.example.com' "$f"
expect_ok "gen-netcfg: NTP list" grep -qx '# NTP=192.0.2.1,192.0.2.2' "$f"
expect_ok "gen-netcfg: list value" grep -q 'addresses: \[192.0.2.53, 192.0.2.54\]' "$f"
expect_fail "gen-netcfg: no NTP line without ntp" grep -q '^# NTP=' "$G/00-00-5e-00-53-03.yaml"

printf 'key,hostname,address\n00:00:5e:00:53:10,a,192.0.2.10/24\n' > "$T/miss.csv"
expect_fail "gen-netcfg: placeholder without column" "$SCRIPTS/gen-netcfg.sh" -t "$REPO/examples/netcfg-template.yaml" -o "$T/g2" "$T/miss.csv"
printf 'key,hostname,address,gateway,dns,search\n00-00-5e-00-53-10,a,192.0.2.10/24,192.0.2.1,192.0.2.53,example.com\n00:00:5E:00:53:10,b,192.0.2.11/24,192.0.2.1,192.0.2.53,example.com\n' > "$T/dup.csv"
expect_fail "gen-netcfg: duplicate key" "$SCRIPTS/gen-netcfg.sh" -t "$REPO/examples/netcfg-template-single.yaml" -o "$T/g3" "$T/dup.csv"
printf 'hostname,address\na,192.0.2.10/24\n' > "$T/nokey.csv"
expect_fail "gen-netcfg: key column required" "$SCRIPTS/gen-netcfg.sh" -t "$REPO/examples/netcfg-template-single.yaml" -o "$T/g4" "$T/nokey.csv"
printf 'key,hostname,address,gateway,dns,search\r\nserial123,node-a,192.0.2.10/24,192.0.2.1,192.0.2.53,example.com\r\n' > "$T/crlf.csv"
expect_ok "gen-netcfg: CRLF CSV, serial key" "$SCRIPTS/gen-netcfg.sh" -t "$REPO/examples/netcfg-template-single.yaml" -o "$T/g5" "$T/crlf.csv"

# --- check.sh ---------------------------------------------------------------------------
expect_ok "check: examples/netcfg" "$SCRIPTS/check.sh" "$REPO/examples/netcfg"
mkdir -p "$T/bad1" "$T/bad2" "$T/bad3"
sed '/^# HOSTNAME=/d' "$f" > "$T/bad1/00-00-5e-00-53-01.yaml"
expect_fail "check: missing HOSTNAME" "$SCRIPTS/check.sh" "$T/bad1"
cp "$f" "$T/bad2/00:00:5E:00:53:01.yaml"
expect_fail "check: bad file name" "$SCRIPTS/check.sh" "$T/bad2"
cp "$f" "$T/bad3/00-00-5e-00-53-01.yaml"
cp "$f" "$T/bad3/00-00-5e-00-53-09.yaml"
expect_fail "check: duplicate host name" "$SCRIPTS/check.sh" "$T/bad3"
if [ $have_yaml -eq 1 ]; then
  mkdir -p "$T/bad4"
  printf '# HOSTNAME=x\nnetwork:\n  version: 2\n   bad: [\n' > "$T/bad4/00-00-5e-00-53-01.yaml"
  expect_fail "check: YAML syntax" "$SCRIPTS/check.sh" "$T/bad4"
else
  sk "check: YAML syntax (python3 PyYAML not installed)"
fi

# --- make-user-data.sh / update-stick.sh with the original file ---------------------------
HASH=$(openssl passwd -6 "test-$RANDOM" 2>/dev/null || true)
: > "$T/empty"
expect_fail "make-user-data: invalid hash" env PASSWORD_HASH=nohash "$SCRIPTS/make-user-data.sh" -o "$T/ud" -u admin "$T/empty"
expect_ok "make-user-data: invalid hash message" grep -q 'no valid crypted password' "$T/last"
printf 'key,hostname\n../x,a\n' > "$T/trav.csv"
expect_fail "gen-netcfg: rejects path in key" "$SCRIPTS/gen-netcfg.sh" -t "$REPO/examples/netcfg-template-single.yaml" -o "$T/g6" "$T/trav.csv"
expect_fail "gen-netcfg: nothing written outside" test -e "$T/x.yaml"
printf 'key,hostname,Key\n00-00-5e-00-53-10,a,b\n' > "$T/dupcol.csv"
expect_fail "gen-netcfg: duplicate column" "$SCRIPTS/gen-netcfg.sh" -t "$REPO/examples/netcfg-template-single.yaml" -o "$T/g7" "$T/dupcol.csv"
mkdir -p "$T/bad5"
cp "$f" "$T/bad5/00-00-5e-00-53.yaml"
expect_fail "check: incomplete MAC" "$SCRIPTS/check.sh" "$T/bad5"
if [ -n "${ORIGINAL_ISO:-}" ] && command -v xorriso >/dev/null && [ -n "$HASH" ]; then
  xorriso -osirrox on -indev "$ORIGINAL_ISO" -extract /server/user-data "$T/orig" >/dev/null 2>&1
  chmod u+w "$T/orig"
  expect_ok "make-user-data: patch applies" env PASSWORD_HASH="$HASH" "$SCRIPTS/make-user-data.sh" -o "$T/ud" -u admin "$T/orig"
  expect_ok "make-user-data: hash filled in" grep -qF "password: \"$HASH\"" "$T/ud"
  expect_ok "make-user-data: user filled in" grep -q 'username: "admin"' "$T/ud"
  expect_ok "check: generated user-data" "$SCRIPTS/check.sh" -u "$T/ud"
  expect_ok "make-user-data: both 9.1.0-1 fixes" test "$(grep -c 'ONLY FOR HPE HVM 9.1.0-1' "$T/ud")" -eq 2
  expect_fail "make-user-data: refuses patched input" env PASSWORD_HASH="$HASH" "$SCRIPTS/make-user-data.sh" -o "$T/ud2" -u admin "$T/ud"

  # Behaviour of early-/late-commands against a fake root (paths rewritten, sleep shortened).
  if [ $have_yaml -eq 1 ]; then
    R=$T/root
    mkdir -p "$R/cdrom/server" "$R/sys/class/net/lo" "$R/sys/class/net/eth0" "$R/sys/class/net/eth1" \
      "$R/etc/netplan" "$R/target/etc/chrony/sources.d" "$R/target/opt/HPE/installer-config"
    cp -r "$REPO/examples/netcfg" "$R/cdrom/server/netcfg"
    echo 00:00:00:00:00:00 > "$R/sys/class/net/lo/address"
    echo 02:00:00:00:00:01 > "$R/sys/class/net/eth0/address"
    echo 00:00:5E:00:53:02 > "$R/sys/class/net/eth1/address"
    echo 'pool ntp.ubuntu.com iburst' > "$R/target/etc/chrony/sources.d/ubuntu-ntp-pools.sources"
    python3 - "$T/ud" "$T" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["autoinstall"]
open(sys.argv[2] + "/early.sh", "w").write(d["early-commands"][0])
open(sys.argv[2] + "/late.sh", "w").write(d["late-commands"][0])
PY
    for s in early late; do
      sed -e "s#/cdrom#$R/cdrom#g; s#/sys/class/net#$R/sys/class/net#g; s#/run/autoinstall-netcfg#$R/run#g" \
          -e "s#/etc/netplan#$R/etc/netplan#g; s#/target#$R/target#g; s#sleep 180#sleep 0#" \
          "$T/$s.sh" > "$T/$s-test.sh"
    done
    expect_ok "early-commands: MAC of second NIC found" sh "$T/early-test.sh"
    expect_ok "early-commands: key written" grep -qx '00-00-5e-00-53-02' "$R/run/key"
    expect_ok "early-commands: installer network off" grep -q 'ethernets: {}' "$R/etc/netplan/99-empty.yaml"
    expect_ok "late-commands: run" sh "$T/late-test.sh"
    expect_ok "late-commands: short host name" grep -qx 'hvm-02' "$R/target/opt/HPE/installer-config/hostname"
    expect_ok "late-commands: node file copied" cmp -s "$REPO/examples/netcfg/00-00-5e-00-53-02.yaml" \
      "$R/target/opt/HPE/installer-config/00-installer-config.yaml"
    expect_ok "late-commands: NTP servers" test "$(cat "$R/target/etc/chrony/sources.d/autoinstall.sources")" = \
      "$(printf 'server 192.0.2.1 iburst\nserver 192.0.2.2 iburst')"
    expect_ok "late-commands: pools disabled" grep -qx '#pool ntp.ubuntu.com iburst' "$R/target/etc/chrony/sources.d/ubuntu-ntp-pools.sources"
    echo 02:00:00:00:00:02 > "$R/sys/class/net/eth1/address"
    expect_fail "early-commands: abort without matching file" sh "$T/early-test.sh"
    expect_ok "early-commands: abort lists MACs" grep -q 'eth1: 02:00:00:00:00:02' "$T/last"
  else
    sk "early-/late-commands behaviour (python3 PyYAML not installed)"
  fi

  # Fake stick: only the files update-stick.sh needs.
  S=$T/stick
  mkdir -p "$S/server/netcfg" "$S/casper"
  : > "$S/casper/vmlinuz"
  cp "$T/orig" "$S/server/user-data"
  touch "$S/server/netcfg/stale.yaml"
  expect_ok "update-stick: first run" env PASSWORD_HASH="$HASH" "$SCRIPTS/update-stick.sh" -u admin -n "$REPO/examples/netcfg" "$S"
  expect_ok "update-stick: original kept" cmp -s "$T/orig" "$S/server/user-data-original"
  expect_ok "update-stick: netcfg replaced" diff -r "$REPO/examples/netcfg" "$S/server/netcfg"
  expect_ok "update-stick: second run" env PASSWORD_HASH="$HASH" "$SCRIPTS/update-stick.sh" -u admin -n "$REPO/examples/netcfg" "$S"
  expect_ok "update-stick: original still unchanged" cmp -s "$T/orig" "$S/server/user-data-original"
else
  sk "make-user-data, early-/late-commands, update-stick with the original file (set ORIGINAL_ISO, needs xorriso, openssl)"
fi

# --- build-iso.sh -----------------------------------------------------------------------
if [ -n "${ORIGINAL_ISO:-}" ] && [ -n "${BUILD_ISO_DIR:-}" ] && command -v xorriso >/dev/null && [ -n "$HASH" ]; then
  ISO_TMP=$(mktemp -d "$BUILD_ISO_DIR/build-iso-test.XXXXXX")
  NEW=$ISO_TMP/test.iso
  expect_ok "build-iso: build" env PASSWORD_HASH="$HASH" "$SCRIPTS/build-iso.sh" -u admin -n "$REPO/examples/netcfg" "$ORIGINAL_ISO" "$NEW"
  expect_fail "build-iso: refuses existing output" env PASSWORD_HASH="$HASH" "$SCRIPTS/build-iso.sh" -u admin -n "$REPO/examples/netcfg" "$ORIGINAL_ISO" "$NEW"
  expect_fail "build-iso: refuses original as output" env PASSWORD_HASH="$HASH" "$SCRIPTS/build-iso.sh" -f -u admin -n "$REPO/examples/netcfg" "$ORIGINAL_ISO" "$ORIGINAL_ISO"
  report=$(xorriso -indev "$NEW" -report_el_torito plain -report_system_area plain 2>/dev/null)
  expect_ok "build-iso: BIOS boot image" grep -q 'El Torito boot img : *1 *BIOS' <<<"$report"
  expect_ok "build-iso: UEFI boot image" grep -q 'El Torito boot img : *2 *UEFI' <<<"$report"
  expect_ok "build-iso: hybrid MBR/GPT" grep -q 'System area summary: MBR.*GPT' <<<"$report"
  xorriso -osirrox on -indev "$NEW" -extract /server "$ISO_TMP/server" >/dev/null 2>&1
  chmod -R u+w "$ISO_TMP/server"
  expect_ok "build-iso: user-data-original unchanged" cmp -s "$T/orig" "$ISO_TMP/server/user-data-original"
  expect_ok "build-iso: user-data as built" cmp -s "$T/ud" "$ISO_TMP/server/user-data"
  expect_ok "build-iso: netcfg on ISO" diff -r "$REPO/examples/netcfg" "$ISO_TMP/server/netcfg"
else
  sk "build-iso (set ORIGINAL_ISO and BUILD_ISO_DIR, needs xorriso, openssl)"
fi

echo "passed: $pass, failed: $fail, skipped: $skip"
[ $fail -eq 0 ]
