# 轻账 云服务器端

零依赖：仅使用 Node.js 内置模块（`http` + `node:sqlite`），不需要 `npm install`。

## 本地开发

```bash
# 需要 Node ≥ 22.5（本机已装 ~/development/node-v22.14.0-darwin-arm64）
node server.js          # 默认端口 8080（PORT 环境变量可改）
node test.js            # 冒烟测试（需先启动 server.js，默认连 18080）
```

## 部署到 Windows 服务器（maserver）

1. 把 `server/` 整个目录拷到远程 `E:\maserver`（保留 `web/`、`data/` 子目录）
2. 远程安装 Node（Windows x64 zip 版解压即用，无需安装器）：
   - 下载 `node-v22.14.0-win-x64.zip`，解压到 `E:\maserver\node`
3. 启动测试：`E:\maserver\node\node.exe E:\maserver\server.js`（端口默认 8080）
4. 注册成 Windows 服务（NSSM）：
   ```
   nssm install qingzhang "E:\maserver\node\node.exe" "E:\maserver\server.js"
   nssm set qingzhang AppDirectory E:\maserver
   nssm start qingzhang
   ```
5. Web UI 就绪后：`flutter build web --release` 把 `build/web/` 产物拷到 `E:\maserver\web\`

## API

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/user/register` | body `{nickname}`；同名用户幂等返回已存在账号 |
| GET | `/api/users` | 所有用户（Web 端切换查看用） |
| GET | `/api/data/:userId` | 拉取该用户全量数据 |
| POST | `/api/data/:userId` | 推送全量，服务端按 `updated_at` last-write-wins 合并，返回合并结果 |

数据表：`users` / `accounts` / `snapshots` / `snapshot_entries` / `txns` / `trips`。
所有业务行用字符串 uuid 作 id，行内引用（entry→account/snapshot、txn→account/trip）也是 uuid。
软删除：`deleted=1` 的 tombstone 行会保留并同步，客户端查询过滤 `deleted=0`。
无鉴权（熟人模式，按用户需求）；暴露公网时建议 frp 配 HTTPS。
