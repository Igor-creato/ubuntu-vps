#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TEST_DIR
REPO_DIR="$(cd "$TEST_DIR/.." && pwd -P)"
readonly REPO_DIR

while IFS= read -r -d '' script; do
    bash -n "$script"
done < <(find "$REPO_DIR" -path "$REPO_DIR/.git" -prune -o -name '*.sh' -type f -print0)

bash "$TEST_DIR/test_ssh_setup.sh"
bash "$TEST_DIR/test_install.sh"
bash "$TEST_DIR/test_access_scripts.sh"

if command -v shellcheck >/dev/null 2>&1; then
    mapfile -d '' scripts < <(find "$REPO_DIR" -path "$REPO_DIR/.git" -prune -o -name '*.sh' -type f -print0)
    shellcheck "${scripts[@]}"
else
    printf 'NOT RUN: ShellCheck is not installed.\n' >&2
    exit 2
fi
