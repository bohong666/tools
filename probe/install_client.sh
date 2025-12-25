#!/usr/bin/env bash
set -e

read -p "Server URL (e.g. http://1.2.3.4:6666): " SERVER
read -p "Client Token: " TOKEN

DIR=/opt/monitor-client
mkdir -p $DIR

cat > $DIR/client.sh <<EOF
#!/bin/sh
SERVER="${SERVER}"
TOKEN="${TOKEN}"

rx=\$(awk '/eth0/ {rx+=\$2} END{print rx}' /proc/net/dev)
tx=\$(awk '/eth0/ {tx+=\$10} END{print tx}' /proc/net/dev)

tcp() {
 curl -o /dev/null -s -w "%{time_connect}" --connect-timeout 2 http://\$1 |
 awk '{printf "%.0f",\$1*1000}'
}

lat_cu=\$(tcp sh-cu-v4.ip.zstaticcdn.com:80)
lat_cm=\$(tcp sh-cm-v4.ip.zstaticcdn.com:80)
lat_ct=\$(tcp sh-ct-v4.ip.zstaticcdn.com:80)

curl -s -X POST "\$SERVER/api/metrics" \
 -H "Authorization: Bearer \$TOKEN" \
 -d "rx=\$rx&tx=\$tx&lat_cu=\$lat_cu&lat_cm=\$lat_cm&lat_ct=\$lat_ct"
EOF

chmod +x $DIR/client.sh

(crontab -l 2>/dev/null; echo "*/1 * * * * $DIR/client.sh >/dev/null 2>&1") | crontab -

echo "===> Client installed (report every 1 min)"
