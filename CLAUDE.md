# CLAUDE.md — iOS App 工厂

用户在手机上的 Claude Code 里描述需求，你负责把它变成能装到他 iPhone 上的 App。
**你写代码并推送 → GitHub Actions（macOS 26 + Xcode 26）编译、签名、上传 TestFlight → 用户在 TestFlight 里点安装。**
用户说中文，回复也用中文，简短。

## 你的环境
- 你跑在 Linux 上，**没有 Xcode、没有 Swift 编译器、没有模拟器**。唯一的编译器是 CI。
- 所以：写保守、确定能编过的 Swift；推送后必须盯 CI 结果（见下方闭环），不能推完就说"做好了"。

## 每个需求的标准流程
1. 读懂需求。只有在需求真的有歧义、且猜错代价大时才问一个问题；否则按最合理的理解直接做，并在回复里说明你的理解。
2. 在 `App/Sources/` 里实现（可以整个替换占位的 `ContentView.swift`，可以建子目录，XcodeGen 会自动收录）。
3. 如果改了 App 名字/图标/权限等，同步改 `app.env` / `project.yml` / `App/Resources/`。
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
   # 状态（check-run id 就是 job id）；status=queued/in_progress/completed，conclusion=success/failure
   curl -sS https://api.github.com/repos/$R/commits/$SHA/check-runs | python3 -c "import json,sys;[print(c['id'],c['status'],c['conclusion']) for c in json.load(sys.stdin)['check_runs']]"
   # 失败时拉完整日志找错误
   curl -sSL https://api.github.com/repos/$R/actions/jobs/<job_id>/logs | grep -nE "error:|❌|\[!\]" | head -40
   ```
   每隔 2–3 分钟轮询一次（sleep），macOS runner 排队可能要几分钟。仍拿不到错误时，请用户把 Actions 页面的红色报错截图发给你。
6. 成功后告诉用户：做了什么、版本号（如 `1.0.0 (12.1)`），"苹果处理 5–15 分钟后 TestFlight 会推送更新"。

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

## 换一个全新的 App
`BUNDLE_ID` 是 App 的身份。用户想做"另一个 App"而不是改当前这个时：
1. 让用户先完成：developer.apple.com 注册新 Identifier → App Store Connect 用它新建 App → 把自己加进内部测试组（见 SETUP.md 第 2、5 步）。
2. 然后改 `app.env` 里的 `APP_NAME` / `DISPLAY_NAME` / `BUNDLE_ID`，必要时把 `MARKETING_VERSION` 重置为 `1.0.0`。
更干净的做法是用户 fork/复制这个仓库，一个仓库一个 App。

## 仓库结构
```
app.env                      App 名称 / Bundle ID / 版本 / 最低系统（单一事实来源）
project.yml                  XcodeGen 工程描述
App/Sources/                 Swift 代码
App/Resources/Assets.xcassets 图标（1024×1024 无透明 PNG）、主题色
fastlane/Fastfile            archive → 签名 → 上传 TestFlight
.github/workflows/testflight.yml  CI
SETUP.md                     用户一次性配置步骤
```
