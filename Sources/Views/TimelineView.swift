import SwiftUI
import UIKit

/// 横スクロールのタイムライン(クリップの長さは出力上の長さに比例)
struct TimelineView: View {
    let project: EditorProject
    let player: PlayerController
    @Binding var selection: UUID?

    private let pointsPerSecond: CGFloat = 40
    private let minCellWidth: CGFloat = 60
    private let maxCellWidth: CGFloat = 360
    private let cellSpacing: CGFloat = 4
    private let cellHeight: CGFloat = 64

    var body: some View {
        let clips = project.clips
        let widths = clips.map { cellWidth(for: $0) }
        let starts = project.clipStartTimes()
        let playheadOffset = playheadX(clips: clips, widths: widths)

        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: cellSpacing) {
                        ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                            TimelineClipCell(clip: clip,
                                             isSelected: clip.id == selection,
                                             width: index < widths.count ? widths[index] : minCellWidth,
                                             height: cellHeight)
                                .id(clip.id)
                                .onTapGesture {
                                    selection = clip.id
                                    if index < starts.count {
                                        player.seek(to: starts[index])
                                    }
                                }
                                .contextMenu {
                                    contextMenuItems(index: index, clipID: clip.id, count: clips.count)
                                }
                                .draggable(clip.id.uuidString)
                                .dropDestination(for: String.self) { (items: [String], _: CGPoint) -> Bool in
                                    return handleDrop(items, onto: clip.id)
                                }
                        }
                    }

                    // 再生位置
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: cellHeight + 12)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .offset(x: playheadOffset - 1, y: -6)
                        .allowsHitTesting(false)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .onChange(of: selection) { _, newValue in
                if let clipID = newValue {
                    withAnimation {
                        proxy.scrollTo(clipID, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - レイアウト計算

    private func cellWidth(for clip: Clip) -> CGFloat {
        let width = CGFloat(clip.outputDuration) * pointsPerSecond
        return min(max(width, minCellWidth), maxCellWidth)
    }

    private func playheadX(clips: [Clip], widths: [CGFloat]) -> CGFloat {
        guard let location = project.locate(timelineTime: player.currentTime),
              location.index < clips.count, location.index < widths.count else { return 0 }
        var x: CGFloat = 0
        for i in 0..<location.index {
            x += widths[i] + cellSpacing
        }
        let clip = clips[location.index]
        var fraction = 0.0
        if clip.outputDuration > 0 {
            fraction = (location.sourceTime - clip.startTime) / max(clip.speed, 0.01) / clip.outputDuration
        }
        fraction = min(max(fraction, 0), 1)
        return x + widths[location.index] * CGFloat(fraction)
    }

    // MARK: - 並べ替え・操作

    @ViewBuilder
    private func contextMenuItems(index: Int, clipID: UUID, count: Int) -> some View {
        Button {
            moveClip(clipID, by: -1)
        } label: {
            Label("左へ移動", systemImage: "arrow.left")
        }
        .disabled(index == 0)

        Button {
            moveClip(clipID, by: 1)
        } label: {
            Label("右へ移動", systemImage: "arrow.right")
        }
        .disabled(index >= count - 1)

        Button {
            project.duplicateClip(id: clipID)
        } label: {
            Label("複製", systemImage: "plus.square.on.square")
        }

        Button(role: .destructive) {
            if selection == clipID {
                selection = nil
            }
            project.removeClip(id: clipID)
        } label: {
            Label("削除", systemImage: "trash")
        }
    }

    private func moveClip(_ clipID: UUID, by delta: Int) {
        guard let i = project.index(of: clipID) else { return }
        let j = i + delta
        guard j >= 0, j < project.clips.count else { return }
        withAnimation {
            project.clips.swapAt(i, j)
        }
    }

    private func handleDrop(_ items: [String], onto targetID: UUID) -> Bool {
        guard let payload = items.first,
              let sourceID = UUID(uuidString: payload),
              sourceID != targetID,
              let from = project.index(of: sourceID),
              let to = project.index(of: targetID) else { return false }
        withAnimation {
            let moving = project.clips.remove(at: from)
            let destination = min(to, project.clips.count)
            project.clips.insert(moving, at: destination)
        }
        return true
    }
}

// MARK: - クリップのセル

private struct TimelineClipCell: View {
    let clip: Clip
    let isSelected: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            thumbnail
                .frame(width: width, height: height)
                .clipped()

            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: height / 2)
                .frame(maxHeight: .infinity, alignment: .bottom)

            HStack(spacing: 3) {
                Text(MediaTimeText.shortSeconds(clip.outputDuration))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                Spacer(minLength: 0)
                if abs(clip.speed - 1) > 0.001 {
                    Text(String(format: "%gx", clip.speed))
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 3)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 3))
                }
                if !clip.filter.isIdentity {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 9))
                }
                if clip.multicam.isActive {
                    Image(systemName: "camera.on.rectangle")
                        .font(.system(size: 9))
                }
                if clip.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 9))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.bottom, 3)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.yellow : Color.white.opacity(0.25),
                        lineWidth: isSelected ? 3 : 1)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = clip.thumbnail {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.4)
                Image(systemName: "film")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}
