#!/bin/bash
set -euo pipefail
# Only this dedicated bridge is affected. No global policy is changed.
BR=mc-hafsa
# Replace both chains in a single transaction so reapplying protection never
# creates an interval with an empty allow-all chain.
iptables -w -N MC_HAFSA 2>/dev/null || true
iptables -w -N MC_HAFSA_HOST 2>/dev/null || true
RULES=$(mktemp)
trap 'rm -f "$RULES"' EXIT
{
  echo '*filter'
  echo '-F MC_HAFSA'
  echo '-F MC_HAFSA_HOST'
  echo '-A MC_HAFSA -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN'
  for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    echo "-A MC_HAFSA -d $cidr -j REJECT"
  done
  while read -r addr; do echo "-A MC_HAFSA -d $addr -j REJECT"; done < <(ip -o -4 addr show | awk '{print $4}')
  echo '-A MC_HAFSA -p tcp -m multiport --dports 80,443 -j RETURN'
  echo '-A MC_HAFSA -p udp --dport 53 -j RETURN'
  echo '-A MC_HAFSA -p tcp --dport 53 -j RETURN'
  echo '-A MC_HAFSA -j REJECT'
  echo '-A MC_HAFSA_HOST -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'
  echo '-A MC_HAFSA_HOST -j REJECT'
  echo 'COMMIT'
} > "$RULES"
iptables-restore --wait 5 --noflush < "$RULES"
iptables -w -C DOCKER-USER -i "$BR" -j MC_HAFSA 2>/dev/null || iptables -w -I DOCKER-USER 1 -i "$BR" -j MC_HAFSA
iptables -w -C INPUT -i "$BR" -j MC_HAFSA_HOST 2>/dev/null || iptables -w -I INPUT 1 -i "$BR" -j MC_HAFSA_HOST
ip6tables -w -C INPUT -i "$BR" -j REJECT 2>/dev/null || ip6tables -w -I INPUT 1 -i "$BR" -j REJECT
ip6tables -w -C FORWARD -i "$BR" -j REJECT 2>/dev/null || ip6tables -w -I FORWARD 1 -i "$BR" -j REJECT
