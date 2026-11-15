#!/usr/bin/env python3
"""主动唤醒评测。

两层：
1. 检测（本机、免费）：按 App/Resources/signals.json 回放每个场景，和 Agent/Signals.swift 同一套规则，
   看该醒的醒了没有、不该醒的有没有误醒。
2. 判断（要 DeepSeek 密钥）：对醒了的场景，用 Assistant.swift 里的 proactiveRules 原文 + 唤醒消息，
   让模型在 notify / notify_later / stay_quiet 里选，看选得对不对、写的话像不像样。

用法：
  python3 bench.py                 # 只跑检测
  DEEPSEEK_API_KEY=sk-... python3 bench.py --llm [--runs 2]
密钥只从环境变量读，不要写进仓库。
"""
import json, os, re, sys, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = json.loads((ROOT / "App/Resources/signals.json").read_text())
SCENARIOS = json.loads((Path(__file__).parent / "scenarios.json").read_text())
COOLDOWN = {"request": 2, "commitment": 20, "care": 75}


def rules():
    src = (ROOT / "App/Sources/Agent/Assistant.swift").read_text()
    m = re.search(r'static let proactiveRules = """\n(.*?)\n\s*"""', src, re.S)
    return "\n".join(l[4:] if l.startswith("    ") else l for l in m.group(1).split("\n"))


def hits(text):
    return [(name, k) for name, k in sorted(CONFIG["kinds"].items()) if any(w in text for w in k["words"])]


def mine(speaker):
    return speaker in (None, "me")


def detect(sc):
    """逐句回放：每进来一句扫一次（App 里是每转写完一段扫一次）。返回 [(分钟, 类别, 证据)]。"""
    window, wakes, last = [], [], {}
    win = CONFIG["window_minutes"]
    drv = CONFIG["driving"]
    driving_note = sc["driving"] >= drv["long_minutes"]

    def fire(t, kind, ev):
        if t - last.get(kind, -1e9) < COOLDOWN[kind]:
            return
        last[kind] = t
        wakes.append((t, kind, ev))

    for t, speaker, text in sc["lines"]:
        request = []
        if mine(speaker):
            for name, k in hits(text):
                h = (t, name, k["wake"], k["weight"], text)
                (request if k["wake"] == "request" else window).append(h)
        window = [h for h in window if t - h[0] <= win]
        if request:
            fire(t, "request", [h[4] for h in request])
            continue
        score = sum(h[3] for h in window) + (drv["bonus"] if window and driving_note else 0)
        if score >= CONFIG["threshold"]:
            by = {}
            for h in window:
                by[h[2]] = by.get(h[2], 0) + h[3]
            kind = max(sorted(by), key=lambda k: by[k])
            fire(t, kind, [h[4] for h in window])
            window = []
    if sc["driving"] >= drv["long_alone_minutes"] and not wakes:
        fire(0, "care", [])
    return wakes


def wake_message(sc, kind, evidence):
    reason = {"request": "我刚说了要你提醒我", "commitment": "我刚答应了别人一件事"}.get(
        kind, "我开了很久的车" if not evidence else "我这阵子一直在抱怨、不舒服或者很累")
    lines = [f"- {sc['now']} 我说：「{e}」" for e in evidence]
    if sc["driving"] >= CONFIG["driving"]["long_minutes"]:
        lines.append(f"- 已经连续开车约 {sc['driving']} 分钟")
    text = f"你被唤醒了（原因：{reason}）。"
    if lines:
        text += "\n本机刚听到 / 看到的：\n" + "\n".join(lines)
    return text + "\n今天还没有提醒过我。\n看看现在有没有值得跟我说的事。"


TOOLS = [
    {"type": "function", "function": {"name": "notify", "description": "发一条通知给我。只有现在说确实有用时才用。",
     "parameters": {"type": "object", "properties": {"title": {"type": "string"}, "body": {"type": "string"}}, "required": ["title", "body"]}}},
    {"type": "function", "function": {"name": "notify_later", "description": "在指定时间发一条通知给我（我说“几点提醒我…”时用）。time 用 HH:mm（今天）或 yyyy-MM-dd HH:mm。",
     "parameters": {"type": "object", "properties": {"time": {"type": "string"}, "title": {"type": "string"}, "body": {"type": "string"}}, "required": ["time", "title", "body"]}}},
    {"type": "function", "function": {"name": "stay_quiet", "description": "现在没有值得提醒的事。", "parameters": {"type": "object", "properties": {}}}},
]


def decide(sc, message):
    """没有真实的读类工具：把情境直接写进 system，等于智能体查过一遍。"""
    context = f"现在是 2026-11-15 {sc['now']}。"
    context += f"最近一小时的情境：{'乘车' if sc['driving'] else '静止'}" + (f"，连续 {sc['driving']} 分钟" if sc["driving"] else "") + "。"
    context += "今天的日程：没有。待办：没有。"
    body = {"model": "deepseek-chat", "temperature": 0.7, "tools": TOOLS, "tool_choice": "required",
            "messages": [{"role": "system", "content": "你是我的常驻助理。说话简短、像朋友。\n\n" + context + "\n\n" + rules()},
                         {"role": "user", "content": message}]}
    req = urllib.request.Request("https://api.deepseek.com/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json", "Authorization": "Bearer " + os.environ["DEEPSEEK_API_KEY"]})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                msg = json.load(r)["choices"][0]["message"]
            call = (msg.get("tool_calls") or [{}])[0].get("function", {})
            return call.get("name", "none"), json.loads(call.get("arguments") or "{}")
        except Exception as e:  # noqa
            err = e
            time.sleep(2)
    return "error", {"error": str(err)}


def main():
    use_llm = "--llm" in sys.argv
    runs = int(sys.argv[sys.argv.index("--runs") + 1]) if "--runs" in sys.argv else 1
    tp = fp = fn = tn = 0
    hard_miss = []
    good = total = 0
    for sc in SCENARIOS:
        wakes = detect(sc)
        expect = sc["wake"]
        got = wakes[0][1] if wakes else None
        if sc.get("hard") and got != expect:
            hard_miss.append(sc["id"])
            print(f"△ 已知   {sc['id']}：应 {expect or '不醒'}，实 {got or '不醒'}（词表覆盖不到，不计入）")
            continue
        if expect and got == expect:
            tp += 1; mark = "✓"
        elif expect and got != expect:
            fn += 1; mark = "✗ 漏" if not got else f"✗ 错类({got})"
        elif not expect and got:
            fp += 1; mark = f"✗ 误醒({got})"
        else:
            tn += 1; mark = "✓"
        print(f"{mark:8} {sc['id']}：应 {expect or '不醒'}，实 {got or '不醒'}" + (f"，醒 {len(wakes)} 次" if len(wakes) > 1 else ""))
        if use_llm and wakes:
            t, kind, ev = wakes[0]
            for _ in range(runs):
                name, args = decide(sc, wake_message(sc, kind, ev))
                ok = name in sc.get("decide", ["stay_quiet"])
                total += 1; good += ok
                say = " / ".join(str(args.get(k, "")) for k in ("time", "title", "body") if args.get(k))
                print(f"           {'✓' if ok else '✗'} 模型：{name}  {say}")
    print(f"\n检测：该醒的 {tp}/{tp + fn} 醒了，不该醒的误醒 {fp}/{fp + tn}")
    if hard_miss:
        print(f"难例没覆盖：{'、'.join(hard_miss)}")
    if use_llm:
        print(f"判断：{good}/{total} 选对")
    return 1 if fn or fp else 0


if __name__ == "__main__":
    sys.exit(main())
