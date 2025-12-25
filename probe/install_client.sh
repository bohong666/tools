#!/usr/bin/env bash
VERSION="2025.12.25-003"
echo "===> Installing Monitor Client, version: $VERSION"

SERVER="http://YOUR_SERVER_IP"
NAME=$(hostname)

cat > /usr/local/bin/monitor-client.sh <<EOF
#!/bin/sh
echo "Client version: $VERSION"
curl -fsSL "$SERVER/api/ping?name=$NAME" >/dev/null 2>&1
EOF

chmod +x /usr/local/bin/monitor-client.sh

(crontab -l 2>/dev/null; echo "*/1 * * * * /usr/local/bin/monitor-client.sh") | crontab -

echo "Client installed. Reporting to $SERVER"
echo "Version: $VERSION"
