# Morpheus Autoinstaller

How to turn the original HPE HVM installation ISO (HPE Morpheus 9.1) into an unattended installer for HVM nodes:
a USB stick that installs a node without any input.

Status: being set up.

## Planned content
- How the autoinstall that is already built into the ISO works (Ubuntu autoinstall, `user-data`), at a high level,
  and where it has to be extended.
- The extensions: answers for the interactive steps, per-node network configuration (`netcfg/`), and how to generate
  a node's network file from one manual installation (then only the host name and optionally NTP servers are added
  as comments).
- Two fixes that apply **only to 9.1.0-1**: Postfix (`postfix check` / `set-permissions` on first boot) and the
  repository key (`apt-key` → keyring).

Out of scope: performance tuning and other site-specific additions.

## License
MIT (planned).
