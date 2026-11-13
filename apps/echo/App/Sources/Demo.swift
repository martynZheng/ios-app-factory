import Foundation

/// 演示数据（-demo 1）。走真实的解析与合并流程，用于 CI 里在模拟器上截图自测界面。
enum Demo {
    static func seed() {
        let store = Store.shared
        let cal = Calendar.current
        let base = cal.date(bySettingHour: 9, minute: 30, second: 0, of: Date()) ?? Date()
        let day = Store.dayKey(base)
        let script: [(Int, String)] = [
            (0, "各位评委各位同事上午好，欢迎来到采供和 IDC 的 AI 实战挑战赛决赛现场。"),
            (1, "今天一共有六支队伍路演，每队十分钟讲解加五分钟问答。"),
            (2, "下面有请二号选手，带来他们的运维助手。"),
            (4, "我们的环境要做全方位全时段监控，云业务体量快速增长给监控带来很大压力。"),
            (5, "告警处理耗时长，多地同时告警的时候响应处置时间明显增加。"),
            (6, "我们沉淀了三十四个技能，让助手小美可以自主处理告警。"),
            (7, "小美收到告警后会解析故障位置和机器 SN，获取日志，自主制定恢复方案。"),
            (9, "评委提问，这个恢复操作的安全性怎么保证。"),
            (10, "我们所有操作都会先创建恢复工单，执行后确认是否真实恢复，再生成可审查的报告。"),
            (16, "谢谢二号选手，下面有请五号选手，来自天津 DC 平台。"),
            (17, "我们做的是代码提交和验收流程里的检查机制，提交时触发增量检查，之后还有全量检查。"),
            (18, "会先获取旧页面的基线，包括 API 和样式，发布后对照基线验证有没有引入 bug。"),
            (20, "这套机制可以从当前阶段延伸到前后端全链路。"),
            (31, "中场休息十分钟，汯毅你会后把六支队伍的评分表汇总一下，周五之前发给评委组。"),
            (32, "好的，另外决赛的奖项设置已经确定了，一等奖一名二等奖两名。"),
            (33, "场地下周还能不能用，这个要再跟行政确认一下。"),
        ]
        var lines: [Line] = []
        var segments: [Segment] = []
        for (i, row) in script.enumerated() {
            let t = base.addingTimeInterval(Double(row.0) * 60)
            let seg = Segment(id: "demo_\(i)", sessionID: "demo", index: i, start: t, duration: 60, hasAudio: false, status: .done, error: nil)
            segments.append(seg)
            lines.append(Line(id: UUID(), segmentID: seg.id, time: t, offset: 0, text: row.1, edited: false))
        }
        store.mutate { db in
            db.segments = segments
            db.lines = lines
            db.dayContext = [day: ""]
        }
        let a = Array(lines[0..<8]), b = Array(lines[8..<13]), c = Array(lines[13...])
        let jsonA = """
        {"scene":"AI 实战挑战赛决赛路演，我在主持","chapters":[
        {"title":"开场：六支队伍决赛路演","speaker":null,"summary":"主持人开场，说明今天六支队伍路演，每队十分钟讲解加五分钟问答。","continues":false,"sources":[0,1,2],"points":[{"text":"每队十分钟讲解加五分钟问答","sources":[1]}]},
        {"title":"二号选手：告警自闭环助手小美","speaker":"二号选手","summary":"云业务增长让监控告警处理越来越慢，团队沉淀 34 个技能，让助手小美自主解析并处理告警。","continues":false,"sources":[3,4,5,6,7],"points":[
          {"text":"多地同时告警时响应处置耗时明显增加","sources":[4]},
          {"text":"沉淀了 34 个技能供助手调用","sources":[5]},
          {"text":"小美会解析故障位置和机器 SN，获取日志后自主制定恢复方案","sources":[6]}]}],
        "decisions":[],"todos":[],"pending":[]}
        """
        let jsonB = """
        {"scene":"","chapters":[
        {"title":"二号选手：告警自闭环助手小美","speaker":"二号选手","summary":"团队沉淀 34 个技能让助手小美自主处理告警；所有恢复操作先建工单、执行后确认并生成可审查报告。","continues":true,"sources":[0],"points":[{"text":"恢复操作先创建工单，执行后确认真实恢复并生成可审查的报告","sources":[0]}]},
        {"title":"五号选手：提交与验收的检查机制","speaker":"五号选手","summary":"在代码提交和验收流程中加入增量与全量检查，并用旧页面基线对照发现新引入的问题。","continues":false,"sources":[1,2,3,4],"points":[
          {"text":"提交时触发增量检查，之后还有全量检查","sources":[2]},
          {"text":"先获取旧页面的 API 和样式基线，发布后对照验证","sources":[3]},
          {"text":"机制可延伸到前后端全链路","sources":[4]}]}],
        "decisions":[],"todos":[],"pending":[]}
        """
        let jsonC = """
        {"scene":"","chapters":[
        {"title":"中场：评分汇总与奖项","speaker":null,"summary":"中场休息时安排了评分表汇总，并确认了奖项设置。","continues":false,"sources":[0,1,2],"points":[]}],
        "decisions":[{"text":"决赛奖项设置为一等奖一名、二等奖两名","sources":[1]}],
        "todos":[{"text":"会后汇总六支队伍的评分表并发给评委组","owner":"汯毅","due":"周五","sources":[0]}],
        "pending":[{"text":"场地下周还能不能用，需要跟行政确认","sources":[2]}]}
        """
        let coordinator = DigestCoordinator.shared
        let steps: [(String, [Line])] = [(jsonA, a), (jsonB, b), (jsonC, c)]
        if UserDefaults.standard.bool(forKey: "grow") {
            // 录屏演示：一节一节长出来
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + Double(i) * 1.8) {
                    coordinator.merge(DigestEngine.parseBlock(step.0, lines: step.1), chunk: step.1, day: day, engine: "device")
                }
            }
        } else {
            for step in steps {
                coordinator.merge(DigestEngine.parseBlock(step.0, lines: step.1), chunk: step.1, day: day, engine: "device")
            }
        }
    }
}
