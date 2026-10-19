# Node files (`server/netcfg/`)

Every node gets one file in `server/netcfg/` on the installation medium. It is the file the network screen of the
manual installation would have written, plus two comment lines.

## Format

```yaml
# HOSTNAME=hvm-01.example.com
# NTP=192.0.2.1,192.0.2.2
network:
  version: 2
  ...
```

- **File name:** `<key>.yaml`. The key is either
  - the MAC address of **any** NIC of the node, lower case, `-` instead of `:` (e.g. `00-00-5e-00-53-01.yaml`) –
    use the burnt-in address of a physical NIC, not that of a bond; or
  - the DMI serial number (`dmidecode -s system-serial-number`), lower case, without spaces. Placeholder values such
    as `Default string` or `To be filled by O.E.M.` are ignored, the MAC is used then.
- **`# HOSTNAME=`** (required): short name or FQDN. The installer writes the short name to
  `/opt/HPE/installer-config/hostname`.
- **`# NTP=`** (optional): comma-separated NTP servers. They are written to `/etc/chrony/sources.d/autoinstall.sources` and the default
  Ubuntu pools are commented out. Without this line chrony keeps its defaults.
- **Rest:** netplan configuration as written by the HPE installer. The HPE first-boot scripts read only the
  **first** VLAN, else the first bond, else the first ethernet interface with an address (see
  [how-it-works.md](how-it-works.md#what-the-hpe-installer-adds)).

Netplan and `yq` ignore the comment lines, so the file is used as it is.

## Getting the file from one manual installation
The easiest way to get a file that matches what HPE expects for your hardware and network:

1. Install one node **manually** from the original ISO and fill in the network screen (bond, VLAN, address,
   gateway, DNS, …).
2. On the installed node, read the file the installer left behind:

   ```bash
   sudo cat /opt/HPE/installer-config/00-installer-config.yaml
   ```

   This is the same place the autoinstaller later puts the node file.
3. Save it as `server/netcfg/<key>.yaml` (key: MAC or serial number of that node, see above) and add the line
   `# HOSTNAME=<name>` at the top – and, if wanted, `# NTP=<server>[,<server>…]`.

For more nodes, either copy the file and change address and host name, or turn it into a template for the CSV
generator.

## Generating files from a CSV file
[`scripts/gen-netcfg.sh`](../scripts/gen-netcfg.sh) fills a template once per CSV line:

```bash
scripts/gen-netcfg.sh -t examples/netcfg-template.yaml -o netcfg examples/nodes.csv
```

**Template:** a netplan file (e.g. the one from the manual installation) in which node-specific values are
replaced by placeholders `@COLUMN@` – the CSV column name in upper case. Existing `# HOSTNAME=` / `# NTP=` lines
in the template are dropped. Examples:
[`netcfg-template.yaml`](../examples/netcfg-template.yaml) (LACP bond + VLAN),
[`netcfg-template-single.yaml`](../examples/netcfg-template-single.yaml) (one interface).

**CSV:** first line is the header, `,` as separator, no quoting; empty lines and lines starting with `#` are
skipped. Example: [`nodes.csv`](../examples/nodes.csv).

| Column | Required | Meaning |
|---|---|---|
| `key` | yes | MAC address of any NIC (`:` or `-`, any case) or DMI serial number; becomes the file name |
| `hostname` | yes | written as `# HOSTNAME=` |
| `ntp` | no | NTP servers separated by `;`, written as `# NTP=a,b` |
| anything else | – | value for `@COLUMN@` in the template. `;` inside a value becomes `, ` – for YAML flow lists such as `addresses: [@DNS@]` |

The script stops if a key appears twice, a placeholder has no column, or an output file exists (`-f` overwrites).
At the end it runs [`scripts/check.sh`](../scripts/check.sh) on the output directory. The generated example files
are in [`examples/netcfg/`](../examples/netcfg/).

## Checking
```bash
scripts/check.sh netcfg/
```
checks file names, the `# HOSTNAME=` line (valid, unique), the `# NTP=` line, line endings and – with python3 and
PyYAML – YAML syntax and the `network` key.
