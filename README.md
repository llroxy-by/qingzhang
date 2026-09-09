# 轻账（qingzhang）

一款 **懒人友好的个人记账 App**：不要求逐笔记账，以 **账户余额快照** 为核心 —— 随手记下各账户余额，App 自动计算总资产、变动趋势、结余构成；账单流水（支付宝 / 微信 / 银行）作为补充，用于消费分类与"花钱大头"分析。

- Flutter（Android 为主，代码同时支持 iOS / Web）
- 数据保存在本机 SQLite；可选自建服务器做**多账号云端同步**
- 同步模型：全量 push → 服务器按 `updated_at` last-write-wins 合并 → 各端收敛一致
- 附带零依赖 Node 服务器（内置 `http` + `node:sqlite`）与只读 Web 报表端

> [!IMPORTANT]
> ## 📱 可以纯本地使用，不需要服务器！
>
> **直接下载 Release 里的 APK 安装即可记账**（导入账单、自动分类、消费分析、旅程全部本地完成，数据只存在你手机里）。
> 服务器只是**可选的云同步功能**——只有你想多设备同步、或让家人朋友 Web 端远程查看时，才需要按下面的「服务器部署指南」自建一个。
> 开源版 App 没填服务器地址前，就是个完完全全的本地记账工具。

## 功能

| 模块 | 说明 |
|---|---|
| 余额快照 | 资金构成（基金/银行卡/零钱通…）自定义；总资产 / 变动 / 趋势 |
| 账单导入 | CSV / XLSX / TXT 自动识别平台与表头（支付宝、微信）；**PDF**：招行交易流水、工行借记账户历史明细；**加密 ZIP**（银行邮件账单，传统 ZipCrypto）输密码解压后解析 |
| 邮箱拉取 | 服务器连接 QQ 邮箱 IMAP，自动列出带 zip/pdf 附件的银行账单邮件（可选功能，需邮箱授权码） |
| 分类 | 内置关键词规则 + 自定义"关键词 → 分类"，导入自动分类；其他类一键重分类 |
| 消费分析 | 支出/收入/存钱统计、分类"花钱大头"、单笔消费 TOP、按旅程归集（区间内流水自动包含，可手动追加区间外的机票、AA 等） |
| 旅程 | 把一段旅途的消费归到一起统计 |
| 随手记 | 不导流水时，刷卡/大额消费随手记一笔，同样参与消费分析 |
| 云端同步 | 昵称 + 密码注册/登录（scrypt 加盐哈希，登录 token 鉴权）；写操作需登录，Web 只读免登录 |
| 离线可用 | 所有功能本地优先，点"立即同步"才联网 |

## 快速开始

### 1. 手机 App

```bash
flutter pub get
flutter run          # 或 flutter build apk --release
```

> 开源版默认不带服务器地址：安装后到 **设置 → 账号与同步 → 点「服务器地址」** 填写自己部署的服务器（见下）。

### 2. 服务器部署指南（云端同步 + Web）

服务端是**零依赖 Node 应用**（仅用内置 `http` + `node:sqlite`），Node.js ≥ 22 即可，不需要 npm install（仅"邮箱账单"可选功能需要装一个 imapflow）。

**① 准备 Node.js**

- Windows：下载 node-v22 win-x64 zip，解压到 `E:\server\node-v22.x` 之类目录
- macOS/Linux：官网 pkg 或 `nvm install 22`
- 检查：`node -v` 输出 v22+

**② 启动服务**

```bash
cd server
node server.js          # 默认监听 8080，改端口用环境变量：PORT=9090 node server.js
```

启动日志会打印监听地址与数据目录；数据存在 `server/data/qingzhang.db`（SQLite 单文件，备份=拷走这个文件）。

可选邮箱账单模块（拉 QQ 邮箱里的银行账单附件）：

```bash
cd server && npm install imapflow
# 重启服务后在 App 导入页「从邮箱获取」填写 QQ 邮箱 + 授权码即可
# （授权码保存在服务器本地 data/mail_config.json）
```

自测：服务起来后另开终端跑 `node test.js`（端到端 20 项：注册/登录/同步/权限隔离）。

**③ 手机 App 连上它**

App 端两种情况：

- 自己构建 App：`flutter build apk --release --dart-define=QINGZHANG_SERVER=http://你的服务器:8080`（内置地址，免填）
- 使用开源默认包：安装后 设置 → 账号与同步 → 点「服务器地址」填入 `http://你的服务器:8080`

**④ 让公网能访问（手机在外面也能同步/看 Web）**

服务器要能被公网访问，任选：

- 有公网 IP 的 VPS：直接部署在上面，安全组放行端口
- 家用/公司内网：用 frp / ngrok / Tailscale Funnel 之类把 8080 暴露出去。
  例（frp）：`frpc.ini` 里 `remote_port = 8080` + `server_addr` 指向你的 frps；外网地址形如 `http://xxx.ofalias.com:8080`。填 App 的服务器地址用这个公网地址。
- ⚠️ 国内云服务器直连公网需要 ICP 备案（未备案的 IP 访问 80/8080 可能被拦截），建议放境外节点或用 HTTPS 域名。

**⑤ （可选）注册成 Windows 开机自启服务**

```powershell
# 用 NSSM（https://nssm.cc）把 node server.js 注册为服务
nssm install qingzhang "E:\server\node.exe" "E:\server\server.js"
nssm set qingzhang AppDirectory E:\server
nssm start qingzhang
```

**⑥ Web 只读端**

```bash
flutter build web --target=lib/main_web.dart
# 把 build/web/ 下所有文件拷到服务器 server/web/（覆盖），重启服务即可
```

之后访问 `http://你的服务器:8080/` 就是免登录只读报表（总资产/趋势/分类大头/旅程/流水）。

### API 摘要

```
POST /api/user/register   { nickname, password }     注册（老账号绑密码兼容）
POST /api/user/login      { nickname, password }     登录 → { user, token }
GET  /api/users                                       用户列表（免登录只读）
GET  /api/data/:uid                                   拉数据（免登录只读）
POST /api/data/:uid      Bearer token                 全量合并同步（last-write-wins）
POST /api/reset/:uid     Bearer token                 清空自己的业务数据
GET  /api/mail/list|config  Bearer token              邮箱账单（需 imapflow）
```

## 隐私说明

- 账号密码用 scrypt 加盐哈希存储，登录换取随机 token；同步/清空等写操作必须携带 token
- Web 只读端**免登录**可查看（方便家人/自己远程瞄一眼）——注意：别把服务器地址发给不相关的人
- 导入解析全部在手机本地完成；PDF/附件不上传服务器（仅可选"邮箱拉取"时服务器代收邮件）

## 技术栈

Flutter / Dart · sqflite · Node.js（零依赖服务端）· SQLite · pdfium（pdfrx_engine 本地补丁，见 `pubspec.yaml` dependency_overrides）

## 目录

```
lib/              Flutter 端（App 与 Web 共用业务代码）
  main.dart         App 入口
  main_web.dart    Web 只读端入口
  db/ models/ services/ pages/ widgets/ utils/
server/           Node 服务器（server.js + mail.js 邮箱模块 + test.js 端到端测试）
test/             Flutter 单元测试（分类/解析器/加密 zip）
```

## License

MIT © llroxy
