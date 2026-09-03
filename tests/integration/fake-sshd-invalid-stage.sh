#!/usr/bin/env bash

set -Eeuo pipefail

for argument in "$@"; do
    if [[ "$argument" == -t ]] && grep -q '^Match User ' /etc/ssh/sshd_config.d/00-vps-hardening.conf 2>/dev/null; then
        printf '%s\n' 'integration fault: staged sshd_config rejected' >&2
        exit 1
    fi
done

exec /usr/sbin/sshd "$@"
