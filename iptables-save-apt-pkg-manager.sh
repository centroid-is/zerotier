#!/bin/bash

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Trying to gain sudo privileges..."
    exec sudo "$0" "$@"
    exit
fi

# Install iptables-persistent
apt update
apt install -y iptables-persistent
if [ $? -eq 0 ]; then
    echo "iptables-persistent installed successfully."
else
    echo "Failed to install iptables-persistent."
    exit 1
fi

# Save iptables rules to /etc/iptables/rules.v4
bash -c 'iptables-save > /etc/iptables/rules.v4'
if [ $? -eq 0 ]; then
    echo "iptables rules saved successfully."
else
    echo "Failed to save iptables rules."
    exit 1
fi

