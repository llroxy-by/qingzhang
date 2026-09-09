# 轻账（qingzhang）

一款 **懒人友好的个人记账 App**：不要求逐笔记账，以 **账户余额快照** 为核心 —— 随手记下各账户余额，App 自动计算总资产、变动趋势、结余构成；账单流水（支付宝 / 微信 / 银行）作为补充，用于消费分类与"花钱大头"分析。

- Flutter（Android 为主，代码同时支持 iOS / Web）
- 数据保存在本机 SQLite；可选自建服务器做**多账号云端同步**
- 同步模型：全量 push → 服务器按 `updated_at` last-write-wins 合并 → 各端收敛一致
- 附带零依赖 Node 服务器（内置 `http` + `node:sqlite`）与只读 Web 报表端

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

### 2. 服务器（可选，云端同步 + Web）

零依赖 Node 服务器，仅需 Node.js ≥ 22（内置 SQLite）：

```bash
cd server
node server.js        # 默认 8080，环境变量 PORT 可改
```

服务器同时托管：
- REST API：注册/登录/同步/清空/邮件（见下方 API 摘要）
- Web 只读端：把 `flutter build web --target=lib/main_web.dart` 产物拷入 `server/web/` 后同端口访问

公网暴露：可用 frp / ngrok 等 TCP 隧道把 8080 映射到公网（国内服务器直连需备案，建议境外节点）。

**邮箱账单功能**（可选）：`npm install imapflow` 后服务器自动启用；在 App 的 导入页 → 从邮箱获取 中填写 QQ 邮箱与授权码（授权码仅存服务器本地 `server/data/mail_config.json`，用于 IMAP 收信）。

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
