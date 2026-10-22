# Building the installation medium

Two ways lead to the same medium – the original ISO with a new `server/user-data`, the unchanged original next to
it as `server/user-data-original`, and `server/netcfg/`:

| Way | Script | When |
|---|---|---|
| new ISO next to the original | [`build-iso.sh`](../scripts/build-iso.sh) | write it to USB with any tool (`dd`, Rufus, …), mount it virtually (BMC, hypervisor) |
| change a writable USB stick | [`update-stick.sh`](../scripts/update-stick.sh) | a stick already written from the original ISO with a tool that keeps a writable FAT32 file system (e.g. Rufus); also to update the node files later |

Both scripts apply [`server/user-data.patch`](../server/user-data.patch) to the original file without fuzz and
warn if its SHA-256 differs from the 9.1.0-1 file. If the patch does not apply, the ISO is not the version this
repository was made for – port the changes by hand.

## Prerequisites
- Original ISO for 9.1.0-1: `HPE_HVM_Install_26.04_S6E64-11270.iso`
  (download from HPE, see the [HPE Morpheus Software documentation 9.1.0](https://support.hpe.com/hpesc/public/docDisplay?docId=sd00008772en_us&docLocale=en_US),
  chapter "HVM Clusters"). `server/user-data` in it has the SHA-256
  `d4a488afa355759b0b4cd5af30597ccabf089c2c7ec46b692f65626aed12d1cc`.
- `xorriso` (only for `build-iso.sh`), `patch`, `bash`; python3 with PyYAML for the full syntax check (optional).
- The node files in a directory, e.g. `netcfg/` ([netcfg.md](netcfg.md)).
- A user name and the password hash for the local admin user:

  ```bash
  mkpasswd -m sha-512 > hash.txt      # package "whois"; or: openssl passwd -6 > hash.txt
  ```

  The hash is read from a file (`-p hash.txt`), stdin (`-p -`) or the environment variable `PASSWORD_HASH` – never
  from the command line.

## New ISO
```bash
scripts/build-iso.sh -u hvmadmin -p hash.txt -n netcfg \
  HPE_HVM_Install_26.04_S6E64-11270.iso HPE_HVM_Install_26.04_autoinstall.iso
```

The original is only read. The script checks the node files, builds and checks the user-data and writes the new ISO
with `xorriso … -boot_image any replay`, which takes over the boot records of the original (BIOS and UEFI El Torito,
hybrid MBR/GPT). At the end it lists the boot images of the new ISO. xorriso warns that the volume ID
`Ubuntu-Server` does not comply with ISO 9660 – that is the original ID and harmless.

Write it to a USB stick, for example:

```bash
sudo dd if=HPE_HVM_Install_26.04_autoinstall.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

A stick written with `dd` is read-only (ISO 9660); to change the node files later, build a new ISO.

## Writable USB stick
Write the original ISO with a tool that creates a writable FAT32 file system (e.g. Rufus in ISO mode), mount it and
run:

```bash
scripts/update-stick.sh -u hvmadmin -p hash.txt -n netcfg /mnt
```

The first run moves `server/user-data` to `server/user-data-original`; later runs build from that file again, so
the script can be repeated, e.g. after adding a node. `server/netcfg/` is replaced completely.

## Booting
- The GRUB entry of the ISO starts the autoinstall after its 30 s timeout. The ISO has boot images for
  legacy BIOS and UEFI; the autoinstall itself does not depend on the boot mode.
- **The target disk is erased without asking.** Without `match` in the storage layout the largest disk is used
  – to choose it by path, device type (model) or SSD, see
  [how-it-works.md](how-it-works.md#choosing-the-target-disk).
- If no node file matches, the installer prints the MAC addresses of all interfaces on the console, waits
  3 minutes and aborts – add a file for one of them.
- Installation, first boot and the second reboot take roughly 10–15 minutes, depending on the hardware.

> Test status: the same changes (node detection, node file, host name, NTP, both fixes) have been used to install
> real nodes from a writable stick. An ISO built by `build-iso.sh` has been checked structurally (boot records,
> files) but not yet booted on a real node.

## Checks
Before building (both scripts run them as well):

```bash
scripts/check.sh netcfg                      # node files
scripts/check.sh -u /path/to/user-data       # generated user-data
```

The new ISO:

```bash
xorriso -indev NEW.iso -report_el_torito plain   # BIOS and UEFI boot images present
xorriso -indev NEW.iso -ls /server /server/netcfg
```

`md5sum.txt` of the ISO still lists the original `server/user-data`; a media check reports that file as changed.

After the installation, on the node:

| Check | Expected |
|---|---|
| `hostname` | short name from `# HOSTNAME=` (set on the first boot) |
| `sudo cat /opt/HPE/installer-config/00-installer-config.yaml` | the node file |
| `ip -br addr` | management address on the HPE switch interfaces created by `hvmcli` |
| `grep '^HPE:' /var/log/cloud-init-output.log` | `configure_mgmt_ip.sh completed`, `configure_node.sh completed`, no `failed` |
| `chronyc sources` | the `# NTP=` servers (if given) |
| `sudo postfix check` | no output ([fix](fixes-9.1.0-1.md#postfix-permissions)) |
| `file /etc/apt/keyrings/zion_repo_public.key` | `OpenPGP Public Key` ([fix](fixes-9.1.0-1.md#repository-key-apt-key--keyring)) |
| `sudo apt-get update` | no `unsupported filetype` / `NO_PUBKEY` warnings |

## Tests of this repository
```bash
tests/run.sh                                     # CSV generator, checks, scripts (no ISO needed)
ORIGINAL_ISO=/path/to/HPE_HVM_Install_26.04_S6E64-11270.iso tests/run.sh     # + patch against the real file
ORIGINAL_ISO=… BUILD_ISO_DIR=/path/with/4GB/free tests/run.sh               # + builds and inspects an ISO
```
The ISO tests need `xorriso`. Nothing outside temporary directories is written.
