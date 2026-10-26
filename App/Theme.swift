// MODULR – designsystem: knapper, paneler, sidehoveder og drop-zoner i brandets farver.
// Ember #FF6B00 · Amber #FFD166 · Mist #F5F5F5 · Graphite #1A1A1A · Void #0A0A0A

import SwiftUI
import AppKit

extension Color {
    static let panel = Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
    static let hairline = Color.white.opacity(0.07)
    // Flad ember (taste-skill: ingen gradienter på knapper og flader). Navnet bevares, så alt bruger samme farve.
    static let emberGradient = LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.06), Color(red: 1, green: 0.45, blue: 0.06)],
                                              startPoint: .top, endPoint: .bottom)
}

enum BrandImages {
    static let logo: NSImage? = Bundle.main.image(forResource: "logo")
    static let hero: NSImage? = Bundle.main.image(forResource: "hero")
}

// MARK: - Knapper

struct EmberButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.void)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.emberGradient)
                    .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.mist.opacity(enabled ? 0.9 : 0.35))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : (hover ? 0.08 : 0.04)))
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.hairline, lineWidth: 1))
            .onHover { hover = $0 }
    }
}

extension ButtonStyle where Self == EmberButtonStyle {
    static var ember: EmberButtonStyle { EmberButtonStyle() }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var ghost: GhostButtonStyle { GhostButtonStyle() }
}

// MARK: - Paneler

struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.045), Color.white.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
            )
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.hairline, lineWidth: 1))
    }
}

/// Topbjælke på hver side: titel, undertitel og handlinger.
struct PageHeader<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.ember)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.mist)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(.mist.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }
}

/// Stor drop-zone til tomme sider.
struct DropZone: View {
    let icon: String
    let title: String
    let subtitle: String
    let targeted: Bool
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.ember.opacity(targeted ? 0.25 : 0.1))
                    .frame(width: 92, height: 92)
                    .blur(radius: targeted ? 2 : 0)
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Color.emberGradient)
            }
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.mist)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(.mist.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.ember)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(targeted ? 0.05 : 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(targeted ? Color.ember : Color.white.opacity(0.12),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.2, dash: [7, 6]))
        )
        .padding(24)
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

/// Lille statistik-felt.
struct StatTile: View {
    let value: String
    let label: String
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent ? AnyShapeStyle(Color.emberGradient) : AnyShapeStyle(Color.mist))
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(.mist.opacity(0.45))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.hairline, lineWidth: 1))
    }
}

/// Baggrund: void med en svag ember-glød.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Color.void
            RadialGradient(colors: [Color.ember.opacity(0.10), .clear], center: .topTrailing, startRadius: 10, endRadius: 700)
            RadialGradient(colors: [Color.amber.opacity(0.04), .clear], center: .bottomLeading, startRadius: 10, endRadius: 600)
        }
        .ignoresSafeArea()
    }
}
