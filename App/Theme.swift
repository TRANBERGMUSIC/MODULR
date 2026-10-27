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

// MARK: - Motion (Apple-fjedre + taste-skill: stærk ease-out, ingen hop, kort under hånden)

enum Motion {
    /// Tryk på knapper og pads (100–160 ms)
    static let press = Animation.easeOut(duration: 0.12)
    /// Hover-farver og små skift (150–200 ms)
    static let hover = Animation.easeOut(duration: 0.18)
    /// Valg, faner, sidebar-markør – Apples "snappy" fjeder uden overshoot
    static let snappy = Animation.snappy(duration: 0.32, extraBounce: 0)
    /// Paneler og sideskift
    static let smooth = Animation.smooth(duration: 0.45, extraBounce: 0)
    /// Signatur: waveform der skrives ind, cover der åbner (expo-out)
    static let reveal = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.9)
}

/// Indgang: delen stiger 10 pt op og toner ind, én gang (eller igen når `trigger` skifter).
/// Med "Reducér bevægelse" slået til vises den bare.
struct Entrance: ViewModifier {
    let delay: Double
    let trigger: AnyHashable
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduce ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 10)
            .onAppear { play() }
            .onChange(of: trigger) { _, _ in
                shown = false
                play()
            }
    }

    private func play() {
        guard !reduce else { shown = true; return }
        withAnimation(Motion.smooth.delay(delay)) { shown = true }
    }
}

/// Waveform-signaturen: indholdet "skrives" ind fra venstre, når en ny sang loades.
struct RevealWipe: ViewModifier {
    let trigger: AnyHashable
    @State private var progress: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                GeometryReader { g in
                    Rectangle().frame(width: max(0, g.size.width * progress))
                }
            }
            .onChange(of: trigger) { _, _ in
                guard !reduce else { return }
                progress = 0
                withAnimation(Motion.reveal) { progress = 1 }
            }
    }
}

/// Lille løft og lysning når musen holdes over (kort, Apple-agtigt).
struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.02
    @State private var hover = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? scale : 1)
            .brightness(hover ? 0.04 : 0)
            .animation(Motion.hover, value: hover)
            .onHover { hover = $0 }
    }
}

extension View {
    func entrance(delay: Double = 0, trigger: AnyHashable = AnyHashable(0)) -> some View {
        modifier(Entrance(delay: delay, trigger: trigger))
    }

    func revealWipe(trigger: AnyHashable) -> some View {
        modifier(RevealWipe(trigger: trigger))
    }

    func hoverLift(_ scale: CGFloat = 1.02) -> some View {
        modifier(HoverLift(scale: scale))
    }
}

enum BrandImages {
    static let logo: NSImage? = Bundle.main.image(forResource: "logo")
    static let hero: NSImage? = Bundle.main.image(forResource: "hero")
}

// MARK: - Knapper

struct EmberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        EmberButtonBody(configuration: configuration)
    }
}

struct EmberButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.void)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ember)
                    .brightness(enabled && hover && !configuration.isPressed ? 0.06 : 0)
                    .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .animation(Motion.hover, value: hover)
            .onHover { hover = $0 }
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
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .animation(Motion.hover, value: hover)
            .onHover { hover = $0 }
    }
}

/// Knap der giver efter under fingeren (som en fysisk knap): skaleres ned ved tryk, lyser lidt ved hover.
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .hoverLift(1.06)
    }
}

extension ButtonStyle where Self == PressScaleStyle {
    static var press: PressScaleStyle { PressScaleStyle() }
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
                    .fill(Color.white.opacity(0.035))
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.ember)
                .symbolEffect(.bounce, value: title)
                .entrance(trigger: title)
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.3)
                .foregroundColor(.mist)
                .entrance(delay: 0.04, trigger: title)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundColor(.mist.opacity(0.6))
                .lineLimit(1)
                .entrance(delay: 0.1, trigger: title)
            Spacer(minLength: 12)
            actions
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
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
                    .fill(Color.ember.opacity(targeted ? 0.18 : 0.1))
                    .frame(width: 92, height: 92)
                Image(systemName: icon)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Color.ember)
                    .symbolEffect(.bounce, value: targeted)
            }
            .scaleEffect(targeted ? 1.06 : 1)
            .entrance()
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
        .animation(Motion.snappy, value: targeted)
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
                .contentTransition(.numericText())
                .animation(Motion.snappy, value: value)
                .foregroundStyle(accent ? AnyShapeStyle(Color.emberGradient) : AnyShapeStyle(Color.mist))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.mist.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.hairline, lineWidth: 1))
    }
}

/// Baggrund: flad void (ingen glød – fladerne skilles af tone-trin).
struct AppBackground: View {
    var body: some View {
        Color.void
            .ignoresSafeArea()
    }
}
