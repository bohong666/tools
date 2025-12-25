#!/usr/bin/env bash
set -e

VERSION="2025.12.25-002"
PORT=6666
APP_DIR=/opt/monitor-server
DB_FILE=$APP_DIR/data.db

echo "===> Installing Monitor Server, version: $VERSION"

# ---------------- 1. 安装 Node.js 16 ----------------
echo "===> Checking Node.js..."
if command -v node >/dev/null || command -v npm >/dev/null; then
    echo "Old Node/npm detected, removing..."
    sudo apt remove -y nodejs npm || true
    sudo apt autoremove -y || true
fi

# 安装 Node.js 16
if command -v apt >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash -
    sudo apt install -y nodejs sqlite3 ca-certificates curl
elif command -v yum >/dev/null 2>&1; then
    curl -fsSL https://rpm.nodesource.com/setup_16.x | bash -
    yum install -y nodejs sqlite ca-certificates curl
fi

echo "Node.js installed: $(node -v)  npm: $(npm -v)"

# ---------------- 2. 创建目录 ----------------
mkdir -p $APP_DIR
cd $APP_DIR

# ---------------- 3. 服务端代码 ----------------
cat > server.js <<'EOF'
const http = require('http');
const fs = require('fs');
const crypto = require('crypto');
const sqlite3 = require('sqlite3').verbose();
const url = require('url');

const PORT = 6666;
const db = new sqlite3.Database('./data.db');

function hash(p) { return crypto.createHash('sha256').update(p).digest('hex'); }

db.serialize(() => {
  db.run(`CREATE TABLE IF NOT EXISTS admin (
    id INTEGER PRIMARY KEY,
    user TEXT,
    pass TEXT
  )`);

  db.run(`CREATE TABLE IF NOT EXISTS clients (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT,
    category TEXT,
    traffic_gb REAL,
    price REAL,
    last_ip TEXT,
    last_seen INTEGER
  )`);

  db.get("SELECT * FROM admin WHERE user='admin'", (e,r)=>{
    if(!r){ db.run("INSERT INTO admin VALUES(1,'admin',?)", hash("admin123")); }
  });
});

function send(res, code, data){
  res.writeHead(code, {"Content-Type":"application/json"});
  res.end(JSON.stringify(data));
}

const server = http.createServer((req,res)=>{
  const p=url.parse(req.url,true);

  if(p.pathname==='/api/login' && req.method==='POST'){
    let b=''; req.on('data',d=>b+=d);
    req.on('end',()=>{
      const j=JSON.parse(b);
      db.get("SELECT * FROM admin WHERE user=? AND pass=?",[j.user,hash(j.pass)],(e,r)=>{
        if(r) send(res,200,{ok:1});
        else send(res,403,{ok:0});
      });
    }); return;
  }

  if(p.pathname==='/api/pass' && req.method==='POST'){
    let b=''; req.on('data',d=>b+=d);
    req.on('end',()=>{
      const j=JSON.parse(b);
      db.run("UPDATE admin SET pass=?",hash(j.pass));
      send(res,200,{ok:1});
    }); return;
  }

  if(p.pathname==='/api/ping'){
    const {name}=p.query;
    db.run(
      "INSERT INTO clients(name,last_ip,last_seen) VALUES(?,?,?) \
      ON CONFLICT(name) DO UPDATE SET last_ip=?, last_seen=?",
      [name,req.socket.remoteAddress,Date.now(),
       req.socket.remoteAddress,Date.now()]
    );
    send(res,200,{ok:1}); return;
  }

  let file='./web'+(p.pathname==='/'?'/login.html':p.pathname);
  if(!fs.existsSync(file)) return send(res,404,{error:404});
  res.writeHead(200); fs.createReadStream(file).pipe(res);
});

server.listen(PORT,'0.0.0.0',()=>{
  console.log(`Monitor server on ${PORT}`);
  console.log(`Default admin: admin / admin123`);
});
EOF

# ---------------- 4. Web 前端 ----------------
mkdir -p web

cat > web/login.html <<'EOF'
<!DOCTYPE html>
<body>
<h3>Login</h3>
<input id=u placeholder=user><br>
<input id=p type=password placeholder=pass><br>
<button onclick=l()>Login</button>
<script>
function l(){
fetch('/api/login',{method:'POST',body:JSON.stringify({
user:u.value,pass:p.value})})
.then(r=>r.json()).then(j=>{
if(j.ok) location.href='admin.html';
else alert('fail');
});
}
</script>
</body>
EOF

cat > web/admin.html <<'EOF'
<!DOCTYPE html>
<body>
<h3>Admin</h3>
<button onclick=cp()>Change Password</button>
<script>
function cp(){
let p=prompt("new password");
fetch('/api/pass',{method:'POST',body:JSON.stringify({pass:p})});
alert('done');
}
</script>
</body>
EOF

# ---------------- 5. systemd 服务 ----------------
cat > /etc/systemd/system/monitor-server.service <<EOF
[Unit]
Description=Monitor Server
After=network.target

[Service]
ExecStart=/usr/bin/node $APP_DIR/server.js
WorkingDirectory=$APP_DIR
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable monitor-server
systemctl restart monitor-server

# ---------------- 6. 输出 IP + 版本 ----------------
IPV4=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}')
IPV6=$(ip -6 route get 2400:3200::1 2>/dev/null | awk '{print $7}')

echo
echo "===> Server installed successfully"
echo "Version: $VERSION"
[ -n "$IPV4" ] && echo "IPv4: http://$IPV4:$PORT/login.html"
[ -n "$IPV6" ] && echo "IPv6: http://[$IPV6]:$PORT/login.html"
echo "Admin: admin / admin123"
