# Morpheus Autoinstaller

Turn the original HPE HVM installation ISO (HPE Morpheus Software 9.1) into an **unattended installer** for HVM
nodes: boot it, and the node installs itself with its own host name and network configuration – no input needed.

The ISO already runs an Ubuntu autoinstall; HPE only leaves four screens interactive. This repository answers those
screens in `server/user-data` (a small, reviewable patch against the original) and adds one network file per node.
Nothing else on the ISO changes.

> Made for **HPE HVM 9.1.0-1** (`HPE_HVM_Install_26.04_S6E64-11270.iso`). The patch applies only without fuzz; a different
> `server/user-data` gives a warning or an error. Two fixes are included that are valid **only for 9.1.0-1** – see
> [docs/fixes-9.1.0-1.md](docs/fixes-9.1.0-1.md).

## Contents
| Path | What |
|---|---|
| [docs/how-it-works.md](docs/how-it-works.md) | the autoinstall built into the ISO and where it is extended – **start here** |
| [docs/netcfg.md](docs/netcfg.md) | node files: format, taking one from a manual installation, generating them from CSV |
| [docs/build.md](docs/build.md) | building the ISO or updating a USB stick, booting, checks |
| [docs/fixes-9.1.0-1.md](docs/fixes-9.1.0-1.md) | Postfix and repository-key fixes (9.1.0-1 only) |
| [server/user-data.patch](server/user-data.patch) | the changes against the original `server/user-data` |
| [scripts/](scripts/) | `gen-netcfg.sh` (CSV → node files), `build-iso.sh` (new ISO), `update-stick.sh` (writable stick), `check.sh`, `make-user-data.sh` |
| [examples/](examples/) | CSV, templates and generated node files (placeholder values) |
| [tests/run.sh](tests/run.sh) | tests of the scripts |

## Quick start
```bash
# 1. Node files: one per node, from a CSV and a template (or copied from a manual installation)
scripts/gen-netcfg.sh -t examples/netcfg-template.yaml -o netcfg examples/nodes.csv

# 2. Password hash for the local admin user
mkpasswd -m sha-512 > hash.txt

# 3. New ISO next to the original (the original is only read)
scripts/build-iso.sh -u hvmadmin -p hash.txt -n netcfg \
  HPE_HVM_Install_26.04_S6E64-11270.iso HPE_HVM_Install_26.04_autoinstall.iso

# 4. Write it to a USB stick (or mount it virtually) and boot the node from it
sudo dd if=HPE_HVM_Install_26.04_autoinstall.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

**Booting the medium erases the target disk without asking.** Details and checks: [docs/build.md](docs/build.md).

Requirements: `bash`, `patch`, `xorriso` (for `build-iso.sh`); python3 with PyYAML for the YAML checks (optional).

## By hand – without the scripts
The scripts only automate a few file operations. Everything can be done by hand on a writable USB stick made from
the original ISO (e.g. with Rufus, FAT32):

1. **Read the patch** [`server/user-data.patch`](server/user-data.patch) – it is short and every change is marked with
   `# autoinstall:` or `# FIX`. On the stick, rename `server/user-data` to `server/user-data-original` and create the
   new `server/user-data` from it: apply the patch (`patch -o server/user-data server/user-data-original
   user-data.patch`) or make the same changes in an editor.
2. **Fill in** `@USERNAME@` and `@PASSWORD_HASH@` (hash from `mkpasswd -m sha-512`).
3. **Create the folder `server/netcfg/`** with one `<mac>.yaml` per node – the netplan file from a manual
   installation plus the lines `# HOSTNAME=` and optionally `# NTP=`. Format and where to get the file:
   [docs/netcfg.md](docs/netcfg.md); ready-made examples: [examples/netcfg/](examples/netcfg/).

That is the whole autoinstaller. The scripts add checks on top ([docs/build.md](docs/build.md#checks)).

## Scope
Only the unattended installation itself plus the two 9.1.0-1 fixes. No performance tuning, no extra packages, no
site-specific settings – add those to your own copy of the patch if needed.

## References
- [HPE Morpheus Software documentation 9.1.0](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00008772en_us&docLocale=en_US)
  – chapter "HVM Clusters" (hardware requirements, provisioning the cluster)
- [Ubuntu autoinstall reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)

## Author
Pascal Liehne

## License
[MIT](LICENSE), © 2026 Pascal Liehne. HPE, HPE Morpheus and HVM are trademarks of Hewlett Packard Enterprise. This project is not affiliated
with HPE; the ISO itself is not part of it.
