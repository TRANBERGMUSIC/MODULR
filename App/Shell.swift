// MODULR – app-skallen: sidebar med logo og værktøjer, opdateringsstatus og indholdsområdet.

import SwiftUI
import AppKit

extension Tool {
    var icon: String {
        switch self {
        case .library: return "square.stack.3d.down.right.fill"
        case .bitrate: return "waveform.badge.magnifyingglass"
        case .findBetter: return "sparkle.magnifyingglass"
        case .artwork: return "photo.stack"
        case .accounts: return "person.crop.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .library: return "Al din musik med BPM, toneart, energi og kvalitet – og direkte på USB til CDJ'en"
        case .bitrate: return "Afslør filer der er opkonverteret fra lav bitrate"
        case .findBetter: return "Find sangen gratis i bedre kvalitet fra kunstneren selv"
        case .artwork: return "Covers til rekordbox og CDJ – samlet, gemt og lagt på automatisk"
        case .accounts: return "Log ind én gang – så husker MODULR det"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var findBetter: FindBetterModel
    @AppStorage("ui.sidebarCollapsed") private var collapsed = false

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(collapsed: $collapsed)
                .frame(width: collapsed ? 64 : 236)
            Rectangle().fill(Color.hairline).frame(width: 1)
            ZStack(alignment: .top) {
                AppBackground()
                VStack(spacing: 0) {
                    UpdateBanner()
                    PageHeader(icon: model.tool.icon, title: model.tool.rawValue, subtitle: model.tool.subtitle) {
                        EmptyView()
                    }
                    ZStack {
                        Group {
                            switch model.tool {
                            case .library: LibraryView()
                            case .bitrate: ContentView()
                            case .findBetter: FindBetterToolView()
                            case .artwork: ArtworkToolView()
                            case .accounts: AccountsView()
                            }
                        }
                        .id(model.tool)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color.void)
        .overlay(DialogHost())
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.findBetterRequest) { url in
            if let url {
                findBetter.start(file: url)
                model.findBetterRequest = nil
            }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var findBetter: FindBetterModel
    @Binding var collapsed: Bool
    @Namespace private var selection

    var body: some View {
        if collapsed { compactBody } else { fullBody }
    }

    /// Foldet sammen: kun logo og ikoner (navnet vises når musen holdes over).
    var compactBody: some View {
        VStack(spacing: 6) {
            if let logo = BrandImages.logo {
                Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 34, height: 34)
                    .padding(.top, 40)
                    .padding(.bottom, 14)
            }
            ForEach(Tool.allCases) { t in
                SidebarItem(tool: t, active: model.tool == t, badge: badge(for: t), compact: true, ns: selection) {
                    withAnimation(Motion.snappy) { model.tool = t }
                }
            }
            Spacer()
            CompactUpdate()
            foldButton
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(Color.graphite)
    }

    var foldButton: some View {
        Button {
            withAnimation(Motion.smooth) { collapsed.toggle() }
        } label: {
            Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.mist.opacity(0.6))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Fold menuen ud" : "Fold menuen ind")
    }

    var fullBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand
            ZStack(alignment: .bottomLeading) {
                if let hero = BrandImages.hero {
                    Image(nsImage: hero)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(height: 150)
                        .clipped()
                        .opacity(0.55)
                        .overlay(LinearGradient(colors: [.clear, Color.graphite], startPoint: .top, endPoint: .bottom))
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let logo = BrandImages.logo {
                        Image(nsImage: logo)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(height: 34)
                    }
                    Text("MODULR")
                        .font(.system(size: 19, weight: .bold))
                        .tracking(5)
                        .foregroundColor(.mist)
                    Text("YOUR TOOLS. ONE PLATFORM.")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(2.6)
                        .foregroundColor(.mist.opacity(0.55))
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            .frame(height: 150)
            .clipped()

            Text("Værktøjer")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.mist.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)

            VStack(spacing: 3) {
                ForEach(Tool.allCases) { t in
                    SidebarItem(tool: t, active: model.tool == t, badge: badge(for: t), ns: selection) {
                        withAnimation(Motion.snappy) { model.tool = t }
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            HStack {
                Spacer()
                foldButton
            }
            .padding(.horizontal, 12)
            UpdatePill()
                .padding(12)
        }
        .background(Color.graphite)
    }

    func badge(for t: Tool) -> String? {
        switch t {
        case .bitrate:
            let n = model.fakeCount
            return n > 0 ? "\(n)" : nil
        case .findBetter:
            return findBetter.busy || findBetter.watchingDownloads ? "•" : nil
        case .library:
            let n = LibraryStore.shared.index.tracks.filter { $0.analyzed && ($0.needsFix || $0.needsUpgrade) }.count
            return n > 0 ? "\(n)" : nil
        default:
            return nil
        }
    }
}

struct SidebarItem: View {
    let tool: Tool
    let active: Bool
    let badge: String?
    var compact: Bool = false
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hover = false

    init(tool: Tool, active: Bool, badge: String?, compact: Bool = false, ns: Namespace.ID, action: @escaping () -> Void) {
        self.tool = tool
        self.active = active
        self.badge = badge
        self.compact = compact
        self.ns = ns
        self.action = action
    }

    /// Den markering der glider mellem punkterne (Apple-agtig, neutral – ikonet bærer accenten).
    @ViewBuilder
    func marker(_ radius: CGFloat) -> some View {
        if active {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.white.opacity(0.09))
                .matchedGeometryEffect(id: "sidebar-selection", in: ns)
        } else {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.white.opacity(hover ? 0.05 : 0))
        }
    }

    var body: some View {
        if compact {
            Button(action: action) {
                Image(systemName: tool.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(active ? AnyShapeStyle(Color.ember) : AnyShapeStyle(Color.mist.opacity(0.6)))
                    .symbolEffect(.bounce, value: active)
                    .frame(width: 44, height: 40)
                    .background(marker(9))
                    .animation(Motion.hover, value: hover)
                    .overlay(alignment: .topTrailing) {
                        if badge != nil { Circle().fill(Color.ember).frame(width: 7, height: 7).offset(x: -6, y: 6) }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(tool.rawValue)
        } else {
            full
        }
    }

    var full: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: tool.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(active ? AnyShapeStyle(Color.ember) : AnyShapeStyle(Color.mist.opacity(0.6)))
                    .symbolEffect(.bounce, value: active)
                Text(tool.rawValue)
                    .font(.system(size: 13, weight: active ? .semibold : .medium))
                    .foregroundColor(active ? .mist : .mist.opacity(0.7))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundColor(.void)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.ember))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(marker(9))
            .animation(Motion.hover, value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Opdatering når menuen er foldet ind: en pil når der er en ny version, ellers "søg efter opdateringer".
struct CompactUpdate: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        switch updater.status {
        case .available(let v):
            Button { updater.install() } label: {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 20)).foregroundColor(.ember)
            }
            .buttonStyle(.plain)
            .help("Version \(v) er klar – klik for at opdatere")
        case .working, .checking:
            ProgressView().controlSize(.small)
        default:
            Button { updater.check(manual: true) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold)).foregroundColor(.mist.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("v\(updater.currentVersion) – søg efter opdateringer")
        }
    }
}

/// Version og opdateringsstatus nederst i sidebaren.
/// Lille ember-prik der pulserer roligt.
struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        ZStack {
            Circle().fill(Color.ember.opacity(0.35)).frame(width: 12, height: 12)
                .scaleEffect(on ? 1.15 : 0.5).opacity(on ? 0 : 1)
            Circle().fill(Color.ember).frame(width: 7, height: 7)
        }
        .frame(width: 12, height: 12)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true }
        }
    }
}

struct UpdatePill: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        HStack(spacing: 8) {
            switch updater.status {
            case .available(let v):
                // To linjer, så intet brydes, uanset hvor smal sidebaren bliver
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        PulsingDot()
                        Text("Version \(v) er klar")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.mist)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                    }
                    Button { updater.install() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Opdatér nu").lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.ember)
                }
            case .working(let m):
                ProgressView().controlSize(.mini)
                Text(m).font(.system(size: 11)).foregroundColor(.mist.opacity(0.7)).lineLimit(1)
                Spacer()
            case .checking:
                ProgressView().controlSize(.mini)
                Text("Søger efter opdateringer …").font(.system(size: 11)).foregroundColor(.mist.opacity(0.6))
                Spacer()
            default:
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                Text("v\(updater.currentVersion)").font(.system(size: 11, weight: .medium)).foregroundColor(.mist.opacity(0.6))
                if let t = updater.lastChecked {
                    Text("· tjekket \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11)).foregroundColor(.mist.opacity(0.35))
                }
                Spacer()
                Button {
                    updater.check(manual: true)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.mist.opacity(0.6))
                .help("Søg efter opdateringer")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.hairline, lineWidth: 1))
    }
}
