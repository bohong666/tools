#!/usr/bin/env bash
set -e

VERSION="2025.12.25-005"
PORT=8080
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

const PORT = 8080;
const db = new sqlite3.Database('./data.db');

function hash(p){ return crypto.createHash('sha256').update(p).digest('hex'); }

db.serialize(()=>{
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
  db.get("SELECT * FROM admin WHERE user='admin'",(e,r)=>{
    if(!r){ db.run("INSERT INTO admin VALUES(1,'admin',?)", hash("admin123")); }
  });
});

function send(res, code, data){
  res.writeHead(code, {"Content-Type":"application/json"});
  res.end(JSON.stringify(data));
}

// ---------------- API ----------------
const server = http.createServer((req,res)=>{
  const p=url.parse(req.url,true);

  // 登录验证
  if(p.pathname==='/api/login' && req.method==='POST'){
    let b=''; req.on('data',d=>b+=d);
    req.on('end',()=>{
      try{
        const j=JSON.parse(b);
        db.get("SELECT * FROM admin WHERE user=? AND pass=?",[j.user,hash(j.pass)],(e,r)=>{
          if(r) send(res,200,{ok:1});
          else send(res,403,{ok:0});
        });
      }catch(e){ send(res,400,{ok:0}); }
    }); return;
  }

  // 修改管理员密码
  if(p.pathname==='/api/pass' && req.method==='POST'){
    let b=''; req.on('data',d=>b+=d);
    req.on('end',()=>{
      try{
        const j=JSON.parse(b);
        db.run("UPDATE admin SET pass=?",hash(j.pass));
        send(res,200,{ok:1});
      }catch(e){ send(res,400,{ok:0}); }
    }); return;
  }

  // 客户端上报
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

  // 获取客户端列表
  if(p.pathname==='/api/clients'){
    db.all("SELECT * FROM clients",(e,r)=>{
      send(res,200,r);
    }); return;
  }

  // 添加客户端
  if(p.pathname==='/api/client/add' && req.method==='POST'){
    let b=''; req.on('data',d=>b+=d);
    req.on('end',()=>{
      const j=JSON.parse(b);
      db.run("INSERT INTO clients(name,category,traffic_gb,price) VALUES(?,?,?,?)",
        [j.name,j.category,j.traffic_gb,j.price]);
      send(res,200,{ok:1});
    }); return;
  }

  // 修改客户端
  if(p.pathname==='/api/client/update' && req.method==='POST'){
    let b=''; req.on('data',d=>b+=d);
    req.on('end',()=>{
      const j=JSON.parse(b);
      db.run("UPDATE clients SET category=?,traffic_gb=?,price=? WHERE id=?",
        [j.category,j.traffic_gb,j.price,j.id]);
      send(res,200,{ok:1});
    }); return;
  }

  // 删除客户端
  if(p.pathname==='/api/client/delete' && req.method==='POST'){
    let b=''; req.on('data',d=>b+=d);
    req.on('end',()=>{
      const j=JSON.parse(b);
      db.run("DELETE FROM clients WHERE id=?", [j.id]);
      send(res,200,{ok:1});
    }); return;
  }

  // 总流量统计
  if(p.pathname==='/api/stats'){
    db.get("SELECT SUM(traffic_gb) AS total_gb FROM clients",(e,r)=>{
      send(res,200,r);
    }); return;
  }

  // 静态文件
  let file='./web'+(p.pathname==='/'?'/login.html':p.pathname);
  if(!fs.existsSync(file)) return send(res,404,{error:404});
  res.writeHead(200); fs.createReadStream(file).pipe(res);
});

server.listen(PORT,'0.0.0.0',()=>{
  console.log(`Monitor server on ${PORT}`);
  console.log(`Default admin: admin / admin123`);
});
EOF

# ---------------- 4. Web 前端（严格保留原始设计） ----------------
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
else alert('Login failed');
});
}
</script>
</body>
EOF

cat > web/admin.html <<'EOF'
<!DOCTYPE html>
<body>
<h3>Admin / Client Management</h3>
<button onclick=cp()>Change Password</button>
<hr>
<h4>Client List</h4>
<table border=1 id=tbl><tr><th>ID</th><th>Name</th><th>Category</th><th>Traffic(GB)</th><th>Price</th><th>Action</th></tr></table>
<button onclick=add()>Add Client</button>
<h4>Total Traffic: <span id=total>0</span> GB</h4>
<script>
function cp(){
let p=prompt("New password");
fetch('/api/pass',{method:'POST',body:JSON.stringify({pass:p})});
alert('Password changed');
}
function loadClients(){
fetch('/api/clients').then(r=>r.json()).then(d=>{
let tbl=document.getElementById('tbl'); tbl.innerHTML="<tr><th>ID</th><th>Name</th><th>Category</th><th>Traffic(GB)</th><th>Price</th><th>Action</th></tr>";
d.forEach(c=>{
let tr=tbl.insertRow();
tr.insertCell(0).innerText=c.id;
tr.insertCell(1).innerText=c.name;
tr.insertCell(2).innerText=c.category;
tr.insertCell(3).innerText=c.traffic_gb;
tr.insertCell(4).innerText=c.price;
tr.insertCell(5).innerHTML='<button onclick="upd('+c.id+')">Edit</button> <button onclick="del('+c.id+')">Del</button>';
});
});
fetch('/api/stats').then(r=>r.json()).then(s=>document.getElementById('total').innerText=s.total_gb||0);
}
function add(){
let name=prompt("Name"),cat=prompt("Category"),tra=prompt("Traffic(GB)"),price=prompt("Price");
fetch('/api/client/add',{method:'POST',body:JSON.stringify({name:name,category:cat,traffic_gb:tra,price:price})}).then(()=>loadClients());
}
function upd(id){
let cat=prompt("Category"),tra=prompt("Traffic(GB)"),price=prompt("Price");
fetch('/api/client/update',{method:'POST',body:JSON.stringify({id:id,category:cat,traffic_gb:tra,price:price})}).then(()=>loadClients());
}
function del(id){
if(confirm("Delete?")) fetch('/api/client/delete',{method:'POST',body:JSON.stringify({id:id})}).then(()=>loadClients());
}
loadClients();
setInterval(loadClients,60000);
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
User=root
Group=root

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
[ -n "$IPV4" ] && echo "IPv4: http://$IPV4:8080/login.html"
[ -n "$IPV6" ] && echo "IPv6: http://[$IPV6]:8080/login.html"
echo "Admin: admin / admin123"
