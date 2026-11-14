// 在一个“空”的 JS 环境里（只有语言本身，没有 Node/浏览器接口，接近 iOS 的 JavaScriptCore）加载打包结果，
// 用真实的 DeepSeek 接口跑一轮带工具的对话。用法：DEEPSEEK_API_KEY=sk-... node test.mjs
import vm from "node:vm";
import fs from "node:fs";

const key = process.env.DEEPSEEK_API_KEY;
if (!key) throw new Error("set DEEPSEEK_API_KEY");
const code = fs.readFileSync(new URL("../App/Resources/pi-agent.jsbundle", import.meta.url), "utf8");
const sandbox = {};
vm.createContext(sandbox);
const controllers = new Map();
let resolveEnd;
const ended = new Promise((r) => (resolveEnd = r));
const log = [];

sandbox.__pi_event = (runId, json) => {
	const e = JSON.parse(json);
	if (e.type !== "text") console.log("event", json.slice(0, 300));
	log.push(e);
	if (process.env.ABORT === "1" && e.type === "tool_start") sandbox.Pi.abort("r1");
	if (e.type === "end") resolveEnd(e);
};
sandbox.__pi_cancel = (id) => controllers.get(id)?.abort();
sandbox.__pi_chat = (id, body) => {
	const c = new AbortController();
	controllers.set(id, c);
	(async () => {
		try {
			const res = await fetch("https://api.deepseek.com/chat/completions", {
				method: "POST", signal: c.signal,
				headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` }, body,
			});
			if (!res.ok) return sandbox.Pi.chatEnd(id, `HTTP ${res.status} ${(await res.text()).slice(0, 200)}`);
			let buffer = "";
			const decoder = new TextDecoder();
			for await (const part of res.body) {
				buffer += decoder.decode(part, { stream: true });
				let i;
				while ((i = buffer.indexOf("\n")) >= 0) {
					const line = buffer.slice(0, i).trim();
					buffer = buffer.slice(i + 1);
					if (line.startsWith("data:")) {
						const payload = line.slice(5).trim();
						if (payload !== "[DONE]") sandbox.Pi.chunk(id, payload);
					}
				}
			}
			sandbox.Pi.chatEnd(id, "");
		} catch (error) {
			sandbox.Pi.chatEnd(id, String(error.message));
		}
	})();
};
sandbox.__pi_tool = (callId, name, args) => {
	console.log("tool", name, args);
	const a = JSON.parse(args);
	let result = { content: "未知工具", isError: true };
	if (name === "get_time") result = { content: `${a.city} 现在是 21:05` };
	if (name === "suggest_replies") result = { content: "好", terminate: true };
	setTimeout(() => sandbox.Pi.toolDone(callId, JSON.stringify(result)), 20);
};

vm.runInContext(code, sandbox);
console.log("loaded", vm.runInContext("Pi.version", sandbox), "globals:", Object.keys(sandbox).join(","));
const str = { type: "string" };
sandbox.Pi.start("r1", JSON.stringify({
	system: "你是一个助理。回答简短。回答完在同一轮最后调用 suggest_replies 给两个后续选项。",
	model: "deepseek-flash",
	thinking: process.env.THINK === "1",
	tools: [
		{ name: "get_time", description: "查一个城市现在的时间", parameters: { type: "object", properties: { city: str }, required: ["city"] } },
		{ name: "suggest_replies", description: "给后续选项", parameters: { type: "object", properties: { options: { type: "array", items: str } }, required: ["options"] } },
	],
	history: [{ role: "user", text: "你好" }, { role: "assistant", text: "你好，有什么事？" }],
	prompt: { text: "上海和东京现在分别几点？" },
}));
const end = await ended;
const texts = log.filter((e) => e.type === "assistant").map((e) => e.text);
console.log("RESULT", JSON.stringify(end), "| partial events:", log.filter((e) => e.type === "text").length, "| texts:", JSON.stringify(texts));
if (end.reason !== (process.env.ABORT === "1" ? "aborted" : "stop")) process.exit(1);
