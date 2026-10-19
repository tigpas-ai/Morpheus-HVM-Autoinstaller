# Fixes for HPE HVM 9.1.0-1 only

> **Valid only for HPE HVM 9.1.0-1** (ISO `HPE_HVM_Install_26.04_S6E64-11270.iso`, Ubuntu Server 26.04).
> Remove both entries from the patch for any other version and check whether the problem still exists.

Both fixes are the last two entries of `user-data.runcmd` (first boot, after the HPE steps) and are marked
`# FIX - ONLY FOR HPE HVM 9.1.0-1` in [`server/user-data.patch`](../server/user-data.patch).

## Postfix permissions
**Symptom:** after the first boot, Postfix reports wrong ownership, e.g. in `/var/log/cloud-init-output.log`:

```
postfix/postlog: warning: not owned by root: /var/spool/postfix/etc/resolv.conf
```

**Fix:**

```bash
postfix check
postfix set-permissions
```

`postfix check` refreshes the files of the Postfix chroot and reports problems, `postfix set-permissions` sets
ownership and modes of the Postfix files and directories as the package expects them.

## Repository key (`apt-key` → keyring)
**Symptom:** the HPE first-boot steps write `/etc/apt/sources.list.d/hpe-ubuntu.sources` with
`signed-by: /etc/apt/keyrings/zion_repo_public.key`, but the key file is **ASCII-armored**. apt accepts armored keys
only with the extension `.asc` and expects a binary keyring otherwise
([apt-secure(8)](https://manpages.debian.org/apt-secure.8): *"ASCII-armored keys must use an extension of .asc,
and unarmored keys an extension of .gpg."*). Every `apt update` then warns and cannot verify the HPE repositories
(they are still used only because the entries are marked `Trusted: True`):

```
W: …/zion-private-ubuntu/dists/pulp/Release.gpg: The key(s) in the keyring /etc/apt/keyrings/zion_repo_public.key are ignored as the file has an unsupported filetype.
W: OpenPGP signature verification failed: … pulp Release: The following signatures couldn't be verified because the public key is not available: NO_PUBKEY …
```

**Fix:** convert the key to a binary keyring in place – only if it is still armored, so the step is harmless once
HPE ships a binary key:

```bash
key=/etc/apt/keyrings/zion_repo_public.key
if grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$key"; then
  tmp=$(mktemp); gpg --dearmor < "$key" > "$tmp"; install -m 0644 "$tmp" "$key"; rm -f "$tmp"
fi
```

**Check:** `file /etc/apt/keyrings/zion_repo_public.key` → `OpenPGP Public Key …` (not `PGP public key block`).
