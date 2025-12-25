#!/usr/bin/env bash

SERVER="http://YOUR_SERVER_IP:6666"
NAME=$(hostname)

cat > /usr/local/bin/monitor-client.sh <<EOF
#!/bin/sh
curl -fsSL "$SERVER/api/ping?name=$NAME" >/dev/null 2>&1
EOF

chmod +x /usr/local/bin/monitor-client.sh

(crontab -l 2>/dev/null; echo "*/1 * * * * /usr/local/bin/monitor-client.sh") | crontab -

echo "Client installed. Reporting to $SERVER"
