#!/bin/bash

# Check if the script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Trying to gain sudo privileges..."
    exec sudo "$0" "$@"
    exit
fi

# Function to list available Ethernet interfaces
list_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -E '^eth|^en|^zt'
}

# Function to calculate the subnet
calculate_subnet() {
    local ip=$1
    local prefix=$2

    # Convert IP to integer
    IFS=. read -r i1 i2 i3 i4 <<< "$ip"
    ip_int=$((i1 * 256 ** 3 + i2 * 256 ** 2 + i3 * 256 + i4))

    # Calculate netmask from prefix
    netmask_int=$((0xFFFFFFFF << (32 - prefix) & 0xFFFFFFFF))

    # Calculate network address
    network_int=$((ip_int & netmask_int))

    # Convert integer back to IP
    network_ip=$(printf "%d.%d.%d.%d" $((network_int >> 24 & 0xFF)) $((network_int >> 16 & 0xFF)) $((network_int >> 8 & 0xFF)) $((network_int & 0xFF)))

    echo "$network_ip/$prefix"
}

# Allow ip forward
sysctl -w net.ipv4.ip_forward=1

# List available interfaces and assign indices
interfaces=($(list_interfaces))
echo "Available Ethernet interfaces:"
for i in "${!interfaces[@]}"; do
    echo "[$i] ${interfaces[$i]}"
done

# Prompt user to pick ZT_IFACE by index
while true; do
    echo "Please pick an interface for Zerotier (ZT_IFACE) by number from the list above:"
    read -p "ZT_IFACE index: " ZT_IFACE_INDEX
    if [[ "$ZT_IFACE_INDEX" =~ ^[0-9]+$ ]] && [ "$ZT_IFACE_INDEX" -ge 0 ] && [ "$ZT_IFACE_INDEX" -lt "${#interfaces[@]}" ]; then
        ZT_IFACE=${interfaces[$ZT_IFACE_INDEX]}
        break
    else
        echo "Invalid index. Please try again."
    fi
done

# Check if eth0 is available for default PHY_IFACE
default_phy_iface=""
for i in "${!interfaces[@]}"; do
    if [ "${interfaces[$i]}" == "eth0" ]; then
        default_phy_iface="eth0"
        break
    fi
done

# Prompt user to pick PHY_IFACE by index with default if available
while true; do
    echo "Please pick a physical interface for PHY_IFACE by number from the list above (default: $default_phy_iface):"
    read -p "PHY_IFACE index (press Enter to use default): " PHY_IFACE_INDEX
    if [ -z "$PHY_IFACE_INDEX" ]; then
        PHY_IFACE=$default_phy_iface
        break
    elif [[ "$PHY_IFACE_INDEX" =~ ^[0-9]+$ ]] && [ "$PHY_IFACE_INDEX" -ge 0 ] && [ "$PHY_IFACE_INDEX" -lt "${#interfaces[@]}" ]; then
        PHY_IFACE=${interfaces[$PHY_IFACE_INDEX]}
        break
    else
        echo "Invalid index. Please try again."
    fi
done

# Ensure ZT_IFACE and PHY_IFACE are set
if [ -z "$ZT_IFACE" ] || [ -z "$PHY_IFACE" ]; then
    echo "Both ZT_IFACE and PHY_IFACE must be set. Exiting."
    exit 1
fi

# Print chosen interfaces
echo "Using ZT_IFACE: $ZT_IFACE"
echo "Using PHY_IFACE: $PHY_IFACE"

# Set up iptables rules
iptables -A FORWARD -i $ZT_IFACE -o $PHY_IFACE -j ACCEPT
iptables -A FORWARD -i $PHY_IFACE -o $ZT_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -A POSTROUTING -o $PHY_IFACE -j MASQUERADE

echo "iptables rules set successfully."

# Get and print the IP address of ZT_IFACE
ZT_IP=$(ip -o -4 addr show $ZT_IFACE | awk '{print $4}' | cut -d/ -f1)
echo "IP address of $ZT_IFACE: $ZT_IP"

# Get the IP address and netmask of PHY_IFACE
PHY_IP_INFO=$(ip -o -4 addr show $PHY_IFACE | awk '{print $4}')
PHY_IP=$(echo $PHY_IP_INFO | cut -d/ -f1)
PREFIX_LEN=$(echo $PHY_IP_INFO | cut -d/ -f2)
echo "IP address of $PHY_IFACE: $PHY_IP"

# Calculate the subnet of PHY_IFACE
PHY_SUBNET=$(calculate_subnet $PHY_IP $PREFIX_LEN)
echo "Subnet of $PHY_IFACE: $PHY_SUBNET"


GREEN='\033[0;32m'
NC='\033[0m' # No Color
echo -e "${GREEN}Now go to Zerotier web UI and make a route"
echo -e "$PHY_SUBNET via $ZT_IP ${NC}"
