# Ubuntu VPS SSH Fail-safe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and prove a transactional Ubuntu 24.04 SSH migration that never removes the last working access path before a real replacement login succeeds.

**Architecture:** `scripts/ssh-setup.sh` becomes a sourceable transaction engine with pure validation/configuration helpers and a guarded CLI entry point. It stages a dual-port configuration, applies the active systemd mode, stages only owned UFW rules, and waits for a verifier invoked from a real second key-only SSH session before final hardening. `install.sh` validates child digests and orchestrates update/readback; web installers receive a minimal safe UFW ordering fix.

**Tech Stack:** Bash 5, OpenSSH 9.6p1, systemd, cloud-init, UFW, Fail2ban, plain Bash regression tests, ShellCheck, Multipass/Hyper-V Ubuntu 24.04 VM.

**Spec:** `specs/2026-09-02-ssh-failsafe.md`

## Global Constraints

- Never mutate or test a live VPS.
- Never delete or truncate any authorized key.
- Never reset UFW or remove a rule not created by the active transaction.
- No hardening activation without `sshd -t`, effective-config checks, listener
  readback, and a real new key-only session.
- Use test-first red/green cycles for every new production behavior.
- Keep private test keys in a disposable host temp directory, never Git.

---

### Task 1: Regression harness and pure contracts

**Files:**
- Create: `tests/run.sh`
- Create: `tests/test_ssh_setup.sh`
- Create: `tests/test_install.sh`
- Create: `tests/lib/assert.sh`
- Modify: `scripts/ssh-setup.sh`
- Modify: `install.sh`

**Interfaces:**
- Produces sourceable `validate_username`, `validate_port`,
  `render_stage_config`, `render_final_config`, `merge_authorized_keys`, and
  `parse_args` behavior.

- [ ] Write tests for valid/invalid user and port arguments, repeated parent-to-child argument propagation, occupied ports, exact stage/final config, key validation/deduplication, and strict-mode error counting.
- [ ] Run `bash tests/test_ssh_setup.sh` and `bash tests/test_install.sh`; verify failures identify missing safe interfaces.
- [ ] Implement the smallest sourceable helpers and guarded `main` entry points.
- [ ] Rerun both tests and preserve a clean pass before proceeding.

### Task 2: Transaction, effective OpenSSH validation, and rollback

**Files:**
- Modify: `scripts/ssh-setup.sh`
- Modify: `tests/test_ssh_setup.sh`

**Interfaces:**
- Produces `begin_transaction`, `validate_candidate`, `apply_ssh_runtime`,
  `verify_listener`, `rollback_transaction`, and failpoint behavior.

- [ ] Add failing tests proving invalid candidate config never activates,
  unmanaged active Port conflicts stop before mutation, socket/service modes
  call their distinct apply sequences, and every failpoint restores the prior
  managed file while keeping the old listener.
- [ ] Run the focused tests and confirm expected red results.
- [ ] Implement unique backup/state, atomic managed-file writes, `sshd -t/-T/-C`
  assertions, systemd mode detection/application, listener readback, ERR trap,
  and installer-owned rollback.
- [ ] Rerun focused and full tests.

### Task 3: User, key, sudo, UFW, and real-session gate

**Files:**
- Modify: `scripts/ssh-setup.sh`
- Modify: `tests/test_ssh_setup.sh`

**Interfaces:**
- Produces `prepare_user`, `install_public_key`, `configure_sudo`,
  `stage_ufw`, `create_session_verifier`, and `await_session_verification`.

- [ ] Add failing tests for custom homes/groups, existing key preservation,
  invalid key rejection, missing root key safe stop, UFW active/inactive and
  pre-existing ownership, rerun idempotency, verifier user/port/nonce checks,
  timeout rollback, and sudo validation.
- [ ] Run focused tests and confirm expected red results.
- [ ] Implement NSS-aware atomic key merge, validated sudoers, UFW state and
  owned-rule tracking, root-owned nonce verifier, timeout handling, and final
  key-only hardening.
- [ ] Rerun focused and full tests.

### Task 4: Parent orchestration and sibling firewall entry points

**Files:**
- Modify: `install.sh`
- Modify: `scripts/apache-wordpress.sh`
- Modify: `scripts/lamp-wp.sh`
- Modify: `scripts/install-docker.sh`
- Modify: `tests/test_install.sh`

**Interfaces:**
- Parent passes the selected admin identity, verifies expected SHA-256, runs SSH
  migration before nonessential package mutation, and performs post-update
  read-only verification.

- [ ] Add failing tests for digest mismatch, safe `set -e` error accumulation,
  help without root/network, no `autoremove --purge`, SSH-safe UFW enable
  ordering, custom-port preservation, and no Docker user guessing.
- [ ] Run focused tests and confirm expected red results.
- [ ] Implement minimal parent and sibling-script changes, then calculate and
  embed the exact expected child digests.
- [ ] Rerun focused and full tests.

### Task 5: Static and disposable Ubuntu 24.04 integration evidence

**Files:**
- Create: `tests/integration/cloud-init.yaml`
- Create: `tests/integration/run-multipass.ps1`
- Create: `tests/integration/run-inside-vm.sh`
- Modify: `README.md`

**Interfaces:**
- `tests/run.sh` runs static/unit checks; the PowerShell runner creates named
  disposable VMs and emits a PASS/FAIL/NOT RUN evidence directory.

- [ ] Add the integration harness without any private key fixture.
- [ ] Run all unit tests, `bash -n`, and ShellCheck.
- [ ] Install Multipass, create disposable Ubuntu 24.04 VM instances, and run
  all thirteen required SSH/cloud-init/socket/UFW/rerun/rollback scenarios.
- [ ] Capture `sshd -T`, `ss -lntp`, UFW, systemd, correct/wrong key, password,
  and root-login outputs; delete the named VMs after evidence collection.

### Task 6: Adversarial review and final gates

**Files:**
- Review all changed files and tests.

**Interfaces:**
- Produces the final evidence-backed patch and report.

- [ ] Run one fresh bypass/regression reviewer on the candidate diff.
- [ ] Reproduce and fix only confirmed findings with a new red/green test.
- [ ] Rerun every static, regression, and integration gate from a clean state.
- [ ] Inspect `git diff`, scan it for secrets/private keys/tokens/passwords,
  run `git diff --check`, and show final `git status`.
- [ ] Map every acceptance criterion to code and fresh test evidence; mark any
  unavailable environment-dependent scenario `NOT RUN`, never `PASS`.
