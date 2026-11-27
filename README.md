# CloudFRP

一个可自托管的 FRP 内网穿透面板：Web 管理端 + 节点捐赠 + 会员积分体系 + 跨平台桌面启动器。

- 后端：Python 3.10+ / Flask / SQLite（可选 MySQL）
- 前端：服务端渲染的 Jinja 页面 + 原生 JS，无需 Node 构建
- 启动器：Rust + egui（Windows / Linux / macOS）

## 功能

**隧道**
- TCP / UDP / HTTP / HTTPS
- 本地端口、远程端口、自定义域名
- 自动分配远程端口（遵循节点允许的端口范围）
- 一键安装脚本 / Windows PowerShell 一条命令

**节点捐赠**
- 捐赠节点自动注册、管理员审核
- 心跳在线状态（30 秒无心跳判定离线）
- 节点描述、允许的端口范围
- 节点流量与客户端数统计
- 面板生成的一键安装脚本（优先面板内置 frps，多镜像回退）

**用户体系**
- 注册 / 邮箱登录 / 用户名登录
- 图片验证码（自研：依次点击 3 个字符）
- 每日签到、积分、会员等级权益
- 会员：积分加成、隧道/节点/域名/SSL/带宽额度
- 定制会员：管理员可按用户覆盖额度、限速、有效期（含永久）
- 高风险操作邮箱验证码

**管理后台**
- 流量监控（平滑折线图、上下行、峰值/均值）
- 用户管理（积分、会员、限速、定制额度、重置密码、删除）
- 隧道管理、节点管理、兑换码管理
- HTTPS 证书信息（如配置了证书路径）

**桌面启动器**
- 登录、隧道卡片网格、启动/停止/删除
- 每日签到、创建隧道
- 节点页、运行日志、累计流量
- 自动下载 frpc

## 架构

```
浏览器 / 桌面启动器
        │ HTTP
        ▼
   CloudFRP 面板 (Flask, :3592)
        │ 管理 API / 生成配置
        ▼
   捐赠节点 frps (:7000) ◀── frpc ── 用户内网服务
        ▲
        └── cloudfrp-node（心跳 / 流量上报）
```

## 快速开始

### 1. 安装依赖

```bash
cd webpanel
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

### 2. 配置

```bash
cp .env.example .env
# 编辑 .env：至少修改 SECRET_KEY、DEFAULT_AUTH_TOKEN、SMTP_*
```

### 3. 启动

```bash
python server.py          # 开发模式
# 或
python -m waitress --listen=0.0.0.0:3592 --threads=8 server:app
```

访问 `http://服务器IP:3592/`。

> 首次启动会自动创建管理员 `admin / yunwang`，**请登录后立即修改密码**，并在 `.env` 中设置随机 `SECRET_KEY`。

### 4. 一键部署（Linux）

```bash
sudo ./deploy.sh
```

自动安装系统依赖、创建 venv、生成 `.env`、执行迁移、创建随机密码管理员、注册 systemd 开机自启。

## 配置项

| 变量 | 说明 |
|---|---|
| `SECRET_KEY` | Flask 会话密钥，生产环境必须随机 |
| `DEFAULT_AUTH_TOKEN` | FRP 认证 Token |
| `PANEL_HOST` / `PANEL_PORT` | 面板监听地址 / 端口 |
| `USE_MYSQL` + `DB_*` | 使用 MySQL 时配置 |
| `SMTP_HOST/PORT/USER/PASS/FROM` | 邮件服务，QQ 邮箱使用授权码作为密码 |

## 捐赠节点

1. 管理员后台 → 节点管理，审核节点、填写描述和允许端口范围
2. 节点服务器执行面板「捐赠节点」页生成的一键脚本
3. 脚本安装 frps + cloudfrp-node，注册 systemd 开机自启
4. 节点每 10 秒心跳，面板据此显示在线状态

## 桌面启动器

```bash
cd client-rust
cargo build --release
# 产物：target/release/cloudfrp-launcher
```

Windows 产物为 `cloudfrp-launcher.exe`，用户无需安装 Rust 或 Python。

## 安全建议

- 修改默认管理员密码，设置随机 `SECRET_KEY`
- 通过 Nginx / Caddy 配置 HTTPS（面板本身监听 HTTP）
- 限制管理后台访问来源
- 定期备份 `webpanel/frp_panel.db`（或 MySQL）
- 节点 Token 与面板 `DEFAULT_AUTH_TOKEN` 保持一致，不要公开

## 目录结构

```
webpanel/            面板后端、模板、静态资源
  app/api/           JSON API（用户/隧道/节点/积分/验证码/邮件）
  app/services/      业务逻辑与数据层
  templates/         Jinja 页面
  tests/             冒烟测试（需要对运行中的面板执行）
client-rust/         Rust 桌面启动器
deploy.sh            Linux 一键部署
start.sh             手动启动 / systemd 管理
```

## 测试

面板运行后：

```bash
cd webpanel
python tests/smoke.py
python tests/donation.py
python tests/tunnel_status.py
```

## License

Apache License 2.0，见 [LICENSE](LICENSE)。
