# 🛠 常用脚本合集 | Useful Scripts Collection

一些自用并持续维护的 **Linux / 网络相关脚本**，主要用于反向代理、协议部署、协议转换及节点探针等场景。  
所有脚本均支持 **一键执行**，适合快速部署与测试环境使用。

A collection of **Linux & networking scripts** for personal use and ongoing maintenance.  
These scripts focus on reverse proxy, protocol deployment, protocol conversion, and node monitoring.  
All scripts support **one-line execution** for fast setup and testing.

---

## 📦 脚本列表 | Script List

### 🔁 反向代理脚本 | Reverse Proxy Script

用于快速部署反向代理服务。  
Quick deployment of reverse proxy services.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bohong666/tools/refs/heads/main/fd.sh)
```

---

### 📡 探针脚本 | Monitoring Probe

用于部署 Komari 探针，监控节点运行状态。  
Deploy Komari probe to monitor node status.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bohong666/tools/refs/heads/main/fd-komari.sh)
```

---

### 📤 修改上传限制 | Upload Limit Fix

用于修改服务器上传大小限制（如 Nginx / PHP 场景）。  
Adjust server upload size limits (e.g. Nginx / PHP).

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bohong666/tools/refs/heads/main/fd-fix.sh)
```

---

### 🔐 共用 443 端口（VLESS） | Shared 443 Port (VLESS)

实现 VLESS 共用 443 端口的快速配置。  
Quick setup for sharing port 443 with VLESS.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bohong666/tools/refs/heads/main/fd-vv.sh)
```

---

### 🔄 SS → VLESS 转换 | SS to VLESS

将 Shadowsocks 配置转换为 VLESS 使用。  
Convert Shadowsocks configuration to VLESS.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bohong666/tools/refs/heads/main/relay.sh)
```

---

### 🚀 VLESS + Reality + Vision

手搓版 Xray 脚本，集成 Reality 与 Vision。  
Handcrafted Xray script with Reality and Vision support.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bohong666/tools/refs/heads/main/xray.sh)
```
---

### 🚪 中转服务（任意门） | Relay Gateway (Any‑Door)

用于快速部署 任意门中转服务（Realm），支持多协议中转、低资源占用，适合多节点链路优化与流量中继场景。
Deploy a lightweight relay gateway (Realm) for multi‑protocol forwarding, ideal for traffic relay, routing optimization, and chained nodes.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/bohong666/tools/refs/heads/main/realm.sh)
```
---

## ⚠️ 使用说明 | Usage Notes

- 适用于 **Linux 系统**
- 建议使用 **root 权限** 执行
- 请在 **可信环境** 中运行，并自行审查脚本内容

- Designed for **Linux environments**
- **Root privileges** recommended
- Review scripts carefully before running in production

---

## 📌 说明 | Notes

本仓库脚本主要为个人使用整理，可能会根据实际需求不定期更新。  
欢迎提交 Issue 或 Fork 自行修改。

This repository contains scripts primarily maintained for personal use and may be updated as needed.  
Issues and forks are welcome.
