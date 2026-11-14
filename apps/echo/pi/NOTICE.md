# 打包进 App 的第三方代码

`../App/Resources/pi-agent.jsbundle` 由本目录用 esbuild 生成，包含：

- `@earendil-works/pi-agent-core` 1.5.2 —— Pi 的智能体内核（MIT，Mario Zechner），源码 https://github.com/earendil-works/pi （packages/agent）
- `@earendil-works/pi-ai` 1.5.2 —— 只用到事件流、对话记录和工具参数校验这几个小模块（MIT，Mario Zechner）
- `@earendil-works/pi-schema` 1.5.2 —— JSON Schema 校验（MIT，Earendil Works；它自带的第三方声明见 `THIRD_PARTY_NOTICES-pi-schema`）
- `host.js` —— 我们自己写的桥接层

没有带任何模型厂商的 SDK：请求由 App（Swift）自己发。

## 重新生成

```bash
cd apps/echo/pi && npm install && npm run build
DEEPSEEK_API_KEY=sk-... npm test     # 在接近 iOS JavaScriptCore 的空环境里用真实接口跑一轮带工具的对话
```

升级 Pi：改 `package.json` 里的版本号，重新 build、test，把新的 `pi-agent.jsbundle` 一起提交。CI 不跑 Node，所以打包结果必须提交进仓库。
