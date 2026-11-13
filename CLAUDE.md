# CLAUDE.md — iOS App 工厂

用户在手机上的 Claude Code 里描述需求，你负责把它变成能装到他 iPhone 上的 App。
**你写代码并推送 → GitHub Actions（`xcode-27` runner，Xcode 27.1 / iOS 27 SDK）编译、签名、上传 TestFlight → 用户在 TestFlight 里点安装。**
用户说中文，回复也用中文，简短。

## 你的环境
- 你跑在 Linux 上，**没有 Xcode、没有 Swift 编译器、没有模拟器**。唯一的编译器是 CI。
- 所以：写保守、确定能编过的 Swift；推送后必须盯 CI 结果（见下方闭环），不能推完就说"做好了"。

## 仓库里有多个 App
每个 App 一个目录：`apps/<name>/`（`app.env`、`project.yml`、`App/Sources`、`App/Resources`）。
- `apps/argent` —— 银盐（胶片相机）。**目前暂停（SKIP_CI=1）**，Bundle ID 被 echo 借用。
- `apps/starmall` —— 星光百货（女性向放置经营游戏）。**目前暂停（SKIP_CI=1）**：它的 BUNDLE_ID 还是借用的 `com.deffisoan.appfactory`（归相机用）。用户注册好 `com.deffisoan.starmall` 后：改回 starmall 的 BUNDLE_ID，删掉它的 SKIP_CI。
- `apps/echo` —— 拾言（Apple Watch + iPhone 语音记忆助手）。含 watchOS 目标：`Watch/`（手表源码）、`Shared/`（两端共用）。**目前借用相机的 Bundle ID `com.deffisoan.appfactory`**（本应是 `com.deffisoan.echonote`），手表为 `.watchkitapp` 后缀。同一时间只能有一个 App 用这个 ID 构建。云端模型密钥只由用户在 App 设置里填，绝不写进仓库。设计与限制见 `apps/echo/README.md`。首页是对话助理（`App/Sources/Agent/`：Pi 式智能体循环 + DeepSeek 搜索/读网页/看图 + MCP 连接器 + 主动提醒）；截图用 `-tab 3`。只做用户主动开始、状态可见的录音，不做隐藏/后台自启录音。
`app.env` 里有 `SKIP_CI=1` 的 App 不会被构建。
push 时 CI 只构建改动过的 App（改了 `fastlane/`、`.github/` 则全部构建）。先确认用户说的是哪个 App，只改那个目录。

## 每个需求的标准流程
1. 读懂需求。只有在需求真的有歧义、且猜错代价大时才问一个问题；否则按最合理的理解直接做，并在回复里说明你的理解。
2. 在 `apps/<name>/App/Sources/` 里实现（可以建子目录，XcodeGen 会自动收录）。
3. 如果改了 App 名字/图标/权限等，同步改该 App 目录下的 `app.env` / `project.yml` / `App/Resources/`。
4. commit 并 push（当前分支即可，`main` 和 `claude/**` 分支都会触发上传）。
5. **CI 闭环**（必须做）：
   ```bash
   gh run list --branch "$(git branch --show-current)" --limit 1     # 拿到 run id
   gh run watch <id> --exit-status                                    # 等结果（约 10–20 分钟）
   gh run view <id> --log-failed | grep -E "error:|❌|Error" | head -50 # 失败时看错误
   ```
   失败就修、再推、再盯，直到成功；连续 5 次失败就停下，把错误原文和你的判断告诉用户。
   如果 `gh` 不可用（云端会话里 GH_TOKEN 无效，且代理拦截写类 Actions API）：仓库是公开的，可以不带认证直接读：
   ```bash
   R=martynZheng/ios-app-factory; SHA=$(git rev-parse HEAD)
   # 状态（check-run id 就是 job id；会有 detect 和 testflight (<app>) 几个 job）；status=queued/in_progress/completed，conclusion=success/failure
   curl -sS https://api.github.com/repos/$R/commits/$SHA/check-runs | python3 -c "import json,sys;[print(c['id'],c['name'],c['status'],c['conclusion']) for c in json.load(sys.stdin)['check_runs']]"
   # 失败时拉完整日志找错误
   curl -sSL https://api.github.com/repos/$R/actions/jobs/<job_id>/logs | grep -nE "error:|❌|\[!\]" | head -40
   ```
   每隔 2–3 分钟轮询一次（sleep），macOS runner 排队可能要几分钟。仍拿不到错误时，请用户把 Actions 页面的红色报错截图发给你。
6. 成功后告诉用户：做了什么、版本号（如 `1.0.0 (12.1)`），"苹果处理 5–15 分钟后 TestFlight 会推送更新"。

## 界面自查（改 UI 后必须做）
App 目录下有 `preview.sh` 时，CI 的 `preview` job 会在模拟器里以演示数据（启动参数 `-demo 1 -tab N`）启动并截图，强推到 `ci-screenshots` 分支：
```bash
git fetch -q origin ci-screenshots && git --work-tree=/tmp/shots checkout -f FETCH_HEAD -- . ; ls /tmp/shots/<app>   # 再用 Read 看 PNG
```
看图确认排版、截断、深色模式没问题再告诉用户。演示数据在 `Demo.swift`，新增界面时同步加演示数据和截图。

## 目标设备：iPhone Duo（折叠屏）
- 外屏 5.4″ 竖向约 466×678pt（compact 宽度，比普通 iPhone 更宽更矮）；内屏 7.6″ 展开后横向约 890×626pt（regular × regular）。
- 布局只看可用尺寸 / size class，不要用 `UIScreen.main`、不要假设设备方向；横竖布局都要能用。
- 必须用 Xcode 27.1+ SDK 编译，否则内屏不会铺满。

## Swift / SwiftUI 规则（降低盲写编译失败率）
- 最低系统 iOS 17（`app.env` 里的 `IOS_DEPLOYMENT_TARGET`）。只用 iOS 17 已有的 API；用到 iOS 18+/26 的 API 必须 `if #available` 包起来。
- Swift 语言模式 5（`SWIFT_VERSION: "5.0"`），不要开严格并发。
- 首选：SwiftUI、`@Observable`（Observation）、`NavigationStack`、SwiftData 或 `@AppStorage`/JSON 文件做本地持久化、`async/await`。
- 大 `body` 拆成小的子 View / 计算属性，避免 "the compiler is unable to type-check this expression in reasonable time"。
- 不确定的 API 签名宁可用更基础的写法。不要凭印象调用你不确定存在的修饰符。
- 默认不引入第三方库。确实需要时用 SPM，在 `project.yml` 顶层加 `packages:` 并在 target 的 `dependencies:` 里引用。
- 需要联网的 App：只用 `URLSession`；HTTP（非 HTTPS）需要在 Info.plist 里加 ATS 例外。

## 权限与能力（漏了会闪退或被拒）
- 用到相机/相册/定位/麦克风/通讯录/通知/健康等，必须在 `project.yml` → `targets.App.info.properties` 里加对应的 `NS...UsageDescription`（中文说明）。
- 推送、iCloud、HealthKit、App Groups、Sign in with Apple 等需要 entitlements + App ID 开 capability：
  在 `project.yml` 的 target 下加 `entitlements:`，自动签名一般会替你开通；如果 CI 报 provisioning/capability 错误，告诉用户去 developer.apple.com 给这个 Identifier 勾上对应能力。

## 别碰 / 别做
- 不要提交 `.xcodeproj`、`Info.plist`（都是 CI 生成的，已 gitignore）。
- 不要把任何密钥、`.p8`、Team ID 写进仓库。它们只在 GitHub Secrets 里。
- `fastlane/` 和 `.github/workflows/` 只在流水线本身坏了时才改。
- 只改 `MARKETING_VERSION` 当用户要求"发新版本号"；构建号由 CI 自动生成（`run_number.run_attempt`），不要手动改。

## 新建一个 App
1. 让用户先在苹果后台完成：developer.apple.com 注册新 Bundle ID（Explicit）→ App Store Connect 用它新建 App →
   该 App 的 TestFlight 建内部测试组、勾「自动分发」、把自己加进去。GitHub 那边不需要任何操作（Secrets 共用）。
2. 复制一个现有 App 目录到 `apps/<新名字>/`，改 `app.env` 的 `APP_NAME` / `DISPLAY_NAME` / `BUNDLE_ID`，
   `MARKETING_VERSION` 重置为 `1.0.0`，按需改 `project.yml` 的 Info.plist 键（权限说明等），替换图标和源码。

## 仓库结构
```
apps/<name>/app.env          App 名称 / Bundle ID / 版本 / 最低系统（单一事实来源）
apps/<name>/project.yml      XcodeGen 工程描述
apps/<name>/App/Sources/     Swift 代码
apps/<name>/App/Resources/   图标（1024×1024 无透明 PNG）、主题色
fastlane/Fastfile            archive（不签名）→ 云端分发签名导出 → 上传 TestFlight（所有 App 共用）
.github/workflows/testflight.yml  CI：detect 改动的 App → 矩阵构建
SETUP.md                     用户一次性配置步骤
```
