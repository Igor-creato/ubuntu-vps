#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly SCRIPT_VERSION="3.0.1"

LOG_FILE="${LOG_FILE:-/var/log/ubuntu-vps-ssh-setup.log}"
STATE_ROOT="${STATE_ROOT:-/var/lib/ubuntu-vps/ssh-transactions}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/ubuntu-vps}"
LOCK_FILE="${LOCK_FILE:-/run/lock/ubuntu-vps-ssh.lock}"
SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSH_CONFIG_DIR="${SSH_CONFIG_DIR:-/etc/ssh/sshd_config.d}"
MANAGED_CONFIG="${MANAGED_CONFIG:-/etc/ssh/sshd_config.d/00-vps-hardening.conf}"
ROOT_AUTHORIZED_KEYS="${ROOT_AUTHORIZED_KEYS:-/root/.ssh/authorized_keys}"
FAIL2BAN_CONFIG="${FAIL2BAN_CONFIG:-/etc/fail2ban/jail.d/90-ubuntu-vps-ssh.conf}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
SS_BIN="${SS_BIN:-ss}"
SSHD_BIN="${SSHD_BIN:-/usr/sbin/sshd}"
UFW_BIN="${UFW_BIN:-ufw}"
VISUDO_BIN="${VISUDO_BIN:-visudo}"
FAIL2BAN_BIN="${FAIL2BAN_BIN:-fail2ban-client}"

USERNAME=""
SSHD_PORT=""
PUBLIC_KEY_FILE=""
ENABLE_UFW=true
VERIFICATION_TIMEOUT=600
VERIFY_ONLY=false
TRANSACTION_ID=""
TRANSACTION_DIR="${TRANSACTION_DIR:-}"
OLD_PORT=""
TRANSACTION_ACTIVE=false
ROLLBACK_RUNNING=false
TEMP_FILES=()
ADOPTED_PORT_RECORDS=()

log() {
    local level="$1"
    shift
    local message="$*"
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" | tee -a "$LOG_FILE"
}

die() { log ERROR "$*"; return 1; }
error_exit() { die "$*"; exit 1; }

show_help() {
    cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION
Fail-safe OpenSSH migration for Ubuntu VPS.

Usage: $SCRIPT_NAME [options]
  --user NAME                  Existing or new administrative user
  --port PORT                  New SSH port (1-65535)
  --public-key-file PATH       Public key or authorized_keys file to merge
  --enable-ufw                 Configure/enable UFW (default)
  --no-ufw                     Do not change UFW
  --verification-timeout SEC   Wait for a real second SSH session (default 600)
  --verify-only                Read-only effective config/listener check
  --help, -h                   Show this help
EOF
}

reset_cli_state() {
    USERNAME=""; SSHD_PORT=""; PUBLIC_KEY_FILE=""
    ENABLE_UFW=true; VERIFICATION_TIMEOUT=600; VERIFY_ONLY=false
}

validate_username() {
    local value="${1-}"
    [[ "$value" != root && "$value" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]
}

target_passwd_record_is_non_root() {
    local record="$1" uid
    IFS=: read -r _ _ uid _ <<<"$record"
    [[ "$uid" =~ ^[0-9]+$ ]] && ((10#$uid != 0))
}
validate_port() {
    local value="${1-}"
    [[ "$value" =~ ^[0-9]+$ && ${#value} -le 5 ]] && ((10#$value >= 1 && 10#$value <= 65535))
}

ssh_connection_local_port() {
    local _client _client_port _server local_port
    IFS=' ' read -r _client _client_port _server local_port <<<"${1-}"
    validate_port "${local_port:-}" || return 1
    printf '%s\n' "$local_port"
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --user) (($# >= 2)) || error_exit "Для --user требуется значение"; USERNAME="$2"; shift 2 ;;
            --port) (($# >= 2)) || error_exit "Для --port требуется значение"; SSHD_PORT="$2"; shift 2 ;;
            --public-key-file) (($# >= 2)) || error_exit "Для --public-key-file требуется значение"; PUBLIC_KEY_FILE="$2"; shift 2 ;;
            --enable-ufw) ENABLE_UFW=true; shift ;;
            --no-ufw) ENABLE_UFW=false; shift ;;
            --verification-timeout) (($# >= 2)) || error_exit "Для --verification-timeout требуется значение"; VERIFICATION_TIMEOUT="$2"; shift 2 ;;
            --verify-only) VERIFY_ONLY=true; shift ;;
            --help|-h) show_help; return 2 ;;
            *) error_exit "Неизвестный параметр: $1" ;;
        esac
    done
    [[ -z "$USERNAME" ]] || validate_username "$USERNAME" || error_exit "Некорректное имя пользователя: $USERNAME"
    [[ -z "$SSHD_PORT" ]] || validate_port "$SSHD_PORT" || error_exit "Некорректный SSH-порт: $SSHD_PORT"
    if ! [[ "$VERIFICATION_TIMEOUT" =~ ^[0-9]+$ ]] || ((10#$VERIFICATION_TIMEOUT < 1)); then
        error_exit "Некорректный timeout проверки"
    fi
}

render_stage_config() {
    local old_port="$1" new_port="$2" username="$3"
    cat <<EOF
# Managed by ubuntu-vps. Do not edit while a migration is active.
Port $old_port
Port $new_port
StrictModes yes

Match User $username LocalPort $new_port
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey

Match all
EOF
}

render_final_config() {
    cat <<EOF
# Managed by ubuntu-vps.
Port $1
StrictModes yes
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
PermitRootLogin no
EOF
}

public_key_file_is_safe() {
    local source="$1"
    [[ -s "$source" ]] || return 1
    if grep -Eq -- '-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' "$source"; then return 1; fi
    ssh-keygen -l -f "$source" >/dev/null 2>&1
}

merge_authorized_keys() {
    local destination="$1" source="$2" line temporary
    public_key_file_is_safe "$source" || return 1
    mkdir -p "$(dirname "$destination")"; touch "$destination"
    temporary="$(mktemp "${destination}.tmp.XXXXXX")"; TEMP_FILES+=("$temporary")
    cat "$destination" > "$temporary"
    if [[ -s "$temporary" ]] && [[ "$(tail -c 1 "$temporary" | wc -l)" -eq 0 ]]; then printf '\n' >> "$temporary"; fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"; [[ -n "$line" ]] || continue; [[ "$line" =~ ^[[:space:]]*# ]] && continue
        grep -Fqx -- "$line" "$temporary" || printf '%s\n' "$line" >> "$temporary"
    done < "$source"
    mv -f "$temporary" "$destination"
}

apply_ssh_runtime() {
    if "$SYSTEMCTL_BIN" is-active --quiet ssh.socket; then
        "$SYSTEMCTL_BIN" daemon-reload
        "$SYSTEMCTL_BIN" restart ssh.socket
    else
        "$SYSTEMCTL_BIN" reload-or-restart ssh.service
    fi
}

port_is_listening() {
    "$SS_BIN" -H -lnt | awk -v expected="$1" '$1 == "LISTEN" { address=$4; sub(/^.*:/,"",address); if (address==expected) found=1 } END { exit(found ? 0 : 1) }'
}

find_unmanaged_port_directives() {
    local main_config="$1" config_dir="$2" managed_config="$3" file
    local -a files=("$main_config")
    if [[ -d "$config_dir" ]]; then
        while IFS= read -r file; do files+=("$file"); done < <(find "$config_dir" -maxdepth 1 -type f -name '*.conf' -print | sort)
    fi
    for file in "${files[@]}"; do
        [[ -f "$file" && "$file" != "$managed_config" ]] || continue
        awk -v source="$file" '
            {
                line=$0
                sub(/^[[:space:]]*/, "", line)
                if (line == "" || line ~ /^#/) next
                keyword=line
                sub(/[=[:space:]].*$/, "", keyword)
                if (tolower(keyword) == "match") { in_match=1; next }
                if (!in_match && tolower(keyword) == "port") {
                    value=line
                    sub(/^[^=[:space:]]+/, "", value)
                    sub(/^[[:space:]]*/, "", value)
                    sub(/^=[[:space:]]*/, "", value)
                    port=value
                    sub(/[[:space:]].*$/, "", port)
                    print source "\t" NR "\t" port "\t" line
                }
            }
        ' "$file"
    done
}

unmanaged_port_records_are_adoptable() {
    local expected_port="$1" records="${2:-}" source line_number port directive
    [[ -n "$records" ]] || return 0
    while IFS=$'\t' read -r source line_number port directive; do
        [[ -n "$source" && "$line_number" =~ ^[1-9][0-9]*$ && "$port" =~ ^[0-9]+$ && -n "$directive" ]] || return 1
        [[ "$port" == "$expected_port" ]] || return 1
    done <<< "$records"
}

format_unmanaged_port_records() {
    local records="${1:-}" source line_number port directive
    while IFS=$'\t' read -r source line_number port directive; do
        [[ -n "$source" ]] || continue
        printf '%s:%s:%s\n' "$source" "$line_number" "$directive"
    done <<< "$records"
}

backup_adopted_port_configs() {
    local backup_dir manifest source line_number port directive index=0
    local -A seen=()
    [[ -n "$TRANSACTION_DIR" ]] || return 1
    backup_dir="$TRANSACTION_DIR/adopted-port-configs"
    manifest="$backup_dir/manifest"
    mkdir -p "$backup_dir"
    : > "$manifest"
    ((${#ADOPTED_PORT_RECORDS[@]} > 0)) || return 0
    printf '%s\n' "${ADOPTED_PORT_RECORDS[@]}" > "$backup_dir/records.before"
    for directive in "${ADOPTED_PORT_RECORDS[@]}"; do
        IFS=$'\t' read -r source line_number port _ <<< "$directive"
        [[ -f "$source" && -n "$line_number" && -n "$port" ]] || return 1
        [[ "$source" != *$'\t'* && "$source" != *$'\n'* ]] || return 1
        [[ -z "${seen[$source]:-}" ]] || continue
        seen["$source"]=1
        cp -a -- "$source" "$backup_dir/$index.before"
        printf '%s\t%s\n' "$index" "$source" >> "$manifest"
        index=$((index + 1))
    done
    chmod 0600 "$manifest" "$backup_dir/records.before"
}

neutralize_adopted_port_configs() {
    local expected_port="$1" backup_dir manifest index source backup temporary current_records expected_records
    ((${#ADOPTED_PORT_RECORDS[@]} > 0)) || return 0
    backup_dir="$TRANSACTION_DIR/adopted-port-configs"
    manifest="$backup_dir/manifest"
    [[ -f "$manifest" && -f "$backup_dir/records.before" ]] || return 1
    expected_records="$(printf '%s\n' "${ADOPTED_PORT_RECORDS[@]}")"
    current_records="$(find_unmanaged_port_directives "$SSHD_CONFIG" "$SSH_CONFIG_DIR" "$MANAGED_CONFIG")"
    [[ "$current_records" == "$expected_records" ]] || {
        log ERROR "Port directives изменились после preflight; финальная активация отменена"
        return 1
    }
    while IFS=$'\t' read -r index source; do
        [[ -n "$index" && -n "$source" ]] || continue
        backup="$backup_dir/$index.before"
        [[ -f "$backup" && -f "$source" ]] || return 1
        cmp -s -- "$backup" "$source" || {
            log ERROR "SSH config изменён после backup: $source"
            return 1
        }
    done < "$manifest"
    while IFS=$'\t' read -r index source; do
        [[ -n "$index" && -n "$source" ]] || continue
        temporary="$(mktemp "$(dirname "$source")/.ubuntu-vps-port.XXXXXX")"
        TEMP_FILES+=("$temporary")
        awk -v expected="$expected_port" '
            {
                line=$0
                sub(/^[[:space:]]*/, "", line)
                if (line == "" || line ~ /^#/) { print; next }
                keyword=line
                sub(/[=[:space:]].*$/, "", keyword)
                if (tolower(keyword) == "match") { in_match=1; print; next }
                if (!in_match && tolower(keyword) == "port") {
                    value=line
                    sub(/^[^=[:space:]]+/, "", value)
                    sub(/^[[:space:]]*/, "", value)
                    sub(/^=[[:space:]]*/, "", value)
                    port=value
                    sub(/[[:space:]].*$/, "", port)
                    if (port == expected) {
                        print "# ubuntu-vps-disabled-port: " line
                        changed++
                        next
                    }
                }
                print
            }
            END { if (changed == 0) exit 1 }
        ' "$source" > "$temporary"
        chmod --reference="$source" "$temporary"
        mv -f -- "$temporary" "$source"
    done < "$manifest"
}

restore_adopted_port_configs() {
    local backup_dir manifest index source backup status=0
    ((${#ADOPTED_PORT_RECORDS[@]} > 0)) || return 0
    backup_dir="$TRANSACTION_DIR/adopted-port-configs"
    manifest="$backup_dir/manifest"
    [[ -f "$manifest" ]] || return 1
    while IFS=$'\t' read -r index source; do
        [[ -n "$index" && -n "$source" ]] || continue
        backup="$backup_dir/$index.before"
        if [[ -e "$backup" ]]; then
            cp -a -- "$backup" "$source" || status=1
        else
            status=1
        fi
    done < "$manifest"
    return "$status"
}

backup_managed_config() {
    [[ -n "$TRANSACTION_DIR" ]] || return 1; mkdir -p "$TRANSACTION_DIR"
    rm -f "$TRANSACTION_DIR/managed-config.existed" "$TRANSACTION_DIR/managed-config.absent"
    if [[ -e "$MANAGED_CONFIG" ]]; then
        cp -a "$MANAGED_CONFIG" "$TRANSACTION_DIR/managed-config.before"; touch "$TRANSACTION_DIR/managed-config.existed"
    else
        rm -f "$TRANSACTION_DIR/managed-config.before"; touch "$TRANSACTION_DIR/managed-config.absent"
    fi
}

restore_managed_config() {
    if [[ -e "$TRANSACTION_DIR/managed-config.existed" ]]; then
        mkdir -p "$(dirname "$MANAGED_CONFIG")"; cp -a "$TRANSACTION_DIR/managed-config.before" "$MANAGED_CONFIG"
    elif [[ -e "$TRANSACTION_DIR/managed-config.absent" ]]; then rm -f "$MANAGED_CONFIG"
    else return 1; fi
}

backup_fail2ban_config() {
    [[ -n "$TRANSACTION_DIR" ]] || return 1
    mkdir -p "$TRANSACTION_DIR"
    rm -f "$TRANSACTION_DIR/fail2ban-config.existed" "$TRANSACTION_DIR/fail2ban-config.absent"
    if [[ -e "$FAIL2BAN_CONFIG" ]]; then
        cp -a "$FAIL2BAN_CONFIG" "$TRANSACTION_DIR/fail2ban-config.before"
        touch "$TRANSACTION_DIR/fail2ban-config.existed"
    else
        rm -f "$TRANSACTION_DIR/fail2ban-config.before"
        touch "$TRANSACTION_DIR/fail2ban-config.absent"
    fi
}

restore_fail2ban_config() {
    if [[ -e "$TRANSACTION_DIR/fail2ban-config.existed" ]]; then
        mkdir -p "$(dirname "$FAIL2BAN_CONFIG")"
        cp -a "$TRANSACTION_DIR/fail2ban-config.before" "$FAIL2BAN_CONFIG"
    elif [[ -e "$TRANSACTION_DIR/fail2ban-config.absent" ]]; then
        rm -f "$FAIL2BAN_CONFIG"
    else
        return 1
    fi
}

assert_effective_value() {
    local effective="$1" key="${2,,}" expected="${3,,}"
    awk -v key="$key" -v expected="$expected" 'tolower($1)==key && tolower($2)==expected {found=1} END {exit(found ? 0 : 1)}' <<<"$effective"
}

authorized_keys_path_supported() {
    awk 'tolower($1)=="authorizedkeysfile" {for(i=2;i<=NF;i++) if($i==".ssh/authorized_keys" || $i=="%h/.ssh/authorized_keys") found=1} END {exit(found ? 0 : 1)}' <<<"$1"
}

ufw_is_active() { LC_ALL=C "$UFW_BIN" status | grep -Fq 'Status: active'; }

ufw_rule_exists() {
    local port="$1"
    LC_ALL=C "$UFW_BIN" show added | awk -v prefix="ufw allow $port/tcp" '
        $0 == prefix || index($0, prefix " comment ") == 1 { found=1 }
        END { exit(found ? 0 : 1) }
    '
}

ufw_transaction_comment() { printf 'ubuntu-vps-%s-%s\n' "$TRANSACTION_ID" "$1"; }

ufw_owned_rule_exists() {
    local port="$1" comment="$2"
    LC_ALL=C "$UFW_BIN" show added | grep -Fqx -- "ufw allow $port/tcp comment '$comment'"
}

ensure_ufw_rule() {
    local port="$1" comment
    ufw_rule_exists "$port" && return 0
    comment="$(ufw_transaction_comment "$port")"
    "$UFW_BIN" allow "$port/tcp" comment "$comment"
    printf '%s\n' "$comment" > "$TRANSACTION_DIR/ufw-created-$port"
}

delete_owned_ufw_rule() {
    local port="$1" marker="$TRANSACTION_DIR/ufw-created-$1" comment
    [[ -s "$marker" ]] || return 0
    comment="$(cat "$marker")"
    if ufw_owned_rule_exists "$port" "$comment"; then
        "$UFW_BIN" --force delete allow "$port/tcp" comment "$comment"
    else
        log WARN "UFW rule $port/tcp больше не принадлежит транзакции; правило сохранено"
    fi
    rm -f "$marker"
}

stage_ufw() {
    local old_port="$1" new_port="$2" initially_active
    [[ -n "$TRANSACTION_DIR" ]] || return 1; mkdir -p "$TRANSACTION_DIR"
    if [[ ! -e "$TRANSACTION_DIR/ufw-prestate-recorded" ]]; then
        initially_active=false; ufw_is_active && initially_active=true
        printf '%s\n' "$initially_active" > "$TRANSACTION_DIR/ufw-initially-active"; touch "$TRANSACTION_DIR/ufw-prestate-recorded"
    else initially_active="$(cat "$TRANSACTION_DIR/ufw-initially-active")"; fi
    ensure_ufw_rule "$old_port"
    ensure_ufw_rule "$new_port"
    if ! ufw_is_active; then "$UFW_BIN" --force enable; touch "$TRANSACTION_DIR/ufw-enabled-by-transaction"; fi
}

rollback_ufw() {
    local old_port="$1" new_port="$2" port
    for port in "$new_port" "$old_port"; do
        delete_owned_ufw_rule "$port"
    done
    if [[ -e "$TRANSACTION_DIR/ufw-enabled-by-transaction" ]]; then "$UFW_BIN" disable; rm -f "$TRANSACTION_DIR/ufw-enabled-by-transaction"; fi
}

finalize_ufw() {
    local old_port="$1" new_port="$2"
    [[ "$old_port" == "$new_port" ]] && return 0
    delete_owned_ufw_rule "$old_port"
}

create_session_verifier() {
    local destination="$1" transaction_id="$2" expected_user="$3" expected_port="$4" marker="$5"
    cat > "$destination" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
[[ \$EUID -eq 0 ]] || { echo 'Verifier must run through sudo.' >&2; exit 1; }
[[ \${1-} == '$transaction_id' ]] || { echo 'Wrong transaction id.' >&2; exit 1; }
[[ \${SUDO_USER-} == '$expected_user' ]] || { echo 'Wrong SSH user.' >&2; exit 1; }
IFS=' ' read -r _ _ _ local_port <<<"\${SSH_CONNECTION-}"
[[ \${local_port-} == '$expected_port' ]] || { echo 'Wrong SSH local port.' >&2; exit 1; }
printf '%s\n' '$expected_user:$expected_port' > '$marker'
chmod 0600 '$marker'
EOF
    chmod 0755 "$destination"
}

require_public_key_source() {
    if [[ -n "${1-}" ]]; then [[ -s "$1" ]] || return 1; printf '%s\n' "$1"
    elif [[ -s "$2" ]]; then printf '%s\n' "$2"
    else return 1; fi
}

require_root() { [[ $EUID -eq 0 ]] || error_exit "Скрипт должен выполняться от root"; }

check_os() {
    [[ -r /etc/os-release ]] || error_exit "Не найден /etc/os-release"
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == ubuntu ]] || error_exit "Поддерживается только Ubuntu"
    case "${VERSION_ID:-}" in 22.04|24.04) ;; *) error_exit "Поддерживаются Ubuntu 22.04 и 24.04; обнаружена ${VERSION_ID:-unknown}" ;; esac
    log INFO "Ubuntu ${VERSION_ID}; основной доказательный target — 24.04 LTS"
}

install_dependencies() {
    local -a missing_packages=()
    [[ -x "$SSHD_BIN" ]] || error_exit "OpenSSH Server уже должен быть установлен; автоматическая установка до подготовки recovery-доступа запрещена"
    command -v ssh-keygen >/dev/null 2>&1 || missing_packages+=(openssh-client)
    command -v flock >/dev/null 2>&1 || missing_packages+=(util-linux)
    command -v "$VISUDO_BIN" >/dev/null 2>&1 || missing_packages+=(sudo)
    command -v "$SS_BIN" >/dev/null 2>&1 || missing_packages+=(iproute2)
    if [[ "$ENABLE_UFW" == true ]]; then
        command -v "$UFW_BIN" >/dev/null 2>&1 || missing_packages+=(ufw)
    fi
    command -v "$FAIL2BAN_BIN" >/dev/null 2>&1 || missing_packages+=(fail2ban)
    ((${#missing_packages[@]} > 0)) || return 0
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q "${missing_packages[@]}"
    command -v ssh-keygen >/dev/null
    command -v flock >/dev/null
    command -v "$VISUDO_BIN" >/dev/null
    command -v "$SS_BIN" >/dev/null
    if [[ "$ENABLE_UFW" == true ]]; then
        command -v "$UFW_BIN" >/dev/null
    fi
    command -v "$FAIL2BAN_BIN" >/dev/null
}

check_verify_dependencies() {
    [[ -x "$SSHD_BIN" ]] || error_exit "sshd не найден"
    command -v "$SS_BIN" >/dev/null 2>&1 || error_exit "ss не найден"
    if [[ "$ENABLE_UFW" == true ]]; then
        command -v "$UFW_BIN" >/dev/null 2>&1 || error_exit "ufw не найден"
    fi
}

acquire_lock() { mkdir -p "$(dirname "$LOCK_FILE")"; exec 9>"$LOCK_FILE"; flock -n 9 || error_exit "Другой экземпляр настройки SSH уже выполняется"; }

prompt_missing_inputs() {
    if [[ -z "$USERNAME" ]]; then read -r -p "Имя административного пользователя: " USERNAME; validate_username "$USERNAME" || error_exit "Некорректное имя пользователя"; fi
    if [[ -z "$SSHD_PORT" ]]; then read -r -p "Новый SSH-порт (1-65535): " SSHD_PORT; validate_port "$SSHD_PORT" || error_exit "Некорректный SSH-порт"; fi
}

ensure_user() { getent passwd "$USERNAME" >/dev/null || adduser --disabled-password --gecos '' "$USERNAME"; usermod -aG sudo "$USERNAME"; }

ensure_non_root_target() {
    local record
    if record="$(getent passwd "$USERNAME")"; then
        target_passwd_record_is_non_root "$record" || error_exit "Пользователь $USERNAME имеет UID 0 и не может быть target SSH hardening"
    fi
}

resolve_user_home_and_group() {
    local record; record="$(getent passwd "$USERNAME")" || error_exit "Пользователь $USERNAME не найден через NSS"
    IFS=: read -r _ _ _ _ _ USER_HOME _ <<<"$record"; USER_GROUP="$(id -gn "$USERNAME")"
    [[ -n "$USER_HOME" && "$USER_HOME" == /* && -n "$USER_GROUP" ]] || error_exit "Некорректные NSS-данные пользователя $USERNAME"
}

configure_sudo() {
    local target="/etc/sudoers.d/90-ubuntu-vps-$USERNAME" temporary
    temporary="$(mktemp /etc/sudoers.d/.ubuntu-vps.XXXXXX)"; TEMP_FILES+=("$temporary")
    printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$USERNAME" > "$temporary"
    chmod 0440 "$temporary"; chown root:root "$temporary"; "$VISUDO_BIN" -cf "$temporary" >/dev/null; mv -f "$temporary" "$target"
}

current_connection_port() {
    local local_port
    if local_port="$(ssh_connection_local_port "${SSH_CONNECTION:-}")"; then printf '%s\n' "$local_port"; return 0; fi
    "$SSHD_BIN" -T -f "$SSHD_CONFIG" | awk 'tolower($1)=="port" {print $2; exit}'
}

sshd_effective() {
    local user="$1" port="$2" remote_addr="127.0.0.1" local_addr="127.0.0.1" _
    if [[ -n "${SSH_CONNECTION:-}" ]]; then IFS=' ' read -r remote_addr _ local_addr _ <<<"$SSH_CONNECTION"; fi
    "$SSHD_BIN" -T -f "$SSHD_CONFIG" -C "user=$user,host=localhost,addr=$remote_addr,laddr=$local_addr,lport=$port"
}

preflight_ssh() {
    local port_records effective formatted_records
    "$SSHD_BIN" -t -f "$SSHD_CONFIG"; OLD_PORT="$(current_connection_port)"
    validate_port "$OLD_PORT" || error_exit "Не удалось определить текущий SSH-порт"
    port_is_listening "$OLD_PORT" || error_exit "Текущий SSH-порт $OLD_PORT не слушается"
    port_records="$(find_unmanaged_port_directives "$SSHD_CONFIG" "$SSH_CONFIG_DIR" "$MANAGED_CONFIG")"
    if ! unmanaged_port_records_are_adoptable "$OLD_PORT" "$port_records"; then
        formatted_records="$(format_unmanaged_port_records "$port_records")"
        error_exit "Обнаружены неоднозначные unmanaged Port directives; автоматическая миграция остановлена:"$'\n'"$formatted_records"
    fi
    ADOPTED_PORT_RECORDS=()
    if [[ -n "$port_records" ]]; then
        mapfile -t ADOPTED_PORT_RECORDS <<< "$port_records"
        log INFO "Найдены явные директивы текущего Port $OLD_PORT; они останутся активны до проверки нового SSH-входа"
    fi
    effective="$(sshd_effective "$USERNAME" "$OLD_PORT")"; authorized_keys_path_supported "$effective" || error_exit "Effective AuthorizedKeysFile не включает .ssh/authorized_keys"
    if [[ "$SSHD_PORT" != "$OLD_PORT" ]] && port_is_listening "$SSHD_PORT"; then error_exit "Порт $SSHD_PORT уже занят"; fi
}

prepare_user_key() {
    local key_source ssh_dir destination pasted
    key_source="$(require_public_key_source "$PUBLIC_KEY_FILE" "$ROOT_AUTHORIZED_KEYS")" || {
        if [[ -t 0 ]]; then
            pasted="$(mktemp)"; TEMP_FILES+=("$pasted"); printf 'Root key отсутствует. Вставьте одну строку публичного ключа: '; IFS= read -r REPLY; printf '%s\n' "$REPLY" > "$pasted"; key_source="$pasted"
        else error_exit "Нет root authorized_keys и не передан --public-key-file; SSH не изменён"; fi
    }
    public_key_file_is_safe "$key_source" || error_exit "Источник ключа не является валидным публичным ключом/authorized_keys"
    ssh_dir="$USER_HOME/.ssh"; destination="$ssh_dir/authorized_keys"
    install -d -m 0700 -o "$USERNAME" -g "$USER_GROUP" "$ssh_dir"; touch "$destination"; chown "$USERNAME:$USER_GROUP" "$destination"; chmod 0600 "$destination"; chmod go-w "$USER_HOME"
    merge_authorized_keys "$destination" "$key_source" || error_exit "Не удалось объединить authorized_keys"
    chown "$USERNAME:$USER_GROUP" "$destination"; chmod 0600 "$destination"; log INFO "Ключи пользователя подготовлены; root authorized_keys не изменялся"
}

begin_transaction() {
    TRANSACTION_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"; TRANSACTION_DIR="$STATE_ROOT/$TRANSACTION_ID"
    mkdir -p "$TRANSACTION_DIR" "$BACKUP_ROOT"; chmod 0711 "$STATE_ROOT" "$TRANSACTION_DIR"
    cp -a /etc/ssh "$BACKUP_ROOT/ssh-$TRANSACTION_ID"; backup_managed_config; backup_adopted_port_configs; backup_fail2ban_config
    printf 'old_port=%s\nnew_port=%s\nuser=%s\n' "$OLD_PORT" "$SSHD_PORT" "$USERNAME" > "$TRANSACTION_DIR/metadata"; chmod 0600 "$TRANSACTION_DIR/metadata"
    TRANSACTION_ACTIVE=true
}

write_managed_config() {
    local temporary; mkdir -p "$SSH_CONFIG_DIR"; temporary="$(mktemp "$SSH_CONFIG_DIR/.00-vps-hardening.conf.XXXXXX")"; TEMP_FILES+=("$temporary")
    printf '%s\n' "$1" > "$temporary"; chmod 0600 "$temporary"; chown root:root "$temporary"; mv -f "$temporary" "$MANAGED_CONFIG"
}

assert_stage_effective() {
    local effective; effective="$(sshd_effective "$USERNAME" "$SSHD_PORT")"
    assert_effective_value "$effective" port "$SSHD_PORT" && assert_effective_value "$effective" pubkeyauthentication yes && assert_effective_value "$effective" passwordauthentication no && assert_effective_value "$effective" kbdinteractiveauthentication no && assert_effective_value "$effective" authenticationmethods publickey && authorized_keys_path_supported "$effective"
}

assert_final_effective() {
    local target root ports; target="$(sshd_effective "$USERNAME" "$SSHD_PORT")"; root="$(sshd_effective root "$SSHD_PORT")"
    assert_effective_value "$target" port "$SSHD_PORT" && assert_effective_value "$target" pubkeyauthentication yes && assert_effective_value "$target" passwordauthentication no && assert_effective_value "$target" kbdinteractiveauthentication no && assert_effective_value "$target" authenticationmethods publickey && assert_effective_value "$root" permitrootlogin no && authorized_keys_path_supported "$target" || return 1
    ports="$($SSHD_BIN -T -f "$SSHD_CONFIG" | awk 'tolower($1)=="port" {print $2}')"; [[ "$ports" == "$SSHD_PORT" ]]
}

maybe_failpoint() { [[ "${VPS_FAILPOINT:-}" != "$1" ]] || die "Injected failpoint: $1"; }

rollback_transaction() {
    local status=0 ssh_recovery_ready=false ssh_config_restored=true
    [[ "$TRANSACTION_ACTIVE" == true ]] || return 0; [[ "$ROLLBACK_RUNNING" == false ]] || return 1
    ROLLBACK_RUNNING=true; set +e; log WARN "Откат SSH-транзакции $TRANSACTION_ID"
    if ! restore_adopted_port_configs; then
        status=1
        ssh_config_restored=false
        log ERROR "Не удалось восстановить исходные Port directives; runtime и UFW оставлены без изменений"
    fi
    if ! restore_managed_config; then
        status=1
        ssh_config_restored=false
        log ERROR "Не удалось восстановить managed SSH config; runtime и UFW оставлены без изменений"
    fi
    if [[ "$ssh_config_restored" != true ]]; then
        :
    elif ! "$SSHD_BIN" -t -f "$SSHD_CONFIG"; then
        status=1
        log ERROR "Восстановленная SSH-конфигурация невалидна; действующий runtime и recovery UFW rules не изменены"
    elif apply_ssh_runtime && port_is_listening "$OLD_PORT"; then
        ssh_recovery_ready=true
    else
        status=1
        log ERROR "Старый SSH listener $OLD_PORT не подтверждён; recovery UFW rules оставлены открытыми"
    fi
    if [[ "$ssh_recovery_ready" == true && "$ENABLE_UFW" == true ]] && command -v "$UFW_BIN" >/dev/null 2>&1; then
        rollback_ufw "$OLD_PORT" "$SSHD_PORT" || status=1
    fi
    restore_fail2ban_config || status=1
    "$FAIL2BAN_BIN" -t || status=1
    "$SYSTEMCTL_BIN" restart fail2ban.service || status=1
    if [[ "$status" -eq 0 ]]; then log WARN "Откат завершён; старый listener $OLD_PORT подтверждён"; else log ERROR "Откат неполный; не закрывайте текущую SSH-сессию. Backup: $BACKUP_ROOT/ssh-$TRANSACTION_ID"; fi
    TRANSACTION_ACTIVE=false; ROLLBACK_RUNNING=false; set -e; return "$status"
}

on_error() { local status="$1" line="$2"; trap - ERR; log ERROR "Ошибка на строке $line, status=$status"; rollback_transaction || true; exit "$status"; }

create_and_wait_for_verification() {
    local verifier="$TRANSACTION_DIR/verify-new-ssh" marker="$TRANSACTION_DIR/verified" deadline
    create_session_verifier "$verifier" "$TRANSACTION_ID" "$USERNAME" "$SSHD_PORT" "$marker"; chown root:root "$verifier"; deadline=$((SECONDS + VERIFICATION_TIMEOUT))
    cat <<EOF

PREPARED: старый SSH-путь остаётся активным.
В другом терминале выполните key-only вход:
  ssh -o IdentitiesOnly=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -i PRIVATE_KEY -p $SSHD_PORT $USERNAME@SERVER
Затем в новой SSH-сессии:
  sudo --preserve-env=SSH_CONNECTION $verifier $TRANSACTION_ID
Ожидание: $VERIFICATION_TIMEOUT секунд.
EOF
    while ((SECONDS < deadline)); do
        if [[ -s "$marker" && "$(cat "$marker")" == "$USERNAME:$SSHD_PORT" ]]; then log INFO "Реальный второй SSH-сеанс и sudo подтверждены"; return 0; fi
        sleep 2
    done
    die "Новый SSH-сеанс не подтверждён за $VERIFICATION_TIMEOUT секунд"
}

configure_fail2ban() {
    local temporary; mkdir -p "$(dirname "$FAIL2BAN_CONFIG")"; temporary="$(mktemp "$(dirname "$FAIL2BAN_CONFIG")/.ubuntu-vps.XXXXXX")"; TEMP_FILES+=("$temporary")
    cat > "$temporary" <<EOF
[sshd]
enabled = true
port = $SSHD_PORT
backend = systemd
maxretry = 3
findtime = 600
bantime = 600
EOF
    chmod 0644 "$temporary"; chown root:root "$temporary"; mv -f "$temporary" "$FAIL2BAN_CONFIG"; "$FAIL2BAN_BIN" -t; "$SYSTEMCTL_BIN" restart fail2ban.service
}

verify_only() {
    local effective root_effective
    [[ -n "$USERNAME" && -n "$SSHD_PORT" ]] || error_exit "--verify-only требует --user и --port"
    "$SSHD_BIN" -t -f "$SSHD_CONFIG"; effective="$(sshd_effective "$USERNAME" "$SSHD_PORT")"; root_effective="$(sshd_effective root "$SSHD_PORT")"
    assert_effective_value "$effective" port "$SSHD_PORT" || error_exit "Effective port отличается"
    assert_effective_value "$effective" passwordauthentication no || error_exit "PasswordAuthentication не отключён"
    assert_effective_value "$effective" pubkeyauthentication yes || error_exit "PubkeyAuthentication не включён"
    assert_effective_value "$effective" kbdinteractiveauthentication no || error_exit "KbdInteractiveAuthentication не отключён"
    assert_effective_value "$effective" authenticationmethods publickey || error_exit "AuthenticationMethods не требует publickey"
    assert_effective_value "$root_effective" permitrootlogin no || error_exit "PermitRootLogin не отключён"
    authorized_keys_path_supported "$effective" || error_exit "Effective AuthorizedKeysFile не включает .ssh/authorized_keys"
    port_is_listening "$SSHD_PORT" || error_exit "Порт $SSHD_PORT не слушается"
    if [[ "$ENABLE_UFW" == true ]]; then
        ufw_is_active || error_exit "UFW не активен"
        ufw_rule_exists "$SSHD_PORT" || error_exit "UFW не разрешает $SSHD_PORT/tcp"
    fi
    printf '%s\n' "$effective"; "$SS_BIN" -lntp
    if command -v "$UFW_BIN" >/dev/null 2>&1; then LC_ALL=C "$UFW_BIN" status verbose; LC_ALL=C "$UFW_BIN" show added; fi
}

cleanup() { if ((${#TEMP_FILES[@]} > 0)); then rm -f "${TEMP_FILES[@]}"; fi; }

main() {
    local parse_status=0 stage_config final_config
    parse_args "$@" || parse_status=$?; [[ "$parse_status" -ne 2 ]] || return 0; [[ "$parse_status" -eq 0 ]] || return "$parse_status"
    require_root; mkdir -p "$(dirname "$LOG_FILE")"; touch "$LOG_FILE"; chmod 0600 "$LOG_FILE"; check_os; acquire_lock
    if [[ "$VERIFY_ONLY" == true ]]; then check_verify_dependencies; verify_only; return 0; fi
    install_dependencies
    prompt_missing_inputs; ensure_non_root_target; ensure_user; resolve_user_home_and_group; configure_sudo; preflight_ssh; prepare_user_key; begin_transaction
    trap 'on_error $? $LINENO' ERR
    stage_config="$(render_stage_config "$OLD_PORT" "$SSHD_PORT" "$USERNAME")"; write_managed_config "$stage_config"; "$SSHD_BIN" -t -f "$SSHD_CONFIG"; assert_stage_effective; maybe_failpoint after_stage_validation
    apply_ssh_runtime; port_is_listening "$OLD_PORT"; port_is_listening "$SSHD_PORT"; maybe_failpoint after_stage_activation
    if [[ "$ENABLE_UFW" == true ]]; then stage_ufw "$OLD_PORT" "$SSHD_PORT"; fi
    maybe_failpoint after_ufw; create_and_wait_for_verification; maybe_failpoint after_verification
    neutralize_adopted_port_configs "$OLD_PORT"; final_config="$(render_final_config "$SSHD_PORT")"; write_managed_config "$final_config"; "$SSHD_BIN" -t -f "$SSHD_CONFIG"; assert_final_effective; maybe_failpoint before_final_activation
    apply_ssh_runtime; port_is_listening "$SSHD_PORT"
    if [[ "$OLD_PORT" != "$SSHD_PORT" ]] && port_is_listening "$OLD_PORT"; then die "Старый SSH listener $OLD_PORT всё ещё активен"; fi
    configure_fail2ban
    if [[ "$ENABLE_UFW" == true ]]; then finalize_ufw "$OLD_PORT" "$SSHD_PORT"; fi
    TRANSACTION_ACTIVE=false; trap - ERR; touch "$TRANSACTION_DIR/committed"; chmod 0600 "$TRANSACTION_DIR/committed"
    log INFO "SSH migration committed: user=$USERNAME port=$SSHD_PORT"; verify_only
}

if [[ "${VPS_SSH_SETUP_LIBRARY:-0}" != "1" ]]; then trap cleanup EXIT; main "$@"; fi
