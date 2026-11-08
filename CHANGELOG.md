# Changelog

All notable changes to this project. The release notes on GitHub are taken from the section of the version.

## 0.2.0 – 2026-11-08
- Add-ons: `build-iso.sh -a` and `update-stick.sh -a` put extension folders on the medium as
  `server/addons/<name>/`; a final `late-commands` entry runs each `install.sh` against `/target` and aborts the
  installation on failure. `check.sh -a` checks the folders. See `docs/how-it-works.md`.
- `SECURITY.md` with the reporting channel and design rules; source link in the README.
- Release workflow: pushing a tag `v<version>` runs the tests and publishes a GitHub release with the notes from this
  file.

## 0.1.0 – 2026-10-31
- Autoinstall for HPE HVM nodes (HPE Morpheus 9.1.0-1) from the original installation ISO: a minimal patch
  (`server/user-data.patch`) against the vendor `user-data` that picks the node file by DMI serial number or MAC
  address and applies host name, network and NTP unattended.
- Scripts: `build-iso.sh` (new ISO), `update-stick.sh` (existing USB stick), `make-user-data.sh`,
  `gen-netcfg.sh` (node files from a CSV file) and `check.sh` (checks of the node files).
- Documentation: how the vendor autoinstall works, node file format, build and USB stick paths, target disk
  selection.
- Fixes valid only for 9.1.0-1: Postfix queue directories and permissions, repository key (apt-key → keyring).
- Tests (`tests/run.sh`) and a CI workflow (ShellCheck and tests).
