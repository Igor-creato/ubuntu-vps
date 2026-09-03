# SSH fail-safe installer specification

## Problem

The installer can remove the final working SSH path before the replacement
user, key, listener, firewall route, and sudo authority are proven.

## Goal

On Ubuntu Server 24.04, migrate to a selected user's key-only SSH access on a
selected port without losing the previous access path during any prepare,
validation, activation, verification, failure, retry, or rollback state.

## Required behavior

- Parse `--user` and `--port`; validate usernames and ports 1 through 65535.
- Preserve root and target authorized keys; merge only validated public keys.
- Resolve the user's NSS home and primary group; enforce safe SSH ownership and
  modes without assuming `/home/<user>` or `<user>:<user>`.
- Validate sudoers with `visudo` and prove `sudo -n true` in the new session.
- Own only `/etc/ssh/sshd_config.d/00-vps-hardening.conf`; preserve all other
  SSH files and make a unique complete `/etc/ssh` backup.
- Refuse an ambiguous unmanaged active `Port` rather than silently rewriting it.
- Stage old and new ports concurrently; on the new port require public key only.
- Run `sshd -t`, global `sshd -T`, and target/root `sshd -T -C` checks.
- In socket mode run `systemctl daemon-reload` and restart `ssh.socket`; in
  service mode reload or restart `ssh.service`; verify listeners using `ss`.
- Never use `ufw reset`; preserve unrelated and pre-existing rules; prepare
  rules before enable; remove only installer-owned temporary old-port rules.
- Require a real second SSH session on the new port before final hardening.
- Final effective policy must include `PubkeyAuthentication yes`,
  `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
  `PermitRootLogin no`, standard `AuthorizedKeysFile`, and only the selected
  final listener when no user-owned additional listener exists.
- On every failure before commit, restore the previous managed file, reapply
  the original systemd mode, prove an old listener exists, and preserve keys.
- Reruns must be deterministic and must not duplicate keys, config, or UFW
  rules.
- The top-level remote command remains supported. Child bytes must be checked
  against expected SHA-256 values before root execution.
- Standalone WordPress/LAMP UFW flows must allow effective SSH listeners before
  enabling UFW and must not reset unrelated rules.

## Acceptance evidence

- Static: `bash -n` and ShellCheck for every shell file.
- Regression: arguments, validation, config generation, cloud-init precedence,
  key merge, UFW ownership, occupied port, idempotency, and rollback failpoints.
- Ubuntu 24.04 VM: `ssh.socket`, `sshd -t/-T`, correct key success, wrong key
  denial, password denial, root denial, new listener, old listener closure,
  UFW rules, cloud-init conflict, rerun, invalid config rollback, occupied port,
  and missing root key safe stop.
- No private key, token, password, or generated secret may enter Git.

## Non-goals

- Do not change a VPS provider's external security group automatically.
- Do not remove user-owned SSH ports, firewall rules, keys, Match policy, or
  Fail2ban configuration.
- Do not fix the unrelated webhook health-response disclosure in this patch.
