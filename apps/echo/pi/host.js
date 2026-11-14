// 宿主桥：让原版 Pi agent core（@earendil-works/pi-agent-core，MIT）跑在 iOS 的 JavaScriptCore 里。
// Pi 负责整个智能体循环（轮次、工具调度、参数校验、事件、终止、中断）；
// 宿主（Swift）只提供三样东西：发一个流式 HTTP 请求、执行一个工具、接收事件。
//
// 宿主要在 globalThis 上提供：
//   __pi_chat(requestId, bodyJSON)        发起 /chat/completions 流式请求
//   __pi_cancel(requestId)                取消请求
//   __pi_tool(callId, name, argsJSON)     执行工具
//   __pi_event(runId, eventJSON)          接收事件
// 然后回调：
//   Pi.chunk(requestId, payload)          一条 SSE data
//   Pi.chatEnd(requestId, error)          请求结束（error 为空串表示成功）
//   Pi.toolDone(callId, resultJSON)       工具结果 {content, isError, terminate}

// ---- JavaScriptCore 里没有的几样运行时接口 ----
const g = globalThis;
if (typeof g.performance === "undefined") g.performance = { now: () => Date.now() };
if (typeof g.structuredClone === "undefined") g.structuredClone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
if (typeof g.AbortController === "undefined") {
	class AbortSignal {
		constructor() {
			this.aborted = false;
			this.reason = undefined;
			this.onabort = null;
			this._listeners = [];
		}
		addEventListener(type, fn) {
			if (type === "abort") this._listeners.push(fn);
		}
		removeEventListener(type, fn) {
			this._listeners = this._listeners.filter((l) => l !== fn);
		}
		throwIfAborted() {
			if (this.aborted) throw this.reason;
		}
	}
	class AbortController {
		constructor() {
			this.signal = new AbortSignal();
		}
		abort(reason) {
			const s = this.signal;
			if (s.aborted) return;
			s.aborted = true;
			s.reason = reason ?? new Error("aborted");
			const event = { type: "abort", target: s };
			if (typeof s.onabort === "function") s.onabort(event);
			for (const l of s._listeners.slice()) l(event);
		}
	}
	g.AbortSignal = AbortSignal;
	g.AbortController = AbortController;
}

import { Agent } from "@earendil-works/pi-agent-core";
import { createAssistantMessageEventStream, getCurrentSystemPrompt, getCurrentTools } from "@earendil-works/pi-ai";

const FILE_MARK = /⟦file:([^⟧]+)⟧/g;
const requests = new Map();
const toolCalls = new Map();
const runs = new Map();
let counter = 0;

function emptyUsage() {
	return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
}

function textOf(content) {
	if (typeof content === "string") return content;
	return (content || []).filter((b) => b.type === "text").map((b) => b.text).join("\n");
}

/** Pi 的消息 → OpenAI 兼容的 messages。 */
function toWire(messages) {
	const wire = [{ role: "system", content: getCurrentSystemPrompt(messages) }];
	for (const m of messages) {
		if (m.role === "user") {
			const blocks = [];
			let text = textOf(m.content);
			const ids = [];
			text = text.replace(FILE_MARK, (_, id) => {
				ids.push(id);
				return "";
			});
			for (const id of ids) blocks.push({ type: "file", file_id: id });
			if (Array.isArray(m.content)) {
				for (const b of m.content) {
					if (b.type === "image") blocks.push({ type: "image_url", image_url: { url: `data:${b.mimeType};base64,${b.data}` } });
				}
			}
			if (blocks.length === 0) {
				wire.push({ role: "user", content: text });
			} else {
				blocks.push({ type: "text", text: text.trim() || "看看这个。" });
				wire.push({ role: "user", content: blocks });
			}
		} else if (m.role === "assistant") {
			if (m.stopReason === "error" || m.stopReason === "aborted") continue;
			const out = { role: "assistant", content: m.content.filter((b) => b.type === "text").map((b) => b.text).join("") };
			const thinking = m.content.filter((b) => b.type === "thinking");
			// DeepSeek 思考模式：带工具的多轮请求必须把思维链原样传回
			if (thinking.length > 0) out.reasoning_content = thinking.map((b) => b.thinking).join("");
			const calls = m.content.filter((b) => b.type === "toolCall");
			if (calls.length > 0) {
				out.tool_calls = calls.map((c) => ({ id: c.id, type: "function", function: { name: c.name, arguments: JSON.stringify(c.arguments ?? {}) } }));
			}
			wire.push(out);
		} else if (m.role === "toolResult") {
			wire.push({ role: "tool", tool_call_id: m.toolCallId, content: textOf(m.content) || "（空）" });
		}
	}
	return wire;
}

/** Pi 的 streamFn：把请求交给宿主去发，再把 SSE 片段还原成 Pi 的事件流。 */
function makeStreamFn(config) {
	return (model, context, options) => {
		const stream = createAssistantMessageEventStream();
		const output = {
			role: "assistant",
			content: [],
			api: "openai-completions",
			provider: model.provider,
			model: model.id,
			usage: emptyUsage(),
			stopReason: "stop",
			timestamp: Date.now(),
		};
		const requestId = `q${++counter}`;
		const tools = getCurrentTools(context.messages);
		const body = { model: model.id, messages: toWire(context.messages), stream: true, temperature: config.temperature ?? 0.2 };
		if (config.thinking === true || config.thinking === false) body.thinking = { type: config.thinking ? "enabled" : "disabled" };
		if (tools.length > 0) {
			body.tools = tools.map((t) => ({ type: "function", function: { name: t.name, description: t.description, parameters: t.parameters } }));
			body.tool_choice = "auto";
		}

		let textIndex = -1;
		let thinkingIndex = -1;
		const pending = new Map(); // index → {id, name, args}
		let finished = false;

		const closeText = () => {
			if (textIndex >= 0) {
				stream.push({ type: "text_end", contentIndex: textIndex, content: output.content[textIndex].text, partial: output });
				textIndex = -1;
			}
		};
		const closeThinking = () => {
			if (thinkingIndex >= 0) {
				stream.push({ type: "thinking_end", contentIndex: thinkingIndex, content: output.content[thinkingIndex].thinking, partial: output });
				thinkingIndex = -1;
			}
		};
		const fail = (reason, message) => {
			if (finished) return;
			finished = true;
			requests.delete(requestId);
			output.stopReason = reason;
			output.errorMessage = message;
			stream.push({ type: "error", reason, error: output });
			stream.end();
		};

		requests.set(requestId, {
			chunk(payload) {
				if (finished) return;
				let obj;
				try {
					obj = JSON.parse(payload);
				} catch {
					return;
				}
				if (obj.usage) {
					output.usage.input = obj.usage.prompt_tokens ?? 0;
					output.usage.output = obj.usage.completion_tokens ?? 0;
					output.usage.totalTokens = obj.usage.total_tokens ?? 0;
				}
				const delta = obj.choices?.[0]?.delta;
				if (!delta) return;
				if (typeof delta.reasoning_content === "string") {
					if (thinkingIndex < 0) {
						output.content.push({ type: "thinking", thinking: "" });
						thinkingIndex = output.content.length - 1;
						stream.push({ type: "thinking_start", contentIndex: thinkingIndex, partial: output });
					}
					if (delta.reasoning_content) {
						output.content[thinkingIndex].thinking += delta.reasoning_content;
						stream.push({ type: "thinking_delta", contentIndex: thinkingIndex, delta: delta.reasoning_content, partial: output });
					}
				}
				if (typeof delta.content === "string" && delta.content) {
					closeThinking();
					if (textIndex < 0) {
						output.content.push({ type: "text", text: "" });
						textIndex = output.content.length - 1;
						stream.push({ type: "text_start", contentIndex: textIndex, partial: output });
					}
					output.content[textIndex].text += delta.content;
					stream.push({ type: "text_delta", contentIndex: textIndex, delta: delta.content, partial: output });
				}
				for (const call of delta.tool_calls ?? []) {
					const index = call.index ?? 0;
					const slot = pending.get(index) ?? { id: "", name: "", args: "" };
					if (call.id) slot.id = call.id;
					if (call.function?.name) slot.name = call.function.name;
					if (typeof call.function?.arguments === "string") slot.args += call.function.arguments;
					pending.set(index, slot);
				}
			},
			end(error) {
				if (finished) return;
				if (error) {
					fail(options?.signal?.aborted ? "aborted" : "error", error);
					return;
				}
				closeThinking();
				closeText();
				const indexes = [...pending.keys()].sort((a, b) => a - b);
				for (const index of indexes) {
					const slot = pending.get(index);
					if (!slot.name) continue;
					const toolCall = { type: "toolCall", id: slot.id || `call_${requestId}_${index}`, name: slot.name, arguments: {} };
					try {
						const parsed = slot.args.trim() ? JSON.parse(slot.args) : {};
						if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) toolCall.arguments = parsed;
						else toolCall.argumentsError = `工具参数不是 JSON 对象：${slot.args.slice(0, 200)}`;
					} catch {
						toolCall.argumentsError = `工具参数不是合法的 JSON：${slot.args.slice(0, 200)}`;
					}
					output.content.push(toolCall);
					const contentIndex = output.content.length - 1;
					stream.push({ type: "toolcall_start", contentIndex, partial: output });
					stream.push({ type: "toolcall_delta", contentIndex, delta: slot.args, partial: output });
					stream.push({ type: "toolcall_end", contentIndex, toolCall, partial: output });
				}
				if (output.content.every((b) => b.type === "thinking")) {
					fail("error", "模型没有返回内容。");
					return;
				}
				finished = true;
				requests.delete(requestId);
				output.stopReason = output.content.some((b) => b.type === "toolCall") ? "toolUse" : "stop";
				stream.push({ type: "done", reason: output.stopReason, message: output });
				stream.end();
			},
		});

		options?.signal?.addEventListener("abort", () => {
			if (finished) return;
			g.__pi_cancel(requestId);
			fail("aborted", "已停下");
		});
		stream.push({ type: "start", partial: output });
		if (options?.signal?.aborted) {
			// 已经被叫停了：不再发请求
			fail("aborted", "已停下");
			return stream;
		}
		g.__pi_chat(requestId, JSON.stringify(body));
		return stream;
	};
}

function makeTools(runId, specs) {
	return specs.map((spec) => ({
		name: spec.name,
		label: spec.name,
		description: spec.description,
		parameters: spec.parameters,
		executionMode: "sequential",
		execute(toolCallId, params) {
			return new Promise((resolve) => {
				const callId = `${runId}:${toolCallId}:${++counter}`;
				toolCalls.set(callId, (resultJSON) => {
					let r = {};
					try {
						r = JSON.parse(resultJSON);
					} catch {}
					resolve({ content: [{ type: "text", text: String(r.content ?? "") }], details: null, isError: r.isError === true, terminate: r.terminate === true });
				});
				g.__pi_tool(callId, spec.name, JSON.stringify(params ?? {}));
			});
		},
	}));
}

function historyMessage(h, model) {
	if (h.role === "user") {
		let text = h.text || "";
		for (const id of h.fileIDs || []) text += `⟦file:${id}⟧`;
		return { role: "user", content: text, timestamp: Date.now() };
	}
	return {
		role: "assistant",
		content: [{ type: "text", text: h.text || "" }],
		api: "openai-completions",
		provider: model.provider,
		model: model.id,
		usage: emptyUsage(),
		stopReason: "stop",
		timestamp: Date.now(),
	};
}

const Pi = {
	version: "pi-agent-core 1.5.2",

	/** 开始一次运行。config: {system, model, thinking, temperature, maxTurns, tools, history, prompt:{text, images, fileIDs}} */
	start(runId, configJSON) {
		const config = JSON.parse(configJSON);
		const send = (event) => g.__pi_event(runId, JSON.stringify(event));
		const model = {
			id: config.model,
			name: config.model,
			api: "openai-completions",
			provider: config.provider || "deepseek",
			baseUrl: "",
			input: ["text", "image"],
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			reasoning: config.thinking !== false,
		};
		let turns = 0;
		const maxTurns = config.maxTurns ?? 200;
		const agent = new Agent({
			initialState: {
				systemPrompt: config.system,
				model,
				thinkingLevel: "off",
				tools: makeTools(runId, config.tools || []),
				messages: (config.history || []).map((h) => historyMessage(h, model)),
			},
			streamFn: makeStreamFn(config),
			toolExecution: "sequential",
			identity: null,
			finishTurn: async () => (turns >= maxTurns ? { action: "end" } : undefined),
		});
		runs.set(runId, agent);
		let outOfTurns = false;
		agent.subscribe((event) => {
			switch (event.type) {
				case "turn_start":
					turns += 1;
					send({ type: "turn_start", turn: turns });
					break;
				case "message_update": {
					if (event.assistantMessageEvent.type === "text_delta") {
						const text = event.message.content.filter((b) => b.type === "text").map((b) => b.text).join("");
						send({ type: "text", text });
					}
					break;
				}
				case "message_end":
					if (event.message.role === "assistant") {
						const text = event.message.content.filter((b) => b.type === "text").map((b) => b.text).join("");
						const calls = event.message.content.filter((b) => b.type === "toolCall").length;
						send({ type: "assistant", text, toolCalls: calls });
					}
					break;
				case "tool_execution_start":
					send({ type: "tool_start", name: event.toolName });
					break;
				case "tool_execution_end":
					send({ type: "tool_end", name: event.toolName, isError: event.isError === true });
					break;
				case "turn_end":
					if (turns >= maxTurns && event.toolResults.length > 0) outOfTurns = true;
					break;
			}
		});

		let text = config.prompt?.text || "";
		for (const id of config.prompt?.fileIDs || []) text += `⟦file:${id}⟧`;
		const images = (config.prompt?.images || []).map((data) => ({ type: "image", data, mimeType: "image/jpeg" }));
		agent
			.prompt(text, images.length > 0 ? images : undefined)
			.then(() => {
				const last = [...agent.state.messages].reverse().find((m) => m.role === "assistant");
				const reason = last?.stopReason === "aborted" ? "aborted" : agent.state.errorMessage ? "error" : outOfTurns ? "max_turns" : "stop";
				send({ type: "end", reason, error: agent.state.errorMessage || "" });
			})
			.catch((error) => {
				send({ type: "end", reason: "error", error: String(error?.message ?? error) });
			})
			.finally(() => runs.delete(runId));
	},

	abort(runId) {
		runs.get(runId)?.abort();
	},

	chunk(requestId, payload) {
		requests.get(requestId)?.chunk(payload);
	},

	chatEnd(requestId, error) {
		requests.get(requestId)?.end(error || "");
	},

	toolDone(callId, resultJSON) {
		const done = toolCalls.get(callId);
		toolCalls.delete(callId);
		if (done) done(resultJSON);
	},
};

g.Pi = Pi;
