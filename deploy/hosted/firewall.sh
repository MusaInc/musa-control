#!/bin/bash
set -euo pipefail
# Only this dedicated bridge is affected. No global policy is changed.
BR=mc-hafsa
iptables -w -N MC_HAFSA 2>/dev/null || true
iptables -w -F MC_HAFSA
iptables -w -A MC_HAFSA -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
# Host, LAN, link-local/cloud metadata, multicast and other container networks.
for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
  iptables -w -A MC_HAFSA -d "$cidr" -j REJECT
done
while read -r addr; do iptables -w -A MC_HAFSA -d "$addr" -j REJECT; done < <(ip -o -4 addr show | awk '{print $4}')
iptables -w -A MC_HAFSA -p tcp -m multiport --dports 80,443 -j RETURN
iptables -w -A MC_HAFSA -p udp --dport 53 -j RETURN
iptables -w -A MC_HAFSA -p tcp --dport 53 -j RETURN
iptables -w -A MC_HAFSA -j REJECT
iptables -w -C DOCKER-USER -i "$BR" -j MC_HAFSA 2>/dev/null || iptables -w -I DOCKER-USER 1 -i "$BR" -j MC_HAFSA
# Host-bound packets do not traverse DOCKER-USER. Allow only replies.
iptables -w -N MC_HAFSA_HOST 2>/dev/null || true
iptables -w -F MC_HAFSA_HOST
iptables -w -A MC_HAFSA_HOST -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -w -A MC_HAFSA_HOST -j REJECT
iptables -w -C INPUT -i "$BR" -j MC_HAFSA_HOST 2>/dev/null || iptables -w -I INPUT 1 -i "$BR" -j MC_HAFSA_HOST
# IPv6 is disabled in both network and container; also reject it at host.
ip6tables -w -C INPUT -i "$BR" -j REJECT 2>/dev/null || ip6tables -w -I INPUT 1 -i "$BR" -j REJECT
ip6tables -w -C FORWARD -i "$BR" -j REJECT 2>/dev/null || ip6tables -w -I FORWARD 1 -i "$BR" -j REJECT
