import SwiftUI

// =====================================================================
// SNS の表示ガイドをプレビューに重ねる。
// 隠れる範囲は半透明の黒に斜線、隠れない範囲は細い点線の四角。投稿先の名前を薄く書く。
// タップはすべて下のプレビューに通す(選択・再生の操作を邪魔しない)。
// 範囲は SafeZoneModels.swift。
// =====================================================================

/// プレビューの映像の上に重ねる本体(9:16 以外では短いヒントだけ出す)
struct SafeZoneOverlay: View {
    let guide: SafeZoneGuide
    /// プレビューの映像の大きさ(比率の判定に使う)
    let renderSize: CGSize

    var body: some View {
        if guide.isOn {
            if SafeZoneGuide.isPortrait9x16(renderSize) {
                Canvas(rendersAsynchronously: false) { context, size in
                    draw(in: context, size: size)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            } else {
                VStack {
                    Spacer()
                    Text("表示ガイドは 9:16 のときに出ます")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .padding(.bottom, 8)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        let regions = guide.regions
        // 隠れる範囲: 半透明の黒を敷いて斜線
        for region in regions {
            let rect = region.rect(in: size)
            guard rect.width > 0, rect.height > 0 else { continue }
            let path = Path(rect)
            context.fill(path, with: .color(.black.opacity(0.28)))
            var hatch = context
            hatch.clip(to: path)
            var lines = Path()
            let step: CGFloat = 8
            var x = rect.minX - rect.height
            while x < rect.maxX {
                lines.move(to: CGPoint(x: x, y: rect.minY))
                lines.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
                x += step
            }
            hatch.stroke(lines, with: .color(.white.opacity(0.10)), lineWidth: 1)
        }
        // 隠れない範囲: 細い点線の四角
        if let safe = guide.safeRect {
            let rect = CGRect(x: safe.minX * size.width, y: safe.minY * size.height,
                              width: safe.width * size.width, height: safe.height * size.height)
                .insetBy(dx: 1.5, dy: 1.5)
            context.stroke(Path(roundedRect: rect, cornerRadius: 3),
                           with: .color(.white.opacity(0.75)),
                           style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        // 投稿先の名前を薄く書く。「すべて」では同じ場所に重ならないよう、横長の範囲は横に、右の列は縦にずらす
        var labelOffsetX: [SafeZoneRegionKind: CGFloat] = [:]
        for region in regions {
            let rect = region.rect(in: size)
            let text = context.resolve(Text(region.platform)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55)))
            let measured = text.measure(in: size)
            let origin: CGPoint
            switch region.kind {
            case .rightColumn:
                origin = CGPoint(x: rect.minX + 3,
                                 y: rect.minY + 3 + CGFloat(region.platformIndex) * (measured.height + 2))
            case .topBar, .bottomBlock, .bottomBar:
                let shift = labelOffsetX[region.kind] ?? 0
                origin = CGPoint(x: rect.minX + 4 + shift, y: rect.minY + 2)
                labelOffsetX[region.kind] = shift + measured.width + 6
            }
            // 範囲からはみ出すなら書かない(小さなプレビューの細いバーなど)
            guard origin.y + measured.height <= rect.maxY + 1 else { continue }
            context.draw(text, at: origin, anchor: .topLeading)
        }
    }
}

/// プレビューの角に出す切り替えボタン(メニューで なし / TikTok / Reels / Shorts / すべて を選ぶ)と、
/// 文字がボタンに隠れるときの小さな警告
struct SafeZoneGuideButton: View {
    @Binding var guide: SafeZoneGuide
    /// 中心が隠れる範囲にあるテキストの数
    let hiddenTextCount: Int

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Picker("表示ガイド", selection: $guide) {
                    ForEach(SafeZoneGuide.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "rectangle.dashed")
                    if guide.isOn {
                        Text(guide.title)
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.45), in: Capsule())
                .contentShape(Capsule())
            }
            .accessibilityLabel("表示ガイド")
            if guide.isOn, hiddenTextCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .padding(5)
                    .background(Color.black.opacity(0.45), in: Circle())
                    .help("文字がボタンに隠れます")
                    .accessibilityLabel("文字がボタンに隠れます")
            }
        }
        .padding(8)
    }
}

/// プレビューに重ねるひとまとまり(ガイドの絵 + 左上のボタン)。ContentView からはこれ 1 つを overlay する
struct SafeZonePreviewLayer: View {
    @Binding var guide: SafeZoneGuide
    let project: EditorProject
    let renderSize: CGSize
    /// 手書き中はボタンを出さない(角の線が描けなくなるため)
    var showsButton: Bool = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            SafeZoneOverlay(guide: guide, renderSize: renderSize)
            if showsButton {
                SafeZoneGuideButton(guide: $guide,
                                    hiddenTextCount: guide.hiddenTextCount(in: project.textClips))
            }
        }
        // ガイドを出していないときもプレビュー全体に広げる(ボタンを左上に置くため)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
