#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 <zt-interface> <src-subnet> <dst-subnet> [lan-if]
Example:
  $0 ztm5tynveb 10.100.20.0/24 10.51.40.0/24
  # with force-return SNAT (avoid router static route):
  $0 ztm5tynveb 10.100.20.0/24 10.51.40.0/24 ens192
USAGE
  exit 1
}

[[ $# -ge 3 ]] || usage
ZT_IF="$1"
SRC_SUBNET="$2"
DST_SUBNET="$3"
LAN_IF="${4:-}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need nft; need systemctl; need awk; need grep; need ip

cidr_ok() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; }
cidr_ok "$SRC_SUBNET" || { echo "Invalid src subnet: $SRC_SUBNET"; exit 1; }
cidr_ok "$DST_SUBNET" || { echo "Invalid dst subnet: $DST_SUBNET"; exit 1; }

get_plen() { echo "$1" | awk -F/ '{print $2}'; }
SRC_PLEN="$(get_plen "$SRC_SUBNET")"
DST_PLEN="$(get_plen "$DST_SUBNET")"
[[ "$SRC_PLEN" = "$DST_PLEN" ]] || { echo "Prefix lengths must match (/$SRC_PLEN vs /$DST_PLEN)"; exit 1; }

[[ -r /proc/sys/net/ipv4/ip_forward ]] && [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]] && \
  echo "Note: IPv4 forwarding is disabled. Consider: sudo sysctl -w net.ipv4.ip_forward=1"
sysctl -q net.ipv4.conf.all.rp_filter >/dev/null 2>&1 && \
  echo "Note: consider: sudo sysctl -w net.ipv4.conf.all.rp_filter=0"

# Ensure table and dedicated chains exist (use numeric priorities for max compatibility)
nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
PR_CHAIN="prefixnat_prerouting"
PO_CHAIN="prefixnat_postrouting"
OU_CHAIN="prefixnat_output"

nft list chain ip nat "$PR_CHAIN" >/dev/null 2>&1 || \
  nft add chain ip nat "$PR_CHAIN" '{ type nat hook prerouting priority -100; policy accept; }'
nft list chain ip nat "$PO_CHAIN" >/dev/null 2>&1 || \
  nft add chain ip nat "$PO_CHAIN" '{ type nat hook postrouting priority 100; policy accept; }'
nft list chain ip nat "$OU_CHAIN" >/dev/null 2>&1 || \
  nft add chain ip nat "$OU_CHAIN" '{ type nat hook output priority -100; policy accept; }'

SNAT_COMMENT="prefix-nat $SRC_SUBNET->$DST_SUBNET via $ZT_IF"
DNAT_COMMENT="prefix-nat $DST_SUBNET->$SRC_SUBNET via $ZT_IF"
LOCL_COMMENT="prefix-nat (local) $DST_SUBNET->$SRC_SUBNET"

# POSTROUTING SNAT: inside -> virtual
if ! nft list chain ip nat "$PO_CHAIN" | grep -Fq -- "$SNAT_COMMENT"; then
  nft -f - <<EOF
add rule ip nat $PO_CHAIN \
  oifname "$ZT_IF" ip saddr $SRC_SUBNET \
  snat ip prefix to ip saddr map { $SRC_SUBNET : $DST_SUBNET } \
  comment "$SNAT_COMMENT"
EOF
fi

# PREROUTING DNAT: virtual -> inside
if ! nft list chain ip nat "$PR_CHAIN" | grep -Fq -- "$DNAT_COMMENT"; then
  nft -f - <<EOF
add rule ip nat $PR_CHAIN \
  iifname "$ZT_IF" ip daddr $DST_SUBNET \
  dnat ip prefix to ip daddr map { $DST_SUBNET : $SRC_SUBNET } \
  comment "$DNAT_COMMENT"
EOF
fi

# OUTPUT DNAT: NAT host can reach the virtual subnet
if ! nft list chain ip nat "$OU_CHAIN" | grep -Fq -- "$LOCL_COMMENT"; then
  nft -f - <<EOF
add rule ip nat $OU_CHAIN \
  ip daddr $DST_SUBNET \
  dnat ip prefix to ip daddr map { $DST_SUBNET : $SRC_SUBNET } \
  comment "$LOCL_COMMENT"
EOF
fi

# Optional: force-return SNAT on LAN egress
if [[ -n "$LAN_IF" ]]; then
  LAN_IP="$(ip -4 -o addr show dev "$LAN_IF" | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  [[ -n "$LAN_IP" ]] || { echo "Could not determine IPv4 on $LAN_IF"; exit 1; }
  TO_LAN_CHAIN="prefixnat_to_lan"
  nft list chain ip nat "$TO_LAN_CHAIN" >/dev/null 2>&1 || \
    nft add chain ip nat "$TO_LAN_CHAIN" '{ type nat hook postrouting priority 100; policy accept; }'
  FR_COMMENT="force-return via $LAN_IF to $LAN_IP for $DST_SUBNET->$SRC_SUBNET"
  if ! nft list chain ip nat "$TO_LAN_CHAIN" | grep -Fq -- "$FR_COMMENT"; then
    nft -f - <<EOF
add rule ip nat $TO_LAN_CHAIN \
  iifname "$ZT_IF" oifname "$LAN_IF" ip daddr $SRC_SUBNET \
  snat to $LAN_IP \
  comment "$FR_COMMENT"
EOF
  fi
  echo "Force-return SNAT installed on $LAN_IF ($LAN_IP)."
fi

# Persist runtime ruleset
CONF="/etc/nftables.conf"
BACKUP="/etc/nftables.conf.backup.$(date -Iseconds)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

nft list ruleset > "$TMP"
nft -c -f "$TMP"

[[ -f "$CONF" ]] && { echo "Backing up $CONF -> $BACKUP"; cp -a "$CONF" "$BACKUP"; }
cp -f "$TMP" "$CONF"

systemctl enable nftables >/dev/null
systemctl reload nftables 2>/dev/null || systemctl restart nftables

echo "✅ Applied 1:1 prefix NAT (PR/PO/OUTPUT) on $ZT_IF: $SRC_SUBNET <-> $DST_SUBNET"
[[ -n "$LAN_IF" ]] && echo "   (force-return SNAT active on $LAN_IF)"
