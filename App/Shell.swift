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

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 236)
            Rectangle().fill(Color.hairline).frame(width: 1)
            ZStack(alignment: .top) {
                AppBackground()
                VStack(spacing: 0) {
                    UpdateBanner()
                    PageHeader(icon: model.tool.icon, title: model.tool.rawValue, subtitle: model.tool.subtitle) {
                        EmptyView()
                    }
                    Group {
                        switch model.tool {
                        case .library: LibraryView()
                        case .bitrate: ContentView()
                        case .findBetter: FindBetterToolView()
                        case .artwork: ArtworkToolView()
                        case .accounts: AccountsView()
                        }
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

    var body: some View {
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

            Text("VÆRKTØJER")
                .font(.system(size: 9, weight: .bold))
                .tracking(2)
                .foregroundColor(.mist.opacity(0.35))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)

            VStack(spacing: 3) {
                ForEach(Tool.allCases) { t in
                    SidebarItem(tool: t, active: model.tool == t, badge: badge(for: t)) {
                        withAnimation(.easeOut(duration: 0.15)) { model.tool = t }
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

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
            let n = LibraryStore.shared.index.tracks.filter { $0.analyzed && $0.needsFix }.count
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
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: tool.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                    .foregroundStyle(active ? AnyShapeStyle(Color.emberGradient) : AnyShapeStyle(Color.mist.opacity(0.6)))
                Text(tool.rawValue)
                    .font(.system(size: 13, weight: active ? .semibold : .medium))
                    .foregroundColor(active ? .mist : .mist.opacity(0.7))
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.void)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.ember))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? Color.ember.opacity(0.13) : Color.white.opacity(hover ? 0.05 : 0))
            )
            .overlay(alignment: .leading) {
                if active {
                    Capsule().fill(Color.emberGradient).frame(width: 3, height: 18).offset(x: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Version og opdateringsstatus nederst i sidebaren.
struct UpdatePill: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        HStack(spacing: 8) {
            switch updater.status {
            case .available(let v):
                Circle().fill(Color.ember).frame(width: 7, height: 7)
                Text("Version \(v) er klar").font(.system(size: 11, weight: .semibold)).foregroundColor(.mist)
                Spacer()
                Button("Opdatér") { updater.install() }
                    .buttonStyle(.ember)
                    .controlSize(.small)
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
