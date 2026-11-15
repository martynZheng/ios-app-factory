#!/usr/bin/env python3
"""主动唤醒评测：把场景（新听到的话 + 情境）原样交给模型，看它说不说、说什么、隔多久再看。

不在本机做任何预筛——App 里也没有。判断全交给模型，这里只量它判断得怎么样。
提示词直接读 Assistant.swift 里的 proactiveRules，和 App 用的是同一段。

  DEEPSEEK_API_KEY=sk-... python3 bench.py [--runs 2] [--model deepseek-chat]
密钥只从环境变量读，不要写进仓库。scenarios.json 里 expect 是可以接受的选择。
"""
import json, os, re, sys, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCENARIOS = json.loads((Path(__file__).parent / "scenarios.json").read_text())


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


def rules():
    src = (ROOT / "App/Sources/Agent/Assistant.swift").read_text()
    m = re.search(r'static let proactiveRules = """\n(.*?)\n\s*"""', src, re.S)
    return "\n".join(l[4:] if l.startswith("    ") else l for l in m.group(1).split("\n"))


RECHECK = {"type": "number", "description": "多少分钟后再醒来看一眼。按你判断接下来可能会发生什么来定。"}
S = {"type": "string"}
TOOLS = [
    {"type": "function", "function": {"name": "notify", "description": "现在发一条通知给我。",
     "parameters": {"type": "object", "properties": {"title": S, "body": S, "recheck_minutes": RECHECK}, "required": ["title", "body", "recheck_minutes"]}}},
    {"type": "function", "function": {"name": "notify_later", "description": "在指定时间发一条通知给我。time 用 HH:mm（今天）或 yyyy-MM-dd HH:mm。",
     "parameters": {"type": "object", "properties": {"time": S, "title": S, "body": S, "recheck_minutes": RECHECK}, "required": ["time", "title", "body", "recheck_minutes"]}}},
    {"type": "function", "function": {"name": "stay_quiet", "description": "现在不说。",
     "parameters": {"type": "object", "properties": {"recheck_minutes": RECHECK}, "required": ["recheck_minutes"]}}},
]


def clock(now, minutes_ago):
    h, m = map(int, now.split(":"))
    t = h * 60 + m - minutes_ago
    return f"{t // 60:02d}:{t % 60:02d}"


def wake_message(sc):
    last = sc["lines"][-1][0] if sc["lines"] else 0
    lines = [f"- {clock(sc['now'], last - t)} {p}{x}" for t, p, x in sc["lines"]]
    text = "你被唤醒了（原因：" + ("又听到了一些新的话" if lines else "到了你上次说要再看一眼的时间") + "）。"
    if lines:
        text += "\n上次醒来之后新听到的（方括号是声纹和声音分类的猜测：[我] 是我本人，[说话人 X] 或名字是别人，[背景] 是远处的人声，[电视/音乐] 是放出来的声音，没有方括号是还没认出来；转写可能有错字）：\n" + "\n".join(lines)
    return text + "\n今天还没有提醒过我。"


def call(body):
    req = urllib.request.Request("https://api.deepseek.com/chat/completions", json.dumps(body).encode(),
                                 {"Content-Type": "application/json", "Authorization": "Bearer " + os.environ["DEEPSEEK_API_KEY"]})
    err = None
    for _ in range(4):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return json.load(r)["choices"][0]["message"]
        except Exception as e:  # noqa
            err = e
            time.sleep(3)
    raise RuntimeError(err)


def decide(sc, model="deepseek-chat", rule_text=None):
    context = f"现在是 2026-11-15 {sc['now']}。最近一小时的情境：" + (f"乘车，已连续 {sc['driving']} 分钟" if sc["driving"] else "静止") + "。今天的日程：没有。待办：没有。"
    body = {"model": model, "tools": TOOLS,
            "messages": [{"role": "system", "content": "你是我的常驻助理。\n\n" + context + "\n\n" + (rule_text or rules())},
                         {"role": "user", "content": wake_message(sc)}]}
    if model == "deepseek-chat":
        body.update(temperature=0.7, tool_choice="required")
    try:
        msg = call(body)
    except RuntimeError as e:
        return "error", {"error": str(e)}
    fn = (msg.get("tool_calls") or [{}])[0].get("function", {})
    try:
        return fn.get("name", "none"), json.loads(fn.get("arguments") or "{}")
    except ValueError:
        return fn.get("name", "none"), {}


def main():
    runs, model = int(arg("--runs", 1)), arg("--model", "deepseek-chat")
    good = total = 0
    for sc in SCENARIOS:
        print(f"{sc['id']}（可接受：{'/'.join(sc['expect'])}）")
        for _ in range(runs):
            name, a = decide(sc, model)
            ok = name in sc["expect"]
            good += ok; total += 1
            say = " / ".join(str(a[k]) for k in ("time", "title", "body") if a.get(k))
            print(f"   {'✓' if ok else '✗'} {name}  {say}  ⟳{a.get('recheck_minutes', '?')}分")
    print(f"\n{good}/{total} 选择可接受")


if __name__ == "__main__":
    main()
