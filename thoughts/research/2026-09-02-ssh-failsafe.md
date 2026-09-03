# Ubuntu VPS SSH fail-safe research

## Scope and evidence

The current installer was traced from `install.sh` into every script that can
change users, sudo, OpenSSH, systemd units, UFW, Fail2ban, packages, or Docker
privileges. Ubuntu 24.04 behavior was checked against Canonical's OpenSSH
documentation, Noble's socket-generator packaging and Launchpad bug 2069041,
OpenSSH 9.6 manuals, cloud-init documentation, and UFW's manual.

## Confirmed root causes

1. `ssh-setup.sh` truncates root's authorized keys before a replacement login
   exists, rewrites the main configuration, and restarts SSH without `sshd -t`.
2. It checks `ssh.service`, not the effective Ubuntu 24.04 `ssh.socket`
   listener, and never verifies the kernel listening socket.
3. It ignores `--user` and `--port`, assumes `/home/<user>` and a same-named
   group, overwrites target keys, and does not validate sudoers with `visudo`.
4. It does not evaluate `sshd_config.d`, cloud-init's snippet, first-value
   precedence, accumulated `Port` values, `Match`, or `AuthorizedKeysFile`.
5. It resets all UFW policy, enables the firewall before proving the new path,
   and lets an unverified yes/no answer authorize removal of port 22.
6. Backup has no restoration consumer; reruns duplicate or destroy state.
7. The WordPress/LAMP scripts independently enable UFW before allowing the
   effective custom SSH port.
8. `install.sh` runs mutable child scripts as root without comparing the
   observed digest to an expected value, and its `set -e` error counter exits
   on the first failed child.

## Alternatives considered

### Convert Noble to permanent `ssh.service`

This makes port changes familiar, but replaces Ubuntu's default activation
model and adds an unnecessary platform divergence. Rejected.

### Keep old and new ports indefinitely

This maximizes availability but does not complete the requested hardening or
prove that the old path can be retired. Rejected as the final state.

### Transactional dual-port cutover with a real second session

Temporarily keep the effective old port, add the new port, validate and apply
the correct systemd mode, allow the new port without resetting UFW, and require
a second key-only SSH session to produce a root-owned transaction marker.
Only then install the final key-only configuration. This is the recommended
approach because it is the only design that preserves the old path while also
proving possession of the new private key and network reachability.

## Recommendation

Implement one managed OpenSSH drop-in and a root-owned transaction directory.
Never delete root keys or user policy. Fail closed when unmanaged active Port
directives make the final listener set ambiguous. Validate the global and
connection-specific effective configuration, apply socket or service mode as
actually active, and roll back only installer-owned changes. Use a disposable
Ubuntu 24.04 VM for end-to-end evidence; Docker and WSL are partial evidence
only for this boundary.
