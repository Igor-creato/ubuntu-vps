#!/bin/bash

# Log file path
LOG_FILE="/var/log/server_setup.log"

# Function to log messages
# Parameters: $1 - message to log
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to handle errors and exit
# Parameters: $1 - error message
handle_error() {
    log_message "ERROR: $1"
    echo "ERROR: $1" >&2
    exit 1
}

# Function to check if the OS is Ubuntu 22 or higher
check_os_version() {
    if [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        if [ "$DISTRIB_ID" != "Ubuntu" ]; then
            handle_error "This script requires Ubuntu OS."
        fi
        VERSION=$(echo "$DISTRIB_RELEASE" | cut -d. -f1)
        if [ "$VERSION" -lt 22 ]; then
            handle_error "Ubuntu version must be 22 or higher."
        fi
        log_message "OS check passed: Ubuntu $DISTRIB_RELEASE"
    else
        handle_error "Unable to determine OS version."
    fi
}

# Function to check if script is run as root
check_root_user() {
    if [ "$(id -u)" -ne 0 ]; then
        handle_error "This script must be run as root."
    fi
    log_message "Root user check passed."
}

# Function to update the system
update_system() {
    apt update -y || handle_error "Failed to update package list."
    apt upgrade -y || handle_error "Failed to upgrade packages."
    log_message "System updated successfully."
}

# Function to install SSH server
install_ssh() {
    apt install openssh-server -y || handle_error "Failed to install OpenSSH server."
    systemctl enable ssh --now || handle_error "Failed to enable and start SSH service."
    log_message "SSH installed and enabled."
}

# Function to get list of sudo users
# Returns: list of users in sudo group
get_sudo_users() {
    getent group sudo | cut -d: -f4 | tr ',' '\n'
}

# Function to validate username
# Parameters: $1 - username
# Returns: 0 if valid, 1 if invalid
validate_username() {
    if [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to create new user with sudo privileges
# Parameters: $1 - username
create_new_user() {
    local username="$1"
    useradd -m -s /bin/bash "$username" || handle_error "Failed to create user $username."
    usermod -aG sudo "$username" || handle_error "Failed to add $username to sudo group."
    # Set up SSH directory for later use
    mkdir -p "/home/$username/.ssh" || handle_error "Failed to create .ssh directory for $username."
    chown -R "$username:$username" "/home/$username/.ssh" || handle_error "Failed to chown .ssh for $username."
    chmod 700 "/home/$username/.ssh" || handle_error "Failed to chmod .ssh for $username."
    log_message "New user $username created with sudo privileges."
}

# Function to handle user selection or creation
# Returns: selected or created username in SELECTED_USER
handle_user_selection() {
    local sudo_users=$(get_sudo_users)
    if [ -z "$sudo_users" ]; then
        echo "No sudo users found. You must create a new one."
        while true; do
            read -p "Enter new username: " new_username
            if validate_username "$new_username"; then
                if id "$new_username" &>/dev/null; then
                    echo "User $new_username already exists."
                else
                    create_new_user "$new_username"
                    SELECTED_USER="$new_username"
                    break
                fi
            else
                echo "Invalid username. Must start with lowercase letter or underscore, followed by lowercase letters, digits, underscores, or hyphens."
            fi
        done
    else
        echo "Existing sudo users:"
        local user_list=($sudo_users)
        for i in "${!user_list[@]}"; do
            echo "$((i+1)). ${user_list[$i]}"
        done
        echo "$(( ${#user_list[@]} + 1 )). Create new user"
        while true; do
            read -p "Select user by number: " choice
            if [ "$choice" -ge 1 ] && [ "$choice" -le "${#user_list[@]}" ]; then
                SELECTED_USER="${user_list[$((choice-1))]}"
                break
            elif [ "$choice" -eq "$(( ${#user_list[@]} + 1 ))" ]; then
                while true; do
                    read -p "Enter new username: " new_username
                    if validate_username "$new_username"; then
                        if id "$new_username" &>/dev/null; then
                            echo "User $new_username already exists."
                        else
                            create_new_user "$new_username"
                            SELECTED_USER="$new_username"
                            break
                        fi
                    else
                        echo "Invalid username. Must start with lowercase letter or underscore, followed by lowercase letters, digits, underscores, or hyphens."
                    fi
                done
                break
            else
                echo "Invalid choice."
            fi
        done
    fi
    log_message "Selected user: $SELECTED_USER"
}

# Function to add SSH key with multi-line support
# Parameters: $1 - username
add_ssh_key() {
    local username="$1"
    local auth_file="/home/$username/.ssh/authorized_keys"
    touch "$auth_file" || handle_error "Failed to create authorized_keys for $username."
    chown "$username:$username" "$auth_file" || handle_error "Failed to chown authorized_keys."
    chmod 600 "$auth_file" || handle_error "Failed to chmod authorized_keys."
    echo "Paste your SSH public key (multi-line supported, end with EOF on a new line):"
    while IFS= read -r line; do
        if [ "$line" = "EOF" ]; then
            break
        fi
        echo "$line" >> "$auth_file"
    done
    if [ ! -s "$auth_file" ]; then
        handle_error "No key added. Aborting."
    fi
    log_message "SSH key added for user $username."
}

# Function to transfer SSH key from root to user
# Parameters: $1 - username
transfer_ssh_key() {
    local username="$1"
    local root_auth="/root/.ssh/authorized_keys"
    local user_auth="/home/$username/.ssh/authorized_keys"
    if [ -f "$root_auth" ]; then
        cp "$root_auth" "$user_auth" || handle_error "Failed to copy authorized_keys to $username."
        chown "$username:$username" "$user_auth" || handle_error "Failed to chown authorized_keys for $username."
        chmod 600 "$user_auth" || handle_error "Failed to chmod authorized_keys for $username."
        rm "$root_auth" || handle_error "Failed to remove root's authorized_keys."
        log_message "SSH key transferred from root to $username and removed from root."
        return 0
    else
        return 1
    fi
}

# Function to handle SSH key setup for selected user
# Parameters: $1 - username
handle_ssh_keys() {
    local username="$1"
    local root_has_key=0
    if [ -f "/root/.ssh/authorized_keys" ] && [ -s "/root/.ssh/authorized_keys" ]; then
        root_has_key=1
    fi

    if [ $root_has_key -eq 1 ]; then
        echo "Root has SSH keys. Choose action:"
        echo "1. Transfer key from root to $username (and remove from root)"
        echo "2. Add your own key (and remove from root if exists)"
        while true; do
            read -p "Select option (1/2): " key_choice
            if [ "$key_choice" = "1" ]; then
                transfer_ssh_key "$username"
                # Even after transfer, remove root key if still there (though transfer removes it)
                rm -f "/root/.ssh/authorized_keys"
                break
            elif [ "$key_choice" = "2" ]; then
                add_ssh_key "$username"
                rm -f "/root/.ssh/authorized_keys" || log_message "No root key to remove."
                break
            else
                echo "Invalid choice."
            fi
        done
    else
        echo "No SSH key found for root. Add your own key."
        add_ssh_key "$username"
    fi
}

# Function to validate port number
# Parameters: $1 - port
# Returns: 0 if valid, 1 if invalid
validate_port() {
    if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

# Function to change SSH port
# Returns: new port in NEW_PORT
change_ssh_port() {
    while true; do
        read -p "Enter new SSH port (default 22, enter to skip): " new_port
        if [ -z "$new_port" ]; then
            NEW_PORT=22
            log_message "SSH port remains 22."
            break
        elif validate_port "$new_port"; then
            sed -i "s/#Port 22/Port $new_port/g" /etc/ssh/sshd_config || handle_error "Failed to update SSH config."
            sed -i "s/Port 22/Port $new_port/g" /etc/ssh/sshd_config || handle_error "Failed to update SSH config."
            systemctl restart ssh || handle_error "Failed to restart SSH."
            NEW_PORT="$new_port"
            log_message "SSH port changed to $NEW_PORT."
            break
        else
            echo "Invalid port. Must be a number between 1 and 65535."
        fi
    done
}

# Function to install and configure fail2ban for SSH port
# Parameters: $1 - port
install_fail2ban() {
    local port="$1"
    apt install fail2ban -y || handle_error "Failed to install fail2ban."
    cat <<EOF > /etc/fail2ban/jail.local || handle_error "Failed to create fail2ban config."
[sshd]
enabled = true
port = $port
logpath = /var/log/auth.log
maxretry = 5
EOF
    systemctl restart fail2ban || handle_error "Failed to restart fail2ban."
    log_message "fail2ban installed and configured for port $port."
}

# Function to install and configure UFW
# Parameters: $1 - new_port
configure_ufw() {
    local new_port="$1"
    apt install ufw -y || handle_error "Failed to install UFW."
    ufw allow 22/tcp || handle_error "Failed to allow port 22 in UFW."
    ufw allow 80/tcp || handle_error "Failed to allow port 80 in UFW."
    ufw allow 443/tcp || handle_error "Failed to allow port 443 in UFW."
    ufw allow "$new_port"/tcp || handle_error "Failed to allow port $new_port in UFW."
    ufw --force enable || handle_error "Failed to enable UFW."
    log_message "UFW configured with ports 22, 80, 443, $new_port open."

    echo "Please check in a new terminal if SSH works on port $new_port."
    while true; do
        read -p "Does SSH work on the new port? (y/n): " answer
        if [ "$answer" = "y" ]; then
            ufw deny 22/tcp || handle_error "Failed to deny port 22 in UFW."
            sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config || handle_error "Failed to disable password auth."
            sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config || handle_error "Failed to disable password auth."
            systemctl restart ssh || handle_error "Failed to restart SSH after config change."
            log_message "Port 22 closed, password authentication disabled."
            break
        elif [ "$answer" = "n" ]; then
            handle_error "SSH check failed. Exiting."
        else
            echo "Invalid response. Enter y or n."
        fi
    done
}

# Function to get server IP
get_server_ip() {
    ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1
}

# Main execution
main() {
    touch "$LOG_FILE" || handle_error "Failed to create log file."
    check_os_version
    check_root_user
    update_system
    install_ssh
    handle_user_selection
    handle_ssh_keys "$SELECTED_USER"
    change_ssh_port
    install_fail2ban "$NEW_PORT"
    configure_ufw "$NEW_PORT"
    
    # Get IP
    local server_ip=$(get_server_ip)
    if [ -z "$server_ip" ]; then
        server_ip="unable to detect, check manually"
    fi
    
    echo "Setup completed successfully."
    echo "User: $SELECTED_USER"
    echo "IP: $server_ip"
    echo "Port: $NEW_PORT"
    echo "You can now login using SSH key."
    
    log_message "Setup completed successfully for user $SELECTED_USER on port $NEW_PORT."
    
    # Clean up temporary files if any (none created, but placeholder)
    rm -f /tmp/setup_temp_* 2>/dev/null
}

main
