# Ubuntu 24.04 integration test

These tests must run only in a disposable Ubuntu 24.04 VM with systemd. They
exercise the real `ssh.socket`, OpenSSH, UFW, cloud-init drop-ins, Fail2ban and
actual SSH client connections. Test private keys are generated in an operating
system temporary directory and must never be added to this repository.

The implementation is intentionally not advertised as passing merely because
the unit tests succeed. The final report must record each system test as PASS,
FAIL, or NOT RUN and retain the relevant command output.
