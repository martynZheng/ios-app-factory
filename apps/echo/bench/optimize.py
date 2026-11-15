#!/usr/bin/env python3
"""自动调提示词：评测 → 把失败案例交给优化模型改写 proactiveRules → 再评测，直到通过。

- 训练集 scenarios.json：优化模型能看到失败案例。
- 验收集 holdout.json：优化模型看不到，只用来判断是不是真的变好了，而不是背答案。
- 优化模型不许往提示词里加关键词表、事件清单、打分/阈值规则——只能写处境、能做什么、我是什么样的人。
- 通过 = 训练集每次都可接受 且 验收集 ≥ --holdout（默认 0.9）。
- --write 把最好的一版写回 Assistant.swift。

  DEEPSEEK_API_KEY=sk-... python3 optimize.py [--iters 8] [--runs 3] [--write]
"""
import json, re, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import bench

HERE = Path(__file__).parent
SWIFT = bench.ROOT / "App/Sources/Agent/Assistant.swift"
TRAIN = json.loads((HERE / "scenarios.json").read_text())
HOLDOUT = json.loads((HERE / "holdout.json").read_text())


def evaluate(rules, scenarios, runs):
    jobs = [(sc, i) for sc in scenarios for i in range(runs)]
    with ThreadPoolExecutor(8) as pool:
        results = list(pool.map(lambda j: (j[0], bench.decide(j[0], "deepseek-chat", rules)), jobs))
    fails = [(sc, name, a) for sc, (name, a) in results if name not in sc["expect"]]
    return 1 - len(fails) / len(jobs), fails


META = """你在帮我调一个常驻助理的“主动唤醒”提示词。助理每隔一阵会被叫醒，看到我最近说的话（带说话人标注）和情境，
自己决定：notify 现在发通知 / notify_later 定时发 / stay_quiet 不说，并给 recheck_minutes。

下面是试过的几版提示词和得分（越高越好），目前最好的一版，它做错的案例，以及全部评测场景的概况（每个场景应该怎么选）。
改写最好的那一版，让它在做错的案例上判断对，同时不能把其他场景弄坏——“该开口”和“该安静”两边都要顾到，之前分数低的版本往往就是只顾了一边。

硬性要求：
- 不许写关键词表、事件清单（“遇到 A/B/C 就提醒”）、打分、阈值、次数限制。只能写：它的处境、它能做什么、我是个什么样的人、我在乎什么、什么样的话对我有用。
- 不要针对某个具体案例写特例；想清楚背后的原因，用一般性的话说。
- 不超过 450 个字。保留 notify / notify_later / stay_quiet / recheck_minutes 的说明和通知字数限制（标题≤14字，正文≤50字）。
- 只输出新的提示词正文，不要解释、不要代码块。

【试过的版本】
{history}

【目前最好的一版】
{rules}

【它做错的案例】
{fails}

【全部场景概况】
{overview}"""


def describe(fails):
    out = []
    for sc, name, a in fails[:14]:
        said = " / ".join(str(a[k]) for k in ("time", "title", "body") if a.get(k))
        out.append(f"场景「{sc['id']}」\n{bench.wake_message(sc)}\n期望：{'/'.join(sc['expect'])}；实际：{name} {said}")
    return "\n\n".join(out)


def overview():
    rows = []
    for sc in TRAIN:
        said = "；".join(p + x for _, p, x in sc["lines"]) or "（没说话）"
        rows.append(f"- {sc['id']}（{'开车' + str(sc['driving']) + '分钟' if sc['driving'] else '没开车'}）：{said} → 应 {'/'.join(sc['expect'])}")
    return "\n".join(rows)


def rewrite(rules, fails, history):
    hist = "\n\n".join(f"得分 {score:.0%}：\n{text}" for score, text in history[-5:])
    body = {"model": "deepseek-reasoner", "messages": [{"role": "user", "content": META.format(
        rules=rules, fails=describe(fails), history=hist, overview=overview())}]}
    text = bench.call(body)["content"].strip()
    return re.sub(r"^```\w*\n|\n```$", "", text).strip()


def write_back(rules):
    src = SWIFT.read_text()
    body = "\n".join(("    " + l) if l else "" for l in rules.split("\n"))
    new = re.sub(r'(static let proactiveRules = """\n)(.*?)(\n\s*""")', lambda m: m.group(1) + body + m.group(3), src, count=1, flags=re.S)
    SWIFT.write_text(new)


def main():
    iters, runs = int(bench.arg("--iters", 8)), int(bench.arg("--runs", 3))
    need = float(bench.arg("--holdout", 0.9))
    rules = bench.rules()
    best = None
    history = []
    best_fails = []
    for it in range(iters + 1):
        train, fails = evaluate(rules, TRAIN, runs)
        hold, hold_fails = evaluate(rules, HOLDOUT, runs)
        print(f"第 {it} 版：训练 {train:.0%}  验收 {hold:.0%}  （{len(rules)} 字）", flush=True)
        for sc, name, _ in fails:
            print(f"    训练错：{sc['id']} → {name}")
        for sc, name, _ in hold_fails:
            print(f"    验收错：{sc['id']} → {name}")
        history.append((train, rules))
        # 选最好的只看训练集（验收集只用来判断通过与否，不参与挑选，免得间接泄漏）
        score = (train, -len(rules))
        if best is None or score > best[0]:
            best = (score, rules, train, hold)
            best_fails = fails
        if train == 1 and hold >= need:
            best = (score, rules, train, hold)
            print("通过。")
            break
        if it == iters:
            break
        # 从目前最好的一版出发改，避免越改越偏
        rules = rewrite(best[1], best_fails, history)
        print("-" * 40 + "\n" + rules + "\n" + "-" * 40, flush=True)
    _, rules, train, hold = best
    print(f"\n最好的一版：训练 {train:.0%}  验收 {hold:.0%}\n{rules}")
    if "--write" in sys.argv:
        write_back(rules)
        print("已写回 Assistant.swift")


if __name__ == "__main__":
    main()
