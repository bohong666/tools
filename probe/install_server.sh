#!/usr/bin/env bash
set -e

PORT=6666
BASE_DIR=/opt/monitor-server

echo "===> Installing Monitor Server on port ${PORT}"

# 1. 安装基础依赖
if command -v apt >/dev/null 2>&1; then
  apt update
  apt install -y curl ca-certificates nodejs npm sqlite3
elif command -v yum >/dev/null 2>&1; then
  yum install -y curl ca-certificates nodejs npm sqlite
else
  echo "Unsupported system"
  exit 1
fi

# 2. 创建目录
rm -rf ${BASE_DIR}
mkdir -p ${BASE_DIR}/public
cd ${BASE_DIR}

# 3. package.json
cat > package.json <<'EOF'
{
  "name": "monitor-server",
  "private": true,
  "dependencies": {
    "bcrypt": "^5.1.0",
    "express": "^4.19.2",
    "jsonwebtoken": "^9.0.2",
    "sqlite3": "^5.1.7"
  }
}
EOF

# 4. server.js
cat > server.js <<'EOF'
const express=require('express');
const sqlite3=require('sqlite3').verbose();
const bcrypt=require('bcrypt');
const jwt=require('jsonwebtoken');
const crypto=require('crypto');
const path=require('path');

const PORT=6666;
const JWT_SECRET=crypto.randomBytes(32).toString('hex');
const app=express();
app.use(express.json());
app.use(express.urlencoded({extended:true}));
app.use(express.static(path.join(__dirname,'public')));
const db=new sqlite3.Database('./monitor.db');

db.serialize(()=>{
  db.run(`CREATE TABLE IF NOT EXISTS admins(
    id INTEGER PRIMARY KEY,
    username TEXT UNIQUE,
    password_hash TEXT
  )`);
  db.run(`CREATE TABLE IF NOT EXISTS servers(
    id INTEGER PRIMARY KEY,
    name TEXT,
    token TEXT UNIQUE,
    category TEXT,
    monthly_fee REAL,
    remark TEXT
  )`);
  db.run(`CREATE TABLE IF NOT EXISTS metrics(
    id INTEGER PRIMARY KEY,
    server_id INTEGER,
    rx_bytes INTEGER,
    tx_bytes INTEGER,
    lat_cu INTEGER,
    lat_cm INTEGER,
    lat_ct INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )`);
  db.get(`SELECT COUNT(*) c FROM admins`,async(_,r)=>{
    if(r.c===0){
      const h=await bcrypt.hash('admin123',12);
      db.run(`INSERT INTO admins(username,password_hash) VALUES('admin',?)`,[h]);
      console.log('Default admin: admin / admin123');
    }
  });
});

function authAdmin(req,res,next){
  const t=req.headers.authorization?.replace('Bearer ','');
  if(!t) return res.sendStatus(401);
  try{req.admin=jwt.verify(t,JWT_SECRET);next();}catch{res.sendStatus(401);}
}
function authClient(req,res,next){
  const t=req.headers.authorization?.replace('Bearer ','');
  if(!t) return res.sendStatus(401);
  db.get(`SELECT id FROM servers WHERE token=?`,[t],(_,r)=>{
    if(!r) return res.sendStatus(403);
    req.sid=r.id;next();
  });
}

app.post('/api/admin/login',(req,res)=>{
  const{username,password}=req.body;
  db.get(`SELECT * FROM admins WHERE username=?`,[username],async(_,r)=>{
    if(!r||!await bcrypt.compare(password,r.password_hash))
      return res.sendStatus(401);
    res.json({token:jwt.sign({id:r.id},JWT_SECRET,{expiresIn:'6h'})});
  });
});

app.post('/api/admin/change-password',authAdmin,async(req,res)=>{
  const{old_password,new_password}=req.body;
  db.get(`SELECT password_hash FROM admins WHERE id=?`,[req.admin.id],
    async(_,r)=>{
      if(!await bcrypt.compare(old_password,r.password_hash))
        return res.sendStatus(403);
      const h=await bcrypt.hash(new_password,12);
      db.run(`UPDATE admins SET password_hash=? WHERE id=?`,
        [h,req.admin.id],()=>res.json({ok:1}));
    });
});

app.post('/api/admin/servers',authAdmin,(req,res)=>{
  const t=crypto.randomBytes(24).toString('hex');
  const{name,category,monthly_fee,remark}=req.body;
  db.run(`INSERT INTO servers(name,token,category,monthly_fee,remark)
          VALUES(?,?,?,?,?)`,
    [name,t,category,monthly_fee,remark],()=>res.json({token:t}));
});

app.get('/api/admin/servers',authAdmin,(_,res)=>{
  db.all(`
    SELECT s.*,
    IFNULL(SUM(m.rx_bytes+m.tx_bytes),0)/1024/1024/1024 total_gb
    FROM servers s LEFT JOIN metrics m ON s.id=m.server_id
    GROUP BY s.id`,(_,r)=>res.json(r));
});

app.post('/api/metrics',authClient,(req,res)=>{
  const{rx,tx,lat_cu,lat_cm,lat_ct}=req.body;
  db.run(`INSERT INTO metrics(server_id,rx_bytes,tx_bytes,lat_cu,lat_cm,lat_ct)
          VALUES(?,?,?,?,?,?)`,
    [req.sid,rx,tx,lat_cu,lat_cm,lat_ct],()=>res.json({ok:1}));
});

app.listen(PORT,()=>console.log('Monitor server on',PORT));
EOF

# 5. 前端
cat > public/login.html <<'EOF'
<!doctype html><body>
<h3>Admin Login</h3>
<input id=u placeholder=username>
<input id=p type=password placeholder=password>
<button onclick=go()>Login</button>
<script>
function go(){
fetch('/api/admin/login',{method:'POST',
headers:{'Content-Type':'application/json'},
body:JSON.stringify({username:u.value,password:p.value})
}).then(r=>r.json()).then(d=>{
localStorage.token=d.token;location.href='/';});
}
</script>
</body>
EOF

cat > public/index.html <<'EOF'
<!doctype html><body>
<h3>Servers</h3><pre id=o></pre>
<script>
fetch('/api/admin/servers',{headers:{
Authorization:'Bearer '+localStorage.token}})
.then(r=>r.json()).then(d=>o.textContent=JSON.stringify(d,null,2));
</script>
</body>
EOF

# 6. 安装依赖
npm install --silent

# 7. systemd
cat >/etc/systemd/system/monitor-server.service <<EOF
[Unit]
Description=Monitor Server
After=network.target
[Service]
WorkingDirectory=${BASE_DIR}
ExecStart=/usr/bin/node server.js
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now monitor-server

echo "===> Server installed"
echo "Login: http://IP:${PORT}/login.html"
echo "Admin: admin / admin123"
