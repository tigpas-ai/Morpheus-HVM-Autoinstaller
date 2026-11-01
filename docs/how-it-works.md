# How the built-in autoinstall works

The HPE HVM installation ISO is an Ubuntu Server live ISO (Subiquity installer) that **already starts an
autoinstall** – it is only made semi-interactive on purpose. This page shows the parts that matter and where the
autoinstaller of this repository hooks in. It does not go through every vendor file.

## Boot entry
The only GRUB entry of the ISO (`/boot/grub/grub.cfg`) is:

```
linux /casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/server/ ...
```

- `autoinstall` – Subiquity runs the autoinstall configuration without asking for confirmation.
- `ds=nocloud;s=/cdrom/server/` – cloud-init's NoCloud data source reads `server/user-data` and `server/meta-data`
  from the boot medium (`/cdrom` in the installer).

So everything is controlled by **one file, `server/user-data`**. GRUB and the boot records stay untouched.

## The original `server/user-data`
In short (see the [Ubuntu autoinstall reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)
for the keys):

| Part | Original content | Effect |
|---|---|---|
| `apt`, `source`, `packages`, `refresh-installer` | offline install of `ubuntu-server-minimal`, no updates | fixed by HPE, unchanged here |
| `timezone`, `keyboard`, `locale` | `America/Denver`, `us`, `en_US.UTF-8` | defaults, adjust if needed |
| `interactive-sections` | `locale`, `identity`, `network`, `storage` | **these four screens are still asked** |
| `storage.layout` | `direct` | whole disk, no LVM |
| `user-data.runcmd` | HPE first-boot steps (below) | runs once on the first boot of the installed system |

`interactive-sections` is the only reason the installation stops. Every section listed there is shown as a
screen, with the values of the file as defaults.

## What the HPE installer adds
Two HPE-specific parts tie the installer to the first boot:

1. **Network screen (patched Subiquity).** HPE's Subiquity writes the network configuration entered on the
   network screen not to `/etc/netplan/`, but to
   **`/opt/HPE/installer-config/00-installer-config.yaml`** on the target (netplan format, mode 0600). Host name
   and proxy from the same screen go to `/opt/HPE/installer-config/hostname` and `…/proxy-url`.
2. **First boot (`runcmd`).** Among other steps it installs `hvmcli` and then runs
   - `/usr/local/sbin/configure_mgmt_ip.sh` – reads `00-installer-config.yaml` (with `yq`) and creates the
     management virtual switch `vs0` with `hvmcli virtswitch create`: uplink interfaces, bond mode, VLAN, IP,
     netmask and gateway are taken from the **first** VLAN entry, else the first bond, else the first ethernet
     interface with an address;
   - `/usr/local/sbin/configure_node.sh` – DNS servers and search domains (same entry), proxy (`proxy-url`) and
     host name (`hostname`) via `hvmcli node configure`.

   Then the system reboots. The file under `/opt/HPE/installer-config/` is an **input for `hvmcli`**, not the
   final netplan configuration; `hvmcli` writes its own files to `/etc/netplan/`.

```
GRUB ─► Subiquity reads /cdrom/server/user-data
          ├─ screens from interactive-sections (locale, identity, network, storage)
          ├─ network screen ─► /target/opt/HPE/installer-config/{00-installer-config.yaml,hostname,proxy-url}
          └─ install, reboot
first boot ─► runcmd: hvmcli, configure_mgmt_ip.sh (vs0), configure_node.sh (DNS, proxy, host name), reboot
```

## Where the autoinstaller extends it
The extension only changes `server/user-data` ([`server/user-data.patch`](../server/user-data.patch)) and adds
`server/netcfg/` to the medium. Changes are marked with `# autoinstall:` or `# FIX` comments in the file.

| Change | Why |
|---|---|
| `identity` (user name, password hash, placeholder host name) | answers the identity screen |
| `interactive-sections` commented out | no screen is shown any more |
| `early-commands` | find the node's file in `server/netcfg/` – by DMI serial number, else by the MAC address of any interface; abort with a list of MAC addresses if none matches. Switch the installer network off so it does not wait for DHCP. |
| `late-commands` | do what the network screen would have done: copy the node's file to `/target/opt/HPE/installer-config/00-installer-config.yaml`, write the host name from its `# HOSTNAME=` line to `…/hostname`; optional `# NTP=` servers for chrony. The placeholder host name from `identity` is replaced by `configure_node.sh` on the first boot. |
| a second `late-commands` entry | runs the [add-ons](#add-ons) on the medium, if there are any (otherwise it does nothing) |
| two `runcmd` entries at the end | [fixes for 9.1.0-1 only](fixes-9.1.0-1.md) |

Because the HPE first-boot scripts find their input files exactly where the manual installation leaves them,
nothing else has to change. This is also why a node file can be taken from one manual installation – see
[netcfg.md](netcfg.md).

Not handled: the proxy field of the network screen (`proxy-url`). If you need it, add a late-command that writes
`/target/opt/HPE/installer-config/proxy-url`.

## Add-ons
The repository itself contains no extras, but the medium can carry additional folders that the installer runs at
the end of the installation – for site-specific settings or separately maintained packages. Convention:

- An add-on is a flat folder, copied as a whole to `server/addons/<name>/` on the medium (`build-iso.sh -a`,
  `update-stick.sh -a`, repeatable; `<name>` is the folder name, which must be unique).
- Entry point: `bash <folder>/install.sh <folder> <target-root>`. `<folder>` is the add-on's path on the medium
  (`/cdrom/server/addons/<name>`), `<target-root>` is the installed system (`/target`). The script is started with
  `bash` because FAT32 and ISO 9660 carry no file permissions.
- The script must be idempotent and must not need the network (the installer network is off). Exit code 0 means
  success; anything else aborts the installation.
- Checking and versioning are the add-on's own business, not the installer's.

The add-ons run in alphabetical order of their folder names, in the last `late-commands` entry, after the node's
network file has been put in place.

## Choosing the target disk
The target disk is chosen by the `direct` layout: without `match` Subiquity takes the **largest disk**. With
several disks, pin it with `match` under `storage.layout` – the patch contains a commented example. The keys are
described in the [autoinstall reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)
(section "storage"):

| Match | Selects | Note |
|---|---|---|
| `path: /dev/sda` | the kernel device name | names can change with more disks or USB media |
| `model: "…"` | the **device type** (udev `ID_MODEL`) | same for all nodes with the same disk model – usually the best choice for one hardware type |
| `vendor: "…"` | udev `ID_VENDOR` | often only the bus (`ATA`), rarely useful alone |
| `serial: "…"` | one physical disk (udev `ID_SERIAL`) | differs per node; `ID_SERIAL` is usually model **and** serial number (`<model>_<serial>`), so use a glob such as `"*_<serial>"` |
| `ssd: true` | any non-rotational disk | combined with `size: largest`/`smallest` to pick among several |

`model`, `vendor`, `serial`, `path` are shell-style globs (`*`, `?`), compared **case-sensitively**; all keys
given must match. `match` may also be a list – the first entry that finds a disk wins, e.g. a model first and the
largest disk as fallback:

```yaml
  storage:
    layout:
      name: direct
      match:
        - model: "EXAMPLE_SSD_500*"
        - size: largest
```

### Finding the device type
The value Subiquity compares is the udev property `ID_MODEL`, in which **spaces are replaced by `_`** – it is
**not** the model as shown by `lsblk`. Read it on any running Linux on the same hardware, or in the shell of the
**original** (interactive) ISO: boot it, wait for the first screen, then "Help › Enter shell". Do not do this with
the autoinstall medium – it erases the disk without stopping.

```bash
lsblk -d -o NAME,TRAN,ROTA,SIZE,MODEL,SERIAL         # overview: which disk is which (ROTA 0 = SSD)
udevadm info --query=property /dev/sdX | grep -E '^ID_(MODEL|VENDOR|SERIAL)='
```

Example: `lsblk` shows `EXAMPLE SSD 500`, `udevadm` shows `ID_MODEL=EXAMPLE_SSD_500` → `model: "EXAMPLE_SSD_500*"`.
After an installation, `/var/log/installer/subiquity-server-debug.log` on the node shows the disks Subiquity
considered and the one it chose (`grep -E 'considering \[|For match|No devices satisfy'`).
