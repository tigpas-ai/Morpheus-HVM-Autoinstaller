# Security

The installer runs unattended on bare servers and erases the target disk. Its add-ons run as root against the
installed system. A flaw here can therefore affect every node installed from a medium built with it.

## Reporting a vulnerability
Please do **not** open a public issue. Use GitHub's private vulnerability reporting instead
(**Security** tab → **Report a vulnerability**) and include the affected release, the steps to reproduce and what an
attacker gains. Reports are answered as soon as possible.

## Supported versions
Only the latest release receives fixes.

## Design rules that limit the impact
- The original ISO is only read; the scripts write a new ISO or a separate USB stick and never change the original.
- Secrets stay out of the repository: the password hash (`hash.txt`) and the node files (`netcfg/`) are ignored by git.
  The hash is written to the medium, so protect the ISO and the stick like a credential.
- Add-ons run as root in `/target` during the installation. Use only folders you trust and have reviewed; a failing
  add-on aborts the installation (see [docs/how-it-works.md](docs/how-it-works.md#add-ons)).
- The patch to the vendor `user-data` applies without fuzz, so a different vendor version is rejected instead of
  being changed unnoticed.
