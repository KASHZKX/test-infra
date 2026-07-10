#!/usr/bin/env bash
set -e

NET_NAME="kind"

NET_ID=$(sudo docker network inspect "$NET_NAME" -f '{{.Id}}')
BR_OPT=$(sudo docker network inspect "$NET_NAME" -f '{{ index .Options "com.docker.network.bridge.name" }}' 2>/dev/null || true)

# Docker 預設 bridge 名稱通常是 br-<network-id 前 12 碼>
BR_DEFAULT="br-${NET_ID:0:12}"

if [ -n "$BR_OPT" ] && ip link show "$BR_OPT" >/dev/null 2>&1; then
  BR="$BR_OPT"
elif ip link show "$BR_DEFAULT" >/dev/null 2>&1; then
  BR="$BR_DEFAULT"
else
  echo "ERROR: cannot find bridge for docker network '$NET_NAME'"
  echo "network id: $NET_ID"
  echo "tried: '$BR_OPT' and '$BR_DEFAULT'"
  echo "Current bridge devices:"
  ip link show | grep -E 'br-|docker0' || true
  exit 1
fi

SUBNET=$(sudo docker network inspect "$NET_NAME" \
  -f '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' \
  | grep -oE '172\.[0-9]+\.[0-9]+\.0/[0-9]+' \
  | head -1)

GW=$(sudo docker network inspect "$NET_NAME" \
  -f '{{range .IPAM.Config}}{{println .Gateway}}{{end}}' \
  | grep -oE '172\.[0-9]+\.[0-9]+\.1' \
  | head -1)

if [ -z "$SUBNET" ] || [ -z "$GW" ]; then
  echo "ERROR: cannot detect IPv4 subnet/gateway for docker network '$NET_NAME'"
  sudo docker network inspect "$NET_NAME"
  exit 1
fi

echo "bridge=$BR subnet=$SUBNET gateway=$GW"

sudo ip addr add "$GW/${SUBNET#*/}" dev "$BR" 2>/dev/null || true
sudo ip link set "$BR" up
sudo ip route replace "$SUBNET" dev "$BR" src "$GW"

echo "== Route check =="
MGMT_IP=$(sudo docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kind-control-plane)
echo "MGMT_IP=$MGMT_IP"
ip route get "$MGMT_IP"

echo "== API check =="
curl -k --max-time 5 "https://${MGMT_IP}:6443/readyz" || true
curl -k --max-time 5 https://127.0.0.1:40145/readyz || true
kubectl get nodes || true
# VM 長時間 suspend / 停滯後，Docker KIND bridge 的 IPv4 位址或路由遺失，導致 host 無法連到 KIND container 的 API server。
# `172.18.0.2 via 192.168.164.2 dev ens33` 這是不正常的。172.18.0.2 是 Docker container IP，應該走 Docker bridge，而不是走 VM 外部網卡 ens33。
# 正常應該是： 172.18.0.2 dev br-ae62945427aa src 172.18.0.1