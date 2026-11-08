# 一次性配置（约 30 分钟，之后再也不用碰）

做完这 7 步，以后只需要在手机的 Claude Code 里说需求。

## 1. 苹果开发者账号 & Team ID
- 需要已加入 Apple Developer Program（个人 ¥688/年）。免费账号不能用 TestFlight。
- 打开 https://developer.apple.com/account → **会员资格详细信息（Membership details）** → 记下 **Team ID**（10 位字母数字）。

## 2. 注册 Bundle ID
developer.apple.com → **Certificates, IDs & Profiles** → **Identifiers** → **+**
→ App IDs → App → Description 随便填 → **Explicit**，填：

```
com.deffisoan.appfactory
```
（必须和仓库 `apps/<name>/app.env` 里的 `BUNDLE_ID` 一致）→ Continue → Register。

## 3. 在 App Store Connect 建 App
https://appstoreconnect.apple.com → **App** → **+ 新建 App**
- 平台：iOS
- 名称：App Store 全球唯一，起个不容易重名的，例如「汯毅的AI工厂」（只是商店名，不会上架；手机桌面显示的名字由 `app.env` 的 `DISPLAY_NAME` 决定）
- 主要语言：简体中文
- 套装 ID：选第 2 步注册的 `com.deffisoan.appfactory`
- SKU：随便，例如 `appfactory`

## 4. 生成 App Store Connect API Key
App Store Connect → **用户和访问（Users and Access）** → **集成（Integrations）** → **App Store Connect API** → **团队密钥** → **+**
- 名称：`github-ci`
- 访问权限：**管理（Admin）** ← 必须是 Admin，云端自动签名需要它来创建分发证书
- 生成后记下 **Key ID**（这一行上）和页面顶部的 **Issuer ID**
- **下载 .p8 文件**（只能下载一次，丢了只能重建）

## 5. TestFlight 内部测试组
- 在第 3 步的 App 里 → **TestFlight** → 「内部测试」旁的 **+** → 建组（如「我」）→ 勾选 **自动分发（Enable automatic distribution）** → 把自己的 Apple ID 加进去
- iPhone 上从 App Store 装 **TestFlight**，用同一个 Apple ID 登录

## 6. 填 GitHub Secrets
仓库 → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**，逐个添加：

| Name | 值 |
|---|---|
| `APPLE_TEAM_ID` | 第 1 步的 Team ID |
| `ASC_KEY_ID` | 第 4 步的 Key ID |
| `ASC_ISSUER_ID` | 第 4 步的 Issuer ID（UUID 格式） |
| `ASC_KEY_P8` | .p8 文件的**全部内容**（从 `-----BEGIN PRIVATE KEY-----` 到 `-----END PRIVATE KEY-----`，含这两行）。也可以填它的 base64 |

> 手机上看 .p8 内容不方便的话，这一步用电脑做：用文本编辑器打开 .p8 复制粘贴。

## 7. 跑第一次
仓库 → **Actions** → **Build & upload to TestFlight** → **Run workflow**。
10–20 分钟后变绿；再等 5–15 分钟苹果处理完，TestFlight 会推送「AI工厂」可安装。打开看到「流水线已跑通」就大功告成。

---

## 之后怎么用
手机 Claude Code → 选这个仓库 → 直接说需求，例如：

> 做一个记账 App：首页按月显示支出总额和分类饼图，右上角加号记一笔（金额、分类、备注、日期），数据存本地。

Claude 会写代码、推送、盯着构建，失败了自己修，成功了告诉你去 TestFlight 装。

## 常见报错
| 报错关键词 | 原因 / 处理 |
|---|---|
| `缺少 GitHub Secrets` | 第 6 步漏填 |
| `No profiles for 'com.deffisoan.appfactory'` / `Cloud signing permission error` | API Key 不是 Admin，或第 2 步 Bundle ID 没注册 |
| `Could not find app ... on App Store Connect` / 上传报找不到 App | 第 3 步没建 App 或套装 ID 选错 |
| `The bundle version must be higher` | 构建号重复，重新 Run workflow 即可（构建号自动递增） |
| TestFlight 里看不到新版本 | 等苹果处理；或第 5 步没开「自动分发」，手动在测试组里添加该构建 |

## 费用提醒
- 仓库建议设为 **Public**：公开仓库的 GitHub Actions macOS 分钟数免费。私有仓库 macOS 按 10 倍计费，免费额度大约只够 10 次构建。
- TestFlight 构建 90 天后过期，届时让 Claude 随便推一次即可续命。
