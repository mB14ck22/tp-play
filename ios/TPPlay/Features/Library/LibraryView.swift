import SwiftUI

struct LibraryView: View {
    @StateObject private var library = PSNLibraryStore.shared
    @State private var selectedGame: TrophyGamePreview?

    var body: some View {
        ZStack {
            if let profile = library.profile {
                LibraryOverviewView(
                    profile: profile,
                    games: library.games,
                    freezesHeader: selectedGame != nil,
                    syncStatus: library.syncStatus,
                    refresh: { Task { await library.sync() } }
                ) { game in
                    withAnimation(.easeOut(duration: 0.2)) {
                        selectedGame = game
                    }
                }
                .allowsHitTesting(selectedGame == nil)
            } else {
                LibrarySignedOutView(isLoading: library.isLoading, errorMessage: library.errorMessage)
            }

            if let selectedGame {
                LibraryTrophyDetailView(game: selectedGame) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        self.selectedGame = nil
                    }
                }
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .background(TPPlayTheme.canvas)
        .task { await library.syncIfNeeded() }
    }
}

private struct LibraryOverviewView: View {
    let profile: PSNProfilePreview
    let games: [TrophyGamePreview]
    let freezesHeader: Bool
    let syncStatus: String
    let refresh: () -> Void
    let openGame: (TrophyGamePreview) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if freezesHeader {
                    LibraryFrozenHeader("LIBRARY // TROPHIES")
                } else {
                    TPPageHeader("LIBRARY // TROPHIES")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)
            .background(TPPlayTheme.canvas)
            .overlay(alignment: .bottom) {
                Rectangle().fill(TPPlayTheme.border).frame(height: 1)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    syncNotice
                    profilePanel
                    trophySummary
                    sectionHeader("TROPHY GROUPS", detail: "\(games.count) GROUPS")
                    ForEach(games) { game in
                        Button { openGame(game) } label: {
                            TrophyGameCard(game: game)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(LibraryPressStyle())
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var syncNotice: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(TPPlayTheme.violet)
                .frame(width: 7, height: 7)
            Text(syncStatus.uppercased())
            Spacer()
            Button("SYNC") { refresh() }
                .foregroundStyle(TPPlayTheme.accent)
        }
        .font(.system(size: 8, weight: .black, design: .monospaced))
        .tracking(0.6)
        .foregroundStyle(TPPlayTheme.secondaryText)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }

    private var profilePanel: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 0) {
                identityBlock
                    .frame(minWidth: 360)
                levelBlock
                    .frame(width: 214)
            }
            VStack(spacing: 0) {
                identityBlock
                levelBlock
            }
        }
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }

    private var identityBlock: some View {
        HStack(alignment: .top, spacing: 14) {
            PSNAvatarPreview(initials: profile.initials, imageURL: profile.avatarURL)
            VStack(alignment: .leading, spacing: 5) {
                Text(profile.onlineID)
                    .font(.system(size: 20, weight: .black, design: .monospaced))
                    .tracking(-0.6)
                    .foregroundStyle(TPPlayTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                HStack(spacing: 7) {
                    Rectangle().fill(TPPlayTheme.accent).frame(width: 7, height: 7)
                    Text("ONLINE // PLAYING \(profile.currentGame.uppercased())")
                        .lineLimit(1)
                }
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(TPPlayTheme.accent)
                Text(profile.realName.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.secondaryText)
                Text(profile.bio.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.tertiaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
    }

    private var levelBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TROPHY LEVEL")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundStyle(TPPlayTheme.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(profile.level)")
                    .font(.system(size: 34, weight: .black, design: .monospaced))
                    .tracking(-1.5)
                Text("LVL")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.accent)
            }
            .foregroundStyle(TPPlayTheme.primaryText)
            SegmentedProgress(value: profile.levelProgress, segments: 24)
            Text("\(Int(profile.levelProgress * 100))% // NEXT LEVEL")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(TPPlayTheme.tertiaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .background(TPPlayTheme.surfaceRaised)
        .overlay(alignment: .leading) {
            Rectangle().fill(TPPlayTheme.border).frame(width: 1)
        }
    }

    private var trophySummary: some View {
        VStack(spacing: 0) {
            HStack {
                Text("// TROPHY ARCHIVE")
                Spacer()
                Text("TOTAL \(profile.totalTrophies.formatted())")
                    .foregroundStyle(TPPlayTheme.primaryText)
            }
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(TPPlayTheme.accent)
            .padding(.horizontal, 14)
            .frame(height: 38)

            Rectangle().fill(TPPlayTheme.border).frame(height: 1)

            HStack(spacing: 0) {
                TrophyCountCell(type: .platinum, count: profile.platinum)
                TrophyCountCell(type: .gold, count: profile.gold)
                TrophyCountCell(type: .silver, count: profile.silver)
                TrophyCountCell(type: .bronze, count: profile.bronze)
            }
        }
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        HStack {
            Text("// \(title)")
            Spacer()
            Text(detail)
                .foregroundStyle(TPPlayTheme.secondaryText)
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .tracking(1)
        .foregroundStyle(TPPlayTheme.accent)
    }
}

private struct LibraryTrophyDetailView: View {
    let game: TrophyGamePreview
    let dismiss: () -> Void
    @State private var expandedGroupIDs: Set<String>

    init(game: TrophyGamePreview, dismiss: @escaping () -> Void) {
        self.game = game
        self.dismiss = dismiss
        _expandedGroupIDs = State(initialValue: Set(game.trophyGroups.map(\.id)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: dismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .black))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(AcidButtonStyle())
                TPPageHeader(game.name.uppercased())
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)
            .background(TPPlayTheme.canvas)
            .overlay(alignment: .bottom) {
                Rectangle().fill(TPPlayTheme.border).frame(height: 1)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    GameArchiveHeader(game: game)
                    TrophyBreakdownRow(breakdown: game.breakdown)

                    if game.hasDLCGroups {
                        sectionHeading("BASE + DLC TROPHY GROUPS")
                        ForEach(game.trophyGroups) { group in
                            TrophyGroupSection(
                                group: group,
                                isExpanded: expandedGroupIDs.contains(group.id)
                            ) {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    if expandedGroupIDs.contains(group.id) {
                                        expandedGroupIDs.remove(group.id)
                                    } else {
                                        expandedGroupIDs.insert(group.id)
                                    }
                                }
                            }
                        }
                    } else {
                        sectionHeading("TROPHY SIGNAL")
                        ForEach(game.trophies) { trophy in
                            TrophySignalRow(trophy: trophy)
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(TPPlayTheme.canvas)
        .libraryEdgeSwipeDismiss(dismiss)
    }

    private func sectionHeading(_ title: String) -> some View {
        HStack {
            Text("// \(title)")
            Spacer()
            Text("EARNED \(game.earned) / \(game.total)")
                .foregroundStyle(TPPlayTheme.secondaryText)
        }
        .font(.system(size: 9, weight: .black, design: .monospaced))
        .tracking(1)
        .foregroundStyle(TPPlayTheme.accent)
    }
}

private struct LibraryFrozenHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(TPPlayTheme.accent)
            Spacer()
        }
        .frame(height: 42)
    }
}

private struct LibrarySignedOutView: View {
    let isLoading: Bool
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            TPPageHeader("LIBRARY // TROPHIES")
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Text("// PSN DATA LINK")
                    .foregroundStyle(TPPlayTheme.accent)
                Text(isLoading ? "SYNCING TROPHY ARCHIVE..." : "SIGN IN TO PSN FROM HOME // CONFIG TO LOAD YOUR TROPHY ARCHIVE.")
                    .foregroundStyle(TPPlayTheme.primaryText)
                if let errorMessage {
                    Text("ERROR // \(errorMessage.uppercased())")
                        .foregroundStyle(TPPlayTheme.danger)
                }
            }
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .tracking(0.7)
            .padding(18)
            .frame(maxWidth: 560, alignment: .leading)
            .background(TPPlayTheme.surface)
            .overlay { Rectangle().stroke(errorMessage == nil ? TPPlayTheme.violet : TPPlayTheme.danger, lineWidth: 1) }
            .padding(20)
            Spacer()
        }
    }
}

private struct PSNAvatarPreview: View {
    let initials: String
    let imageURL: URL?

    var body: some View {
        ZStack {
            TPPlayTheme.canvas
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        avatarFallback
                    }
                }
            } else {
                avatarFallback
            }
            CornerBrackets()
                .stroke(TPPlayTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .butt, lineJoin: .miter))
                .padding(5)
        }
        .frame(width: 86, height: 86)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
        .accessibilityLabel("PSN profile avatar")
    }

    private var avatarFallback: some View {
        VStack(spacing: 2) {
            Image(systemName: "person.fill")
                .font(.system(size: 30, weight: .black))
            Text(initials)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(1)
        }
        .foregroundStyle(TPPlayTheme.primaryText)
    }
}

private struct TrophyCountCell: View {
    let type: TrophyTypePreview
    let count: Int

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                TrophyTypeGlyph(type: type, size: 14)
                Text(type.label)
            }
            .font(.system(size: 8, weight: .black, design: .monospaced))
            Text(count.formatted())
                .font(.system(size: 18, weight: .black, design: .monospaced))
        }
        .foregroundStyle(type.color)
        .frame(maxWidth: .infinity, minHeight: 70)
        .overlay(alignment: .leading) {
            Rectangle().fill(TPPlayTheme.border).frame(width: type == .platinum ? 0 : 1)
        }
    }
}

private struct TrophyGameCard: View {
    let game: TrophyGamePreview

    var body: some View {
        HStack(spacing: 14) {
            GameArchiveGlyph(code: game.archiveCode, imageURL: game.imageURL)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 6) {
                        Text(game.name.uppercased())
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundStyle(TPPlayTheme.primaryText)
                            .lineLimit(1)
                        if game.hasCompletionMark {
                            CompletionCheckmark()
                        }
                    }
                    Spacer(minLength: 8)
                    Text("\(Int(game.completion * 100))%")
                        .font(.system(size: 16, weight: .black, design: .monospaced))
                        .foregroundStyle(game.completion == 1 ? TPPlayTheme.accent : TPPlayTheme.primaryText)
                }
                SegmentedProgress(value: game.completion, segments: 28)
                HStack {
                    TrophyBreakdownCompact(breakdown: game.breakdown)
                    Spacer()
                    Text(game.lastPlayed.uppercased())
                        .foregroundStyle(TPPlayTheme.accent)
                }
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(TPPlayTheme.tertiaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }
}

private struct GameArchiveHeader: View {
    let game: TrophyGamePreview

    var body: some View {
        HStack(spacing: 16) {
            GameArchiveGlyph(code: game.archiveCode, imageURL: game.imageURL, large: true)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(game.name.uppercased())
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundStyle(TPPlayTheme.primaryText)
                        .lineLimit(1)
                    if game.hasCompletionMark {
                        CompletionCheckmark()
                    }
                    Spacer(minLength: 4)
                    Text(game.platform).libraryTag()
                }
                Text("\(game.earned) / \(game.total) TROPHIES")
                    .font(.system(size: 15, weight: .black, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.primaryText)
                HStack {
                    Text("\(Int(game.completion * 100))% COMPLETE")
                    Spacer()
                    Text("ARCHIVE // \(game.archiveCode)")
                        .foregroundStyle(TPPlayTheme.secondaryText)
                }
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(TPPlayTheme.accent)
                SegmentedProgress(value: game.completion, segments: 32)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }
}

private struct CompletionCheckmark: View {
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Rectangle()
                .fill(TPPlayTheme.accent)
            AngularCheckPath()
                .stroke(
                    TPPlayTheme.onAccent,
                    style: StrokeStyle(
                        lineWidth: max(2, size * 0.17),
                        lineCap: .butt,
                        lineJoin: .miter
                    )
                )
                .padding(size * 0.19)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
            .accessibilityLabel("Completion achieved")
    }
}

private struct AngularCheckPath: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private struct TrophyBreakdownCompact: View {
    let breakdown: TrophyBreakdownPreview

    var body: some View {
        HStack(spacing: 7) {
            compact("P", breakdown.platinum)
            compact("G", breakdown.gold)
            compact("S", breakdown.silver)
            compact("B", breakdown.bronze)
        }
    }

    private func compact(_ label: String, _ count: TrophyTypeCountPreview) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(TPPlayTheme.accent)
            Text("\(count.earned)/\(count.total)")
        }
    }
}

private struct TrophyBreakdownRow: View {
    let breakdown: TrophyBreakdownPreview

    var body: some View {
        HStack(spacing: 0) {
            TrophyProgressCell(type: .platinum, count: breakdown.platinum)
            TrophyProgressCell(type: .gold, count: breakdown.gold)
            TrophyProgressCell(type: .silver, count: breakdown.silver)
            TrophyProgressCell(type: .bronze, count: breakdown.bronze)
        }
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.border, lineWidth: 1) }
    }
}

private struct TrophyProgressCell: View {
    let type: TrophyTypePreview
    let count: TrophyTypeCountPreview

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                TrophyTypeGlyph(type: type, size: 14)
                Text(type.label)
            }
            Text("\(count.earned) / \(count.total)")
                .font(.system(size: 15, weight: .black, design: .monospaced))
        }
        .font(.system(size: 8, weight: .black, design: .monospaced))
        .foregroundStyle(type.color)
        .frame(maxWidth: .infinity, minHeight: 64)
        .overlay(alignment: .leading) {
            if type != .platinum {
                Rectangle().fill(TPPlayTheme.border).frame(width: 1)
            }
        }
    }
}

private struct TrophyGroupSection: View {
    let group: TrophyGroupPreview
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Text(group.name.uppercased())
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(group.earned) / \(group.total)")
                    Text("\(Int(group.completion * 100))%")
                        .foregroundStyle(group.completion == 1 ? TPPlayTheme.accent : TPPlayTheme.secondaryText)
                    Text(isExpanded ? "[−]" : "[+]")
                        .foregroundStyle(TPPlayTheme.accent)
                }
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(TPPlayTheme.primaryText)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(LibraryPressStyle())

            if isExpanded {
                ForEach(group.trophies) { trophy in
                    TrophySignalRow(trophy: trophy)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
    }
}

private struct TrophySignalRow: View {
    let trophy: TrophyPreview

    var body: some View {
        HStack(spacing: 0) {
            TrophyArtwork(trophy: trophy)
                .frame(width: 68)
                .frame(minHeight: 92)
                .background(TPPlayTheme.canvas)

            VStack(alignment: .leading, spacing: 6) {
                Text(trophy.name.uppercased())
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(TPPlayTheme.primaryText)
                    .lineLimit(1)
                Text(trophy.description.uppercased())
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(trophy.isEarned ? TPPlayTheme.secondaryText : TPPlayTheme.tertiaryText)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Text(trophy.rarityLabel)
                        .foregroundStyle(trophy.rarityColor)
                    Text(trophy.type.label)
                        .foregroundStyle(trophy.type.color)
                }
                .font(.system(size: 8, weight: .black, design: .monospaced))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)

            VStack(spacing: 7) {
                Text(trophy.isEarned ? "EARNED" : "LOCKED")
                if trophy.isEarned {
                    CompletionCheckmark(size: 16)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14, weight: .black))
                }
                Text(trophy.earnedAt?.uppercased() ?? "--")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(trophy.isEarned ? TPPlayTheme.accent : TPPlayTheme.tertiaryText)
            }
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .foregroundStyle(trophy.isEarned ? TPPlayTheme.accent : TPPlayTheme.secondaryText)
            .frame(width: 82)
            .frame(minHeight: 92)
            .background(trophy.isEarned ? TPPlayTheme.accent.opacity(0.055) : TPPlayTheme.surfaceRaised)
            .overlay(alignment: .leading) { Rectangle().fill(TPPlayTheme.border).frame(width: 1) }
        }
        .background(TPPlayTheme.surface)
        .overlay { Rectangle().stroke(trophy.isEarned ? TPPlayTheme.violet : TPPlayTheme.border.opacity(0.72), lineWidth: 1) }
        .opacity(trophy.isEarned ? 1 : 0.82)
    }
}

private struct TrophyTypeGlyph: View {
    let type: TrophyTypePreview
    let size: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .stroke(type.color, style: StrokeStyle(lineWidth: 1, lineCap: .butt, lineJoin: .miter))
                .frame(width: size, height: size)
            Text(type.symbol)
                .font(.system(size: size * 0.44, weight: .black, design: .monospaced))
                .foregroundStyle(type.color)
        }
    }
}

private struct GameArchiveGlyph: View {
    let code: String
    let imageURL: URL?
    var large = false

    var body: some View {
        ZStack {
            TPPlayTheme.canvas
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        archiveFallback
                    }
                }
            } else {
                archiveFallback
            }
        }
        .frame(width: large ? 84 : 72, height: large ? 84 : 72)
        .overlay { Rectangle().stroke(TPPlayTheme.violet, lineWidth: 1) }
        .clipped()
    }

    private var archiveFallback: some View {
        VStack(spacing: 5) {
            Image(systemName: "archivebox")
                .font(.system(size: large ? 28 : 20, weight: .black))
            Text(code)
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .tracking(0.5)
        }
        .foregroundStyle(TPPlayTheme.primaryText)
    }
}

private struct TrophyArtwork: View {
    let trophy: TrophyPreview

    var body: some View {
        ZStack {
            TPPlayTheme.canvas
            if let imageURL = trophy.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(8)
                    } else {
                        TrophyTypeGlyph(type: trophy.type, size: 42)
                    }
                }
            } else {
                TrophyTypeGlyph(type: trophy.type, size: 42)
            }
        }
        .clipped()
    }
}

private struct SegmentedProgress: View {
    let value: Double
    let segments: Int

    var body: some View {
        GeometryReader { geometry in
            let gap: CGFloat = 2
            let segmentWidth = max(1, (geometry.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments))
            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { index in
                    Rectangle()
                        .fill(Double(index) < value * Double(segments) ? TPPlayTheme.accent : TPPlayTheme.tertiaryText.opacity(0.55))
                        .frame(width: segmentWidth)
                }
            }
        }
        .frame(height: 8)
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.22
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        return path
    }
}

private struct LibraryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.68 : 1)
    }
}

private struct LibraryEdgeSwipeDismiss: ViewModifier {
    let dismiss: () -> Void
    @State private var dragOffset: CGFloat = 0
    @State private var isCompleting = false

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(x: dragOffset)
                .overlay(alignment: .leading) {
                    if !isCompleting {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: 28)
                            .gesture(edgeBackGesture(viewportWidth: geometry.size.width))
                            .accessibilityHidden(true)
                    }
                }
        }
    }

    private func edgeBackGesture(viewportWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard value.translation.width > 0,
                      abs(value.translation.height) < value.translation.width * 1.2 else { return }
                dragOffset = min(value.translation.width, viewportWidth)
            }
            .onEnded { value in
                let shouldClose = dragOffset > viewportWidth * 0.3
                    || value.predictedEndTranslation.width > viewportWidth * 0.55
                if shouldClose {
                    isCompleting = true
                    withAnimation(.easeOut(duration: 0.18)) {
                        dragOffset = viewportWidth
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        dismiss()
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        dragOffset = 0
                    }
                }
            }
    }
}

private extension View {
    func libraryTag() -> some View {
        self
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .foregroundStyle(TPPlayTheme.primaryText)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .overlay { Rectangle().stroke(TPPlayTheme.secondaryText, lineWidth: 1) }
    }

    func libraryEdgeSwipeDismiss(_ dismiss: @escaping () -> Void) -> some View {
        modifier(LibraryEdgeSwipeDismiss(dismiss: dismiss))
    }
}

struct PSNProfilePreview {
    let onlineID: String
    let realName: String
    let bio: String
    let currentGame: String
    let level: Int
    let levelProgress: Double
    let platinum: Int
    let gold: Int
    let silver: Int
    let bronze: Int
    let avatarURL: URL?

    var totalTrophies: Int { platinum + gold + silver + bronze }
    var initials: String {
        realName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    static let preview = PSNProfilePreview(
        onlineID: "VOID_RUNNER",
        realName: "Akira Mori",
        bio: "Trophy hunter. Night shift player.",
        currentGame: "Astro Bot",
        level: 342,
        levelProgress: 0.76,
        platinum: 18,
        gold: 94,
        silver: 286,
        bronze: 886
        , avatarURL: nil
    )
}

enum TrophyTypePreview: String, Codable {
    case platinum, gold, silver, bronze

    var label: String { rawValue.uppercased() }
    var symbol: String {
        switch self {
        case .platinum: "P"
        case .gold: "G"
        case .silver: "S"
        case .bronze: "B"
        }
    }
    var color: Color {
        switch self {
        case .platinum: Color(red: 0.78, green: 0.69, blue: 1)
        case .gold: Color(red: 1, green: 0.79, blue: 0.12)
        case .silver: Color(red: 0.72, green: 0.75, blue: 0.78)
        case .bronze: Color(red: 0.82, green: 0.42, blue: 0.20)
        }
    }
}

struct TrophyPreview: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let rarity: Double
    let type: TrophyTypePreview
    let isEarned: Bool
    let earnedAt: String?
    let imageURL: URL?

    init(name: String, description: String, rarity: Double, type: TrophyTypePreview, isEarned: Bool, earnedAt: String?, imageURL: URL? = nil) {
        self.name = name
        self.description = description
        self.rarity = rarity
        self.type = type
        self.isEarned = isEarned
        self.earnedAt = earnedAt
        self.imageURL = imageURL
    }

    var rarityLabel: String {
        let tier: String
        switch rarity {
        case ..<5: tier = "ULTRA RARE"
        case ..<20: tier = "VERY RARE"
        case ..<50: tier = "RARE"
        default: tier = "COMMON"
        }
        return "\(tier) // \(rarity.formatted(.number.precision(.fractionLength(1))))%"
    }

    var rarityColor: Color {
        rarity < 5 ? TrophyTypePreview.platinum.color : (rarity < 20 ? TPPlayTheme.violet : TPPlayTheme.secondaryText)
    }
}

struct TrophyGamePreview: Identifiable {
    let id = UUID()
    let name: String
    let platform: String
    let earned: Int
    let total: Int
    let lastPlayed: String
    let latestTrophy: String
    let archiveCode: String
    let breakdown: TrophyBreakdownPreview
    let trophyGroups: [TrophyGroupPreview]
    let imageURL: URL?

    init(name: String, platform: String, earned: Int, total: Int, lastPlayed: String, latestTrophy: String, archiveCode: String, breakdown: TrophyBreakdownPreview, trophyGroups: [TrophyGroupPreview], imageURL: URL? = nil) {
        self.name = name
        self.platform = platform
        self.earned = earned
        self.total = total
        self.lastPlayed = lastPlayed
        self.latestTrophy = latestTrophy
        self.archiveCode = archiveCode
        self.breakdown = breakdown
        self.trophyGroups = trophyGroups
        self.imageURL = imageURL
    }

    var completion: Double { total == 0 ? 0 : Double(earned) / Double(total) }
    var trophies: [TrophyPreview] { trophyGroups.flatMap(\.trophies) }
    var hasDLCGroups: Bool { trophyGroups.contains { !$0.isBaseGame } }
    var hasEarnedPlatinum: Bool { breakdown.platinum.earned > 0 }
    var hasCompletionMark: Bool { hasEarnedPlatinum || completion >= 0.999 }

    static let previews: [TrophyGamePreview] = [
        TrophyGamePreview(
            name: "Astro Bot",
            platform: "PS5",
            earned: 48,
            total: 51,
            lastPlayed: "2 hours ago",
            latestTrophy: "First Contact",
            archiveCode: "ASB-051",
            breakdown: .init(platinum: (1, 1), gold: (3, 5), silver: (10, 11), bronze: (34, 34)),
            trophyGroups: [
                TrophyGroupPreview(name: "Base Game", isBaseGame: true, earned: 43, total: 43, trophies: [
                    TrophyPreview(name: "Bot of War", description: "Rescued all bots in the crash site.", rarity: 3.2, type: .platinum, isEarned: true, earnedAt: "2 hours ago"),
                    TrophyPreview(name: "First Contact", description: "Found your first lost bot.", rarity: 76.4, type: .bronze, isEarned: true, earnedAt: "2 hours ago")
                ]),
                TrophyGroupPreview(name: "Stellar Speedway", isBaseGame: false, earned: 5, total: 8, trophies: [
                    TrophyPreview(name: "System Restored", description: "Completed the main mission.", rarity: 18.7, type: .gold, isEarned: true, earnedAt: "1 day ago"),
                    TrophyPreview(name: "Hidden Galaxy", description: "Found the secret galaxy.", rarity: 15.1, type: .silver, isEarned: false, earnedAt: nil)
                ])
            ]
        ),
        TrophyGamePreview(
            name: "Returnal",
            platform: "PS5",
            earned: 34,
            total: 51,
            lastPlayed: "1 day ago",
            latestTrophy: "Data Link",
            archiveCode: "RTN-051",
            breakdown: .init(platinum: (0, 1), gold: (2, 7), silver: (8, 12), bronze: (24, 31)),
            trophyGroups: [
                TrophyGroupPreview(name: "Base Game", isBaseGame: true, earned: 34, total: 51, trophies: [
                    TrophyPreview(name: "White Shadow", description: "Escape the cycle.", rarity: 6.7, type: .gold, isEarned: false, earnedAt: nil),
                    TrophyPreview(name: "Atropian Survival", description: "Learn the basics of survival.", rarity: 82.1, type: .bronze, isEarned: true, earnedAt: "1 week ago")
                ])
            ]
        ),
        TrophyGamePreview(
            name: "Ghost of Tsushima",
            platform: "PS4",
            earned: 77,
            total: 77,
            lastPlayed: "5 days ago",
            latestTrophy: "Living Legend",
            archiveCode: "GOT-077",
            breakdown: .init(platinum: (1, 1), gold: (2, 2), silver: (9, 9), bronze: (65, 65)),
            trophyGroups: [
                TrophyGroupPreview(name: "Base Game", isBaseGame: true, earned: 77, total: 77, trophies: [
                    TrophyPreview(name: "Living Legend", description: "Obtain all trophies.", rarity: 4.9, type: .platinum, isEarned: true, earnedAt: "5 days ago")
                ])
            ]
        )
    ]
}

struct TrophyTypeCountPreview {
    let earned: Int
    let total: Int
}

struct TrophyBreakdownPreview {
    let platinum: TrophyTypeCountPreview
    let gold: TrophyTypeCountPreview
    let silver: TrophyTypeCountPreview
    let bronze: TrophyTypeCountPreview

    init(
        platinum: (Int, Int),
        gold: (Int, Int),
        silver: (Int, Int),
        bronze: (Int, Int)
    ) {
        self.platinum = TrophyTypeCountPreview(earned: platinum.0, total: platinum.1)
        self.gold = TrophyTypeCountPreview(earned: gold.0, total: gold.1)
        self.silver = TrophyTypeCountPreview(earned: silver.0, total: silver.1)
        self.bronze = TrophyTypeCountPreview(earned: bronze.0, total: bronze.1)
    }
}

struct TrophyGroupPreview: Identifiable {
    let id: String
    let name: String
    let isBaseGame: Bool
    let earned: Int
    let total: Int
    let trophies: [TrophyPreview]

    init(name: String, isBaseGame: Bool, earned: Int, total: Int, trophies: [TrophyPreview]) {
        id = "\(isBaseGame ? "base" : "dlc")-\(name)"
        self.name = name
        self.isBaseGame = isBaseGame
        self.earned = earned
        self.total = total
        self.trophies = trophies
    }

    var completion: Double { total == 0 ? 0 : Double(earned) / Double(total) }
}
