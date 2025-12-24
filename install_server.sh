#!/bin/bash

# ================================================
# 服务器监控系统 - 服务端一键安装脚本 v2
# 修复 Ubuntu 18.04 兼容性问题
# ================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}"
cat << "EOF"
╔════════════════════════════════════════════════╗
║     服务器监控系统 - 服务端一键安装 v2         ║
║     Server Monitor - Auto Installer            ║
╚════════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        echo -e "${RED}无法检测操作系统类型${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ 检测到操作系统: $OS $VERSION${NC}"
}

# 安装 Node.js
install_nodejs() {
    echo -e "\n${YELLOW}→ 正在安装 Node.js...${NC}"
    
    if command -v node &> /dev/null; then
        NODE_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$NODE_VERSION" -ge 14 ]; then
            echo -e "${GREEN}✓ Node.js 已安装 ($(node -v))${NC}"
            return
        fi
    fi

    # Ubuntu 18.04 使用 Node.js 16
    if [[ "$OS" == "ubuntu" ]] && [[ "$VERSION" == "18.04" ]]; then
        echo -e "${YELLOW}! Ubuntu 18.04 检测到，安装 Node.js 16 (兼容版本)${NC}"
        curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash - || {
            echo -e "${YELLOW}! 官方源失败，尝试备用方案...${NC}"
            install_nodejs_via_nvm
            return
        }
        sudo apt-get install -y nodejs || {
            echo -e "${YELLOW}! apt 安装失败，使用 NVM...${NC}"
            install_nodejs_via_nvm
            return
        }
    elif [[ "$OS" == "ubuntu" ]] || [[ "$OS" == "debian" ]]; then
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        sudo apt-get install -y nodejs
    elif [[ "$OS" == "centos" ]] || [[ "$OS" == "rhel" ]]; then
        curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
        sudo yum install -y nodejs
    fi

    if ! command -v node &> /dev/null; then
        echo -e "${RED}✗ Node.js 安装失败，尝试使用 NVM 安装...${NC}"
        install_nodejs_via_nvm
        return
    fi

    echo -e "${GREEN}✓ Node.js 安装完成 ($(node -v))${NC}"
}

# 备用方案：使用 NVM 安装 Node.js
install_nodejs_via_nvm() {
    echo -e "${YELLOW}→ 使用 NVM 安装 Node.js 16...${NC}"
    
    # 安装 NVM
    export HOME=/root
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    
    # 加载 NVM
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    
    # 安装 Node.js 16
    nvm install 16
    nvm use 16
    nvm alias default 16
    
    # 创建系统级软链接
    NODE_PATH=$(nvm which 16)
    NPM_PATH=$(dirname $NODE_PATH)/npm
    
    sudo ln -sf "$NODE_PATH" /usr/local/bin/node
    sudo ln -sf "$NPM_PATH" /usr/local/bin/npm
    
    # 更新 PATH
    echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.bashrc
    export PATH="/usr/local/bin:$PATH"
    
    echo -e "${GREEN}✓ Node.js 通过 NVM 安装完成 ($(node -v))${NC}"
}

# 创建项目目录
create_project() {
    echo -e "\n${YELLOW}→ 创建项目目录...${NC}"
    
    INSTALL_DIR="/opt/server-monitor"
    sudo mkdir -p $INSTALL_DIR
    cd $INSTALL_DIR
    
    echo -e "${GREEN}✓ 项目目录: $INSTALL_DIR${NC}"
}

# 创建 package.json
create_package_json() {
    echo -e "\n${YELLOW}→ 创建 package.json...${NC}"
    
    cat > package.json << 'PACKAGE_EOF'
{
  "name": "server-monitor",
  "version": "1.0.0",
  "description": "Server monitoring system",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5",
    "sqlite3": "^5.1.6",
    "ws": "^8.14.2"
  }
}
PACKAGE_EOF

    echo -e "${GREEN}✓ package.json 创建完成${NC}"
}

# 创建服务端代码
create_server_code() {
    echo -e "\n${YELLOW}→ 创建服务端代码...${NC}"
    
    cat > server.js << 'SERVER_EOF'
const express = require('express');
const cors = require('cors');
const sqlite3 = require('sqlite3').verbose();
const WebSocket = require('ws');
const crypto = require('crypto');
const http = require('http');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());
app.use(express.static('public'));

const db = new sqlite3.Database('./monitor.db', (err) => {
  if (err) console.error('Database error:', err);
  else {
    console.log('✓ Database connected');
    initDatabase();
  }
});

function initDatabase() {
  db.run(`CREATE TABLE IF NOT EXISTS servers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    merchant TEXT,
    country TEXT DEFAULT 'US',
    os TEXT,
    status TEXT DEFAULT 'offline',
    price TEXT,
    blog_link TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    last_seen DATETIME
  )`);

  db.run(`CREATE TABLE IF NOT EXISTS metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_token TEXT NOT NULL,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    cpu_cores INTEGER,
    cpu_usage REAL,
    memory_total REAL,
    memory_used REAL,
    memory_percent REAL,
    disk_total REAL,
    disk_used REAL,
    disk_percent REAL,
    network_sent REAL,
    network_recv REAL,
    upload_speed REAL,
    download_speed REAL,
    uptime REAL,
    delay_ct INTEGER,
    delay_cu INTEGER,
    delay_cm INTEGER
  )`);

  db.run(`CREATE TABLE IF NOT EXISTS traffic_daily (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    server_token TEXT NOT NULL,
    date DATE NOT NULL,
    upload REAL DEFAULT 0,
    download REAL DEFAULT 0,
    UNIQUE(server_token, date)
  )`);
}

const authenticate = (req, res, next) => {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing token' });
  }
  const token = authHeader.substring(7);
  db.get('SELECT * FROM servers WHERE token = ?', [token], (err, server) => {
    if (err || !server) return res.status(401).json({ error: 'Invalid token' });
    req.server = server;
    next();
  });
};

app.post('/api/register', (req, res) => {
  const { name, merchant, country, os, price, blog_link } = req.body;
  if (!name) return res.status(400).json({ error: 'Name required' });
  
  const token = crypto.randomBytes(32).toString('hex');
  db.run(
    `INSERT INTO servers (token, name, merchant, country, os, price, blog_link) 
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [token, name, merchant || 'Unknown', country || 'US', os, price, blog_link],
    function(err) {
      if (err) return res.status(500).json({ error: 'Registration failed' });
      res.json({ success: true, token, server_id: this.lastID });
    }
  );
});

app.post('/api/metrics', authenticate, (req, res) => {
  const { cpu, memory, disk, network, uptime, delays } = req.body;
  const token = req.server.token;

  db.run('UPDATE servers SET status = ?, last_seen = CURRENT_TIMESTAMP WHERE token = ?', ['online', token]);

  db.run(
    `INSERT INTO metrics (
      server_token, cpu_cores, cpu_usage, memory_total, memory_used, memory_percent,
      disk_total, disk_used, disk_percent, network_sent, network_recv, 
      upload_speed, download_speed, uptime, delay_ct, delay_cu, delay_cm
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [token, cpu.cores, cpu.usage, memory.total, memory.used, memory.percent,
     disk.total, disk.used, disk.percent, network.total_sent, network.total_recv,
     network.upload_speed, network.download_speed, uptime, delays.ct, delays.cu, delays.cm],
    (err) => {
      if (err) return res.status(500).json({ error: 'Save failed' });
      updateDailyTraffic(token, network.upload_speed, network.download_speed);
      broadcastUpdate(token);
      res.json({ success: true });
    }
  );
});

app.get('/api/servers', (req, res) => {
  const query = `
    SELECT s.*, m.cpu_cores, m.cpu_usage, m.memory_total, m.memory_used, m.memory_percent,
           m.disk_total, m.disk_used, m.disk_percent, m.network_sent, m.network_recv,
           m.upload_speed, m.download_speed, m.uptime, m.delay_ct, m.delay_cu, m.delay_cm,
           m.timestamp as last_update
    FROM servers s
    LEFT JOIN (
      SELECT * FROM metrics m1 WHERE timestamp = (
        SELECT MAX(timestamp) FROM metrics m2 WHERE m2.server_token = m1.server_token
      )
    ) m ON s.token = m.server_token
    ORDER BY s.id
  `;

  db.all(query, [], (err, rows) => {
    if (err) return res.status(500).json({ error: 'Fetch failed' });
    const now = Date.now();
    const servers = rows.map(row => {
      const lastSeen = new Date(row.last_seen || 0).getTime();
      const isOnline = (now - lastSeen) < 5 * 60 * 1000;
      return {
        id: row.id, name: row.name, merchant: row.merchant, country: row.country,
        os: row.os, status: isOnline ? 'online' : 'offline', price: row.price,
        blog_link: row.blog_link,
        cpu: { cores: row.cpu_cores || 0, usage: row.cpu_usage || 0 },
        memory: { total: row.memory_total || 0, used: row.memory_used || 0, percent: row.memory_percent || 0 },
        disk: { total: row.disk_total || 0, used: row.disk_used || 0, percent: row.disk_percent || 0 },
        network: { tx: row.network_sent || 0, rx: row.network_recv || 0 },
        speed: { upload: row.upload_speed || 0, download: row.download_speed || 0 },
        uptime: row.uptime || 0,
        delays: { ct: row.delay_ct || 0, cu: row.delay_cu || 0, cm: row.delay_cm || 0 },
        last_update: row.last_update
      };
    });
    res.json({ servers });
  });
});

function updateDailyTraffic(token, upload, download) {
  const today = new Date().toISOString().split('T')[0];
  db.run(
    `INSERT INTO traffic_daily (server_token, date, upload, download)
     VALUES (?, ?, ?, ?)
     ON CONFLICT(server_token, date) DO UPDATE SET 
       upload = upload + excluded.upload, download = download + excluded.download`,
    [token, today, upload / 1024, download / 1024]
  );
}

const server = http.createServer(app);
const wss = new WebSocket.Server({ server });
const clients = new Set();

wss.on('connection', (ws) => {
  clients.add(ws);
  ws.on('close', () => clients.delete(ws));
});

function broadcastUpdate(token) {
  clients.forEach(client => {
    if (client.readyState === WebSocket.OPEN) {
      client.send(JSON.stringify({ type: 'update', token }));
    }
  });
}

server.listen(PORT, '0.0.0.0', () => {
  const os = require('os');
  const interfaces = os.networkInterfaces();
  let serverIP = '0.0.0.0';
  
  for (const name of Object.keys(interfaces)) {
    for (const iface of interfaces[name]) {
      if (iface.family === 'IPv4' && !iface.internal) {
        serverIP = iface.address;
        break;
      }
    }
  }
  
  console.log(`
╔════════════════════════════════════════╗
║   服务器监控系统已启动                 ║
╠════════════════════════════════════════╣
║  访问地址: http://${serverIP}:${PORT}
║  本地访问: http://localhost:${PORT}
╚════════════════════════════════════════╝
  `);
});

process.on('SIGINT', () => {
  console.log('\n正在关闭...');
  db.close();
  server.close();
  process.exit(0);
});
SERVER_EOF

    echo -e "${GREEN}✓ 服务端代码创建完成${NC}"
}

# 创建前端页面
create_frontend() {
    echo -e "\n${YELLOW}→ 创建前端页面...${NC}"
    
    mkdir -p public
    
    cat > public/index.html << 'HTML_EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>服务器监控面板</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-900 text-gray-100 p-4">
    <div class="max-w-7xl mx-auto">
        <h1 class="text-3xl font-bold mb-6 text-center">🖥️ 服务器监控面板</h1>
        
        <div class="bg-gray-800 rounded-lg p-4 mb-4 flex flex-wrap gap-4 text-sm">
            <div>🟢 在线: <span id="online-count">0</span></div>
            <div>🔴 离线: <span id="offline-count">0</span></div>
            <div>📍 区域: <span id="location-count">0</span></div>
        </div>

        <div id="servers-container" class="space-y-2"></div>

        <div class="mt-8 text-center text-sm text-gray-500">
            <p>服务器监控系统 v1.0 | 自动刷新: 30秒</p>
        </div>
    </div>

    <script>
        const API_URL = window.location.origin + '/api';
        
        async function fetchServers() {
            try {
                const res = await fetch(`${API_URL}/servers`);
                const data = await res.json();
                renderServers(data.servers);
            } catch (e) {
                console.error('获取数据失败:', e);
            }
        }

        function renderServers(servers) {
            const container = document.getElementById('servers-container');
            const online = servers.filter(s => s.status === 'online').length;
            
            document.getElementById('online-count').textContent = online;
            document.getElementById('offline-count').textContent = servers.length - online;
            document.getElementById('location-count').textContent = new Set(servers.map(s => s.country)).size;

            container.innerHTML = servers.map(s => `
                <div class="bg-gray-800 rounded-lg p-4 hover:bg-gray-700 transition">
                    <div class="grid grid-cols-1 md:grid-cols-6 gap-4 text-sm">
                        <div class="flex items-center gap-2">
                            <div class="w-3 h-3 rounded-full ${s.status === 'online' ? 'bg-green-500' : 'bg-red-500'}"></div>
                            <div>
                                <div class="font-semibold">${s.name}</div>
                                <div class="text-xs text-gray-400">${s.merchant || 'Unknown'}</div>
                            </div>
                        </div>
                        <div>
                            <div class="text-xs text-gray-400">CPU</div>
                            <div>${s.cpu.usage.toFixed(1)}% (${s.cpu.cores}核)</div>
                        </div>
                        <div>
                            <div class="text-xs text-gray-400">内存</div>
                            <div>${s.memory.percent.toFixed(1)}%</div>
                            <div class="text-xs">${s.memory.used.toFixed(1)}/${s.memory.total.toFixed(1)} GB</div>
                        </div>
                        <div>
                            <div class="text-xs text-gray-400">硬盘</div>
                            <div>${s.disk.percent.toFixed(1)}%</div>
                        </div>
                        <div>
                            <div class="text-xs text-gray-400">速率</div>
                            <div class="text-xs text-green-400">↑ ${s.speed.upload.toFixed(2)} MB/s</div>
                            <div class="text-xs text-red-400">↓ ${s.speed.download.toFixed(2)} MB/s</div>
                        </div>
                        <div>
                            <div class="text-xs text-gray-400">延迟</div>
                            <div class="text-xs">电信:${s.delays.ct}ms 联通:${s.delays.cu}ms</div>
                        </div>
                    </div>
                </div>
            `).join('');
        }

        fetchServers();
        setInterval(fetchServers, 30000);

        const ws = new WebSocket(`ws://${window.location.host}`);
        ws.onmessage = () => fetchServers();
    </script>
</body>
</html>
HTML_EOF

    echo -e "${GREEN}✓ 前端页面创建完成${NC}"
}

# 安装依赖
install_dependencies() {
    echo -e "\n${YELLOW}→ 安装项目依赖 (可能需要几分钟)...${NC}"
    npm install --production
    echo -e "${GREEN}✓ 依赖安装完成${NC}"
}

# 创建启动脚本
create_start_script() {
    echo -e "\n${YELLOW}→ 创建启动脚本...${NC}"
    
    cat > start.sh << 'START_EOF'
#!/bin/bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
cd /opt/server-monitor
node server.js
START_EOF

    chmod +x start.sh
    echo -e "${GREEN}✓ 启动脚本创建完成${NC}"
}

# 创建 systemd 服务
create_systemd_service() {
    echo -e "\n${YELLOW}→ 创建系统服务...${NC}"
    
    cat | sudo tee /etc/systemd/system/server-monitor.service > /dev/null << SERVICE_EOF
[Unit]
Description=Server Monitor System
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/bin/bash $INSTALL_DIR/start.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    sudo systemctl daemon-reload
    sudo systemctl enable server-monitor
    echo -e "${GREEN}✓ 系统服务创建完成${NC}"
}

# 配置防火墙
configure_firewall() {
    echo -e "\n${YELLOW}→ 配置防火墙...${NC}"
    
    if command -v ufw &> /dev/null; then
        sudo ufw allow 3000/tcp 2>/dev/null || true
        echo -e "${GREEN}✓ UFW 防火墙规则已添加${NC}"
    elif command -v firewall-cmd &> /dev/null; then
        sudo firewall-cmd --permanent --add-port=3000/tcp 2>/dev/null || true
        sudo firewall-cmd --reload 2>/dev/null || true
        echo -e "${GREEN}✓ Firewalld 规则已添加${NC}"
    else
        echo -e "${YELLOW}! 未检测到防火墙${NC}"
    fi
}

# 启动服务
start_service() {
    echo -e "\n${YELLOW}→ 启动服务...${NC}"
    sudo systemctl start server-monitor
    sleep 3
    
    if sudo systemctl is-active --quiet server-monitor; then
        echo -e "${GREEN}✓ 服务启动成功${NC}"
    else
        echo -e "${RED}✗ 服务启动失败${NC}"
        echo -e "${YELLOW}查看日志: journalctl -u server-monitor -n 50${NC}"
        exit 1
    fi
}

# 显示完成信息
show_completion() {
    SERVER_IP=$(hostname -I | awk '{print $1}')
    
    echo -e "\n${GREEN}"
    cat << EOF
╔════════════════════════════════════════════════╗
║              🎉 安装完成！                     ║
╠════════════════════════════════════════════════╣
║                                                ║
║  📱 访问地址:                                  ║
║     http://$SERVER_IP:3000                ║
║     http://localhost:3000 (本地)               ║
║                                                ║
║  📋 管理命令:                                  ║
║     systemctl start server-monitor            ║
║     systemctl stop server-monitor             ║
║     systemctl status server-monitor           ║
║     journalctl -u server-monitor -f           ║
║                                                ║
╚════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# 主流程
main() {
    detect_os
    install_nodejs
    create_project
    create_package_json
    create_server_code
    create_frontend
    install_dependencies
    create_start_script
    create_systemd_service
    configure_firewall
    start_service
    show_completion
}

main
