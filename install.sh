#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: Alisson Chaves
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/alissonchaves/qm-iptag

function header_info {
clear
cat <<"EOF"
   ____    __  ___   ________      ______           
  / __ \  /  |/  /  /  _/ __ \    /_  __/___ _____ _
 / / / / / /|_/ /   / // /_/ /_____/ / / __ `/ __ `/
/ /_/ / / /  / /  _/ // ____/_____/ / / /_/ / /_/ / 
\___\_\/_/  /_/  /___/_/         /_/  \__,_/\__, /  
                                           /____/   
EOF
}

clear
header_info
APP="QM IP-Tag"
hostname=$(hostname)

# Farbvariablen
YW=$(echo "\033[33m")
GN=$(echo "\033[1;92m")
RD=$(echo "\033[01;31m")
CL=$(echo "\033[m")
BFR="\\r\\033[K"
HOLD=" "
CM=" ✔️ ${CL}"
CROSS=" ✖️ ${CL}"

# This function enables error handling in the script by setting options and defining a trap for the ERR signal.
catch_errors() {
  set -Eeuo pipefail
  trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
}

# This function is called when an error occurs. It receives the exit code, line number, and command that caused the error, and displays an error message.
error_handler() {
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID >/dev/null; then kill $SPINNER_PID >/dev/null; fi
  printf "\e[?25h"
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
}

# This function displays a spinner.
spinner() {
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local spin_i=0
  local interval=0.1
  printf "\e[?25l"

  local color="${YWB}"

  while true; do
  printf "\r ${color}%s${CL}" "${frames[spin_i]}"
  spin_i=$(((spin_i + 1) % ${#frames[@]}))
  sleep "$interval"
  done
}

# This function displays an informational message with a yellow color.
msg_info() {
  local msg="$1"
  echo -ne "${TAB}${YW}${HOLD}${msg}${HOLD}"
  spinner &
  SPINNER_PID=$!
}

# This function displays a success message with a green color.
msg_ok() {
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID >/dev/null; then kill $SPINNER_PID >/dev/null; fi
  printf "\e[?25h"
  local msg="$1"
  echo -e "${BFR}${CM}${GN}${msg}${CL}"
}

# This function displays a error message with a red color.
msg_error() {
  if [ -n "$SPINNER_PID" ] && ps -p $SPINNER_PID >/dev/null; then kill $SPINNER_PID >/dev/null; fi
  printf "\e[?25h"
  local msg="$1"
  echo -e "${BFR}${CROSS}${RD}${msg}${CL}"
}

while true; do
  read -p "This will install ${APP} on ${hostname}. Proceed? (y/n): " yn
  case $yn in
  [Yy]*) break ;;
  [Nn]*)
  msg_error "Installation cancelled."
  exit
  ;;
  *) msg_error "Please answer yes or no." ;;
  esac
done

if ! pveversion | grep -Eq "pve-manager/8.[0-3]"; then
  msg_error "This version of Proxmox Virtual Environment is not supported"
  msg_error "⚠️ Requires Proxmox Virtual Environment Version 8.0 or later."
  msg_error "Exiting..."
  sleep 2
  exit
fi

FILE_PATH="/usr/local/bin/qm-iptag"
if [[ -f "$FILE_PATH" ]]; then
  msg_info "The file already exists: '$FILE_PATH'. Skipping installation."
  exit 0
fi

msg_info "Installing Dependencies"
apt-get update &>/dev/null
apt-get install -y ipcalc net-tools &>/dev/null
msg_ok "Installed Dependencies"

msg_info "Setting up IP-Tag Scripts"
mkdir -p /opt/qm-iptag
msg_ok "Setup IP-Tag Scripts"

msg_info "Setup Default Config"
if [[ ! -f /opt/qm-iptag/qm-iptag.conf ]]; then
  cat <<EOF >/opt/qm-iptag/qm-iptag.conf
# Configuration file for QM IP tagging

# List of allowed CIDRs
CIDR_LIST=(
  192.168.0.0/16
  172.16.0.0/12
  10.0.0.0/8
  100.64.0.0/10
)

# Interval settings (in seconds)
LOOP_INTERVAL=60
FW_NET_INTERFACE_CHECK_INTERVAL=60
QM_STATUS_CHECK_INTERVAL=-1
FORCE_UPDATE_INTERVAL=1800
EOF
  msg_ok "Setup default config"
else
  msg_ok "Default config already exists"
fi

msg_info "Setup Main Function"
if [[ ! -f /opt/qm-iptag/qm-iptag ]]; then
  cat <<'EOF' >/opt/qm-iptag/qm-iptag
#!/bin/bash

# =============== CONFIGURATION =============== #

CONFIG_FILE="/opt/qm-iptag/qm-iptag.conf"

# Load the configuration file if it exists
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=./qm-iptag.conf
  source "$CONFIG_FILE"
fi

# Convert IP to integer for comparison
ip_to_int() {
  local ip="${1}"
  local a b c d

  IFS=. read -r a b c d <<< "${ip}"
  echo "$((a << 24 | b << 16 | c << 8 | d))"
}

# Check if IP is in CIDR
ip_in_cidr() {
  local ip="${1}"
  local cidr="${2}"

  # Separate base IP and CIDR prefix
  local base_ip=$(echo "${cidr}" | cut -d/ -f1)
  local prefix=$(echo "${cidr}" | cut -d/ -f2)

  # Calculate the network mask
  local netmask=$(( 0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF ))

  # Convert IP and base IP to integers
  local ip_int=$(ip_to_int "${ip}")
  local base_ip_int=$(ip_to_int "${base_ip}")

  # Check if the IP belongs to the subnet
  [[ $((ip_int & netmask)) -eq $((base_ip_int & netmask)) ]] && return 0 || return 1
}

# Check if IP is in any CIDRs
ip_in_cidrs() {
  local ip="${1}"
  local cidrs=()

  mapfile -t cidrs < <(echo "${2}" | tr ' ' '\n')
  for cidr in "${cidrs[@]}"; do
  ip_in_cidr "${ip}" "${cidr}" && return 0
  done

  return 1
}

# Check if IP is valid
is_valid_ipv4() {
  local ip=$1
  local regex="^([0-9]{1,3}\.){3}[0-9]{1,3}$"

  if [[ $ip =~ $regex ]]; then
    IFS='.' read -r -a parts <<< "$ip"
    for part in "${parts[@]}"; do
      if ! [[ $part =~ ^[0-9]+$ ]] || ((part < 0 || part > 255)); then
        return 1
      fi
    done
    return 0
  else
    return 1
  fi
}

qm_status_changed() {
  current_qm_status=$(qm list 2>/dev/null)
  if [ "${last_qm_status}" == "${current_qm_status}" ]; then
    return 1
  else
    last_qm_status="${current_qm_status}"
    return 0
  fi
}

fw_net_interface_changed() {
  current_net_interface=$(ifconfig | grep "^fw")
  if [ "${last_net_interface}" == "${current_net_interface}" ]; then
    return 1
  else
    last_net_interface="${current_net_interface}"
    return 0
  fi
}

# =============== MAIN =============== #

update_qm_iptags() {
  vmid_list=$(qm list 2>/dev/null | grep -v VMID | awk '{print $1}')
  for vmid in ${vmid_list}; do
    last_tagged_ips=()
    current_valid_ips=()
    next_tags=()

    # Parse current tags
    mapfile -t current_tags < <(qm config "${vmid}" | grep tags | awk '{print $2}' | sed 's/;/\n/g')
    for current_tag in "${current_tags[@]}"; do
      if is_valid_ipv4 "${current_tag}"; then
        last_tagged_ips+=("${current_tag}")
        continue
      fi
      next_tags+=("${current_tag}")
    done

    # Get current IPs
    current_ips_full=$(qm agent "${vmid}" network-get-interfaces | grep \"ip-address\" | cut -f4 -d"\"")
    for ip in ${current_ips_full}; do
        if is_valid_ipv4 "${ip}" && ip_in_cidrs "${ip}" "${CIDR_LIST[*]}"; then
            current_valid_ips+=("${ip}")
            next_tags+=("${ip}")
        fi
    done

    # Skip if no ip change
    if [[ "$(echo "${last_tagged_ips[@]}" | tr ' ' '\n' | sort -u)" == "$(echo "${current_valid_ips[@]}" | tr ' ' '\n' | sort -u)" ]]; then
      echo "Skipping ${vmid} cause ip no changes"
      continue
    fi

    # Set tags
    echo "Setting ${vmid} tags from ${current_tags[*]} to ${next_tags[*]}"
    qm set "${vmid}" -tags "$(IFS=';'; echo "${next_tags[*]}")"
  done
}

check() {
  current_time=$(date +%s)

  time_since_last_qm_status_check=$((current_time - last_qm_status_check_time))
  if [[ "${QM_STATUS_CHECK_INTERVAL}" -gt 0 ]] \
    && [[ "${time_since_last_qm_status_check}" -ge "${STATUS_CHECK_INTERVAL}" ]]; then
    echo "Checking qm status..."
    last_qm_status_check_time=${current_time}
    if qm_status_changed; then
      update_qm_iptags
      last_update_time=${current_time}
      return
    fi
  fi

  time_since_last_fw_net_interface_check=$((current_time - last_fw_net_interface_check_time))
  if [[ "${FW_NET_INTERFACE_CHECK_INTERVAL}" -gt 0 ]] \
    && [[ "${time_since_last_fw_net_interface_check}" -ge "${FW_NET_INTERFACE_CHECK_INTERVAL}" ]]; then
    echo "Checking fw net interface..."
    last_fw_net_interface_check_time=${current_time}
    if fw_net_interface_changed; then
      update_qm_iptags
      last_update_time=${current_time}
      return
    fi
  fi

  time_since_last_update=$((current_time - last_update_time))
  if [ ${time_since_last_update} -ge ${FORCE_UPDATE_INTERVAL} ]; then
    echo "Force updating qm iptags..."
    update_qm_iptags
    last_update_time=${current_time}
    return
  fi
}

# main: Set the IP tags for all QM containers
main() {
  while true; do
    check
    sleep "${LOOP_INTERVAL}"
  done
}

main
EOF
  msg_ok "Setup Main Function"
else
  msg_ok "Main Function already exists"
fi
chmod +x /opt/qm-iptag/qm-iptag

msg_info "Creating Service"
if [[ ! -f /lib/systemd/system/qm-iptag.service ]]; then
  cat <<EOF >/lib/systemd/system/qm-iptag.service
[Unit]
Description=QM IP-Tag service
After=network.target

[Service]
Type=simple
ExecStart=/opt/qm-iptag/qm-iptag
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  msg_ok "Created Service"
else
  msg_ok "Service already exists."
fi

msg_ok "Setup IP-Tag Scripts"

msg_info "Starting Service"
systemctl daemon-reload &>/dev/null
systemctl enable -q --now qm-iptag.service &>/dev/null
msg_ok "Started Service"
SPINNER_PID=""
echo -e "\n${APP} installation completed successfully! ${CL}\n"
