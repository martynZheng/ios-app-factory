import SwiftUI

/// 开场剧情：外婆留下的老商场。
struct IntroView: View {
    @EnvironmentObject private var store: GameStore
    @State private var page = 0
    @State private var name = ""

    private let lines = [
        "毕业那年夏天，我回到了家乡。",
        "外婆留下的「星光百货」，已经冷清很多年了……",
        "落灰的橱窗、生锈的招牌，只有一楼的奶茶小铺还亮着灯。",
        "我想让它重新闪闪发光——从一杯奶茶开始！",
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 18) {
                AvatarView(look: store.heroineLook)
                    .frame(width: 140, height: 190)
                    .background(Circle().fill(Palette.blush).frame(width: 150, height: 150))
                if page < lines.count {
                    Text(lines[page])
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 60)
                        .id(page)
                        .transition(.opacity)
                    CandyButton(title: page == lines.count - 1 ? "开始吧" : "继续", color: Palette.pink) {
                        withAnimation(.easeInOut(duration: 0.25)) { page += 1 }
                    }
                } else {
                    Text("你叫什么名字？")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                    TextField("小星", text: $name)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Palette.cream))
                        .overlay(Capsule().strokeBorder(Palette.blush, lineWidth: 2))
                    CandyButton(title: "成为老板 ✨", color: Palette.rose) {
                        withAnimation { store.finishIntro(name: name) }
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: 380)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.white)
                    .shadow(color: Palette.pink.opacity(0.3), radius: 20, y: 8)
            )
            .padding(24)
        }
    }
}
