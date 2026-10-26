// MODULR – egne menuer og dialoger i brandets look (i stedet for macOS' grå standardmenuer).
//  • ModMenu: højreklik-menu i et svævende panel – mørk glas-flade, ember-kant og ember-markering.
//    Undermenuer foldes ud på stedet. Lukker ved klik udenfor, Esc, scroll eller når appen mister fokus.
//  • .modMenu { … } på en hvilken som helst visning og .background(RightClickArea …) på tabeller.
//  • ModMenuButton: knap der åbner samme menu under sig.
//  • Dialogs: bekræftelser og navne-dialoger som et kort midt i vinduet med dæmpet baggrund.

import SwiftUI
import AppKit

// MARK: - Menupunkter

struct MMItem: Identifiable {
    enum Kind {
        case action(() -> Void)
        case submenu([MMItem])
        case divider
        case header
    }

    let id = UUID()
    var title: String
    var icon: String?
    var destructive: Bool
    var enabled: Bool
    var kind: Kind

    static func action(_ title: String, icon: String? = nil, destructive: Bool = false, enabled: Bool = true,
                       _ run: @escaping () -> Void) -> MMItem {
        MMItem(title: title, icon: icon, destructive: destructive, enabled: enabled, kind: .action(run))
    }

    static func submenu(_ title: String, icon: String? = nil, _ items: [MMItem]) -> MMItem {
        MMItem(title: title, icon: icon, destructive: false, enabled: !items.isEmpty, kind: .submenu(tidy(items)))
    }

    static var divider: MMItem { MMItem(title: "", icon: nil, destructive: false, enabled: false, kind: .divider) }

    static func header(_ title: String) -> MMItem {
        MMItem(title: title, icon: nil, destructive: false, enabled: false, kind: .header)
    }

    var isDivider: Bool { if case .divider = kind { return true }; return false }

    /// Fjerner skillelinjer i starten, slutningen og dobbelte.
    static func tidy(_ items: [MMItem]) -> [MMItem] {
        var out = [MMItem]()
        for i in items {
            if i.isDivider && (out.isEmpty || out.last!.isDivider) { continue }
            out.append(i)
        }
        while out.last?.isDivider == true { out.removeLast() }
        return out
    }
}

// MARK: - Panelet

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct MenuSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

final class ModMenu {
    static let shared = ModMenu()
    static let pad: CGFloat = 18          // plads til skyggen rundt om kortet

    private var panel: MenuPanel?
    private var monitors: [Any] = []
    private var observer: NSObjectProtocol?
    private var openedAt: TimeInterval = -1
    private var anchor = NSPoint.zero

    var isOpen: Bool { panel != nil }

    /// Viser menuen med øverste venstre hjørne ved `point` (skærmkoordinater).
    func show(_ items: [MMItem], at point: NSPoint, event: NSEvent? = nil, title: String? = nil, subtitle: String? = nil) {
        close()
        let list = MMItem.tidy(items)
        guard !list.isEmpty else { return }
        openedAt = event?.timestamp ?? -1
        anchor = point

        let p = MenuPanel(contentRect: NSRect(x: point.x, y: point.y, width: 10, height: 10),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .popUpMenu
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = true
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]

        let card = MenuCard(items: list, title: title, subtitle: subtitle,
                            onResize: { [weak self] size in self?.place(size) },
                            onPick: { [weak self] run in
                                self?.close()
                                DispatchQueue.main.async(execute: run)
                            })
        let host = FirstMouseHostingView(rootView: card)
        p.contentView = host
        panel = p
        place(host.fittingSize)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }
        installMonitors()
    }

    func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func place(_ size: CGSize) {
        guard let p = panel, size.width > 1, size.height > 1 else { return }
        let pad = Self.pad
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 4000, height: 4000)
        let w = size.width
        let h = size.height
        var x = anchor.x - pad
        if x + w - pad > vf.maxX { x = anchor.x - w + pad }        // ingen plads til højre: åbn mod venstre
        x = max(vf.minX - pad, x)
        var y = anchor.y + pad - h                                   // kortets top ved musen
        if y + pad < vf.minY {                                       // ingen plads nedenunder: åbn opad
            y = min(anchor.y - pad, vf.maxY + pad - h)
            y = max(vf.minY - pad, y)
        }
        p.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    private func installMonitors() {
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { [weak self] e in
            guard let self, let p = self.panel else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53 { self.close(); return nil }     // Esc
                return e
            }
            if e.window === p { return e }
            if e.timestamp == self.openedAt { return e }
            self.close()
            // Klik udenfor lukker bare menuen (som macOS); højreklik må gerne åbne en ny
            return e.type == .rightMouseDown || e.type == .scrollWheel ? e : nil
        }
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
        monitors = [local, global].compactMap { $0 }
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.close()
        }
    }
}

// MARK: - Menu-kortet

struct MenuCard: View {
    let items: [MMItem]
    var title: String?
    var subtitle: String?
    let onResize: (CGSize) -> Void
    let onPick: (@escaping () -> Void) -> Void
    @State private var expanded: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let title {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color.mist)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(Color.mist.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 280, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 6)
                MenuDivider()
            }
            ForEach(items) { item in
                entry(item, depth: 0)
            }
        }
        .padding(5)
        .frame(minWidth: 236, alignment: .leading)
        .background(MenuCardBackground())
        .fixedSize()
        .padding(ModMenu.pad)
        .background(GeometryReader { g in Color.clear.preference(key: MenuSizeKey.self, value: g.size) })
        .onPreferenceChange(MenuSizeKey.self) { onResize($0) }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    func entry(_ item: MMItem, depth: Int) -> some View {
        switch item.kind {
        case .divider:
            MenuDivider()
        case .header:
            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.mist.opacity(0.35))
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
        case .action(let run):
            MenuRow(item: item, expanded: false, indent: depth) { onPick(run) }
        case .submenu(let children):
            let open: Bool = expanded == item.id
            MenuRow(item: item, expanded: open, indent: depth) {
                withAnimation(.easeOut(duration: 0.16)) { expanded = open ? nil : item.id }
            }
            if open {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(children) { child in
                        SubEntry(item: child, onPick: onPick)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.emberGradient).frame(width: 2).padding(.leading, 6).padding(.vertical, 3).opacity(0.7)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Et punkt i en udfoldet undermenu (undermenuer i undermenuer foldes også ud).
struct SubEntry: View {
    let item: MMItem
    let onPick: (@escaping () -> Void) -> Void
    @State private var open = false

    var body: some View {
        switch item.kind {
        case .divider:
            MenuDivider()
        case .header:
            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.mist.opacity(0.35))
                .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 2)
        case .action(let run):
            MenuRow(item: item, expanded: false, indent: 1) { onPick(run) }
        case .submenu(let children):
            VStack(alignment: .leading, spacing: 1) {
                MenuRow(item: item, expanded: open, indent: 1) {
                    withAnimation(.easeOut(duration: 0.16)) { open.toggle() }
                }
                if open {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(children) { c in SubEntry(item: c, onPick: onPick) }
                    }
                    .padding(.leading, 14)
                }
            }
        }
    }
}

struct MenuRow: View {
    let item: MMItem
    let expanded: Bool
    let indent: Int
    let tap: () -> Void
    @State private var hover = false

    var isSubmenu: Bool { if case .submenu = item.kind { return true }; return false }

    var foreground: Color {
        if !item.enabled { return Color.mist.opacity(0.28) }
        if hover { return item.destructive ? Color.white : Color.void }
        return item.destructive ? Color(red: 1, green: 0.42, blue: 0.36) : Color.mist
    }

    var fill: AnyShapeStyle {
        if hover && item.enabled {
            if item.destructive { return AnyShapeStyle(Color(red: 0.9, green: 0.22, blue: 0.2)) }
            return AnyShapeStyle(Color.emberGradient)
        }
        if expanded { return AnyShapeStyle(Color.white.opacity(0.06)) }
        return AnyShapeStyle(Color.clear)
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: item.icon ?? "circle")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16)
                .opacity(item.icon == nil ? 0 : (hover ? 1 : 0.85))
                .foregroundStyle(iconStyle)
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 20)
            if isSubmenu {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(0.6)
            }
        }
        .foregroundColor(foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
        .contentShape(Rectangle())
        .onHover { hover = $0 && item.enabled }
        .onTapGesture { if item.enabled { tap() } }
        .animation(.easeOut(duration: 0.08), value: hover)
    }

    var iconStyle: AnyShapeStyle {
        if hover || !item.enabled { return AnyShapeStyle(foreground) }
        if item.destructive { return AnyShapeStyle(Color(red: 1, green: 0.42, blue: 0.36)) }
        return AnyShapeStyle(Color.emberGradient)
    }
}

struct MenuDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

struct MenuCardBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        shape
            .fill(Color(white: 0.11))
            .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.55), radius: 16, y: 8)
    }
}

// MARK: - Højreklik

/// Usynlig visning der fanger højreklik (og ctrl-klik) inden for sit område. På en tabel får man rækkenummeret.
final class RightClickCatcherView: NSView {
    var handler: ((Int?, NSEvent) -> Bool)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] e in
            guard let self, let w = self.window, e.window === w, !self.isHiddenOrHasHiddenAncestor else { return e }
            if e.type == .leftMouseDown && !e.modifierFlags.contains(.control) { return e }
            let p = self.convert(e.locationInWindow, from: nil)
            guard self.bounds.contains(p), self.visibleRect.contains(p) else { return e }
            var row: Int?
            if let hit = w.contentView?.hitTest(e.locationInWindow) {
                var v: NSView? = hit
                while let cur = v, !(cur is NSTableView) { v = cur.superview }
                if let tv = v as? NSTableView {
                    let r = tv.row(at: tv.convert(e.locationInWindow, from: nil))
                    row = r >= 0 ? r : nil
                }
            }
            return (self.handler?(row, e) ?? false) ? nil : e
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}

struct RightClickArea: NSViewRepresentable {
    let handler: (Int?, NSEvent) -> Bool

    func makeNSView(context: Context) -> RightClickCatcherView {
        let v = RightClickCatcherView()
        v.handler = handler
        return v
    }

    func updateNSView(_ nsView: RightClickCatcherView, context: Context) {
        nsView.handler = handler
    }
}

extension View {
    /// Højreklik-menu i MODULRs look.
    func modMenu(title: String? = nil, subtitle: String? = nil, _ items: @escaping () -> [MMItem]) -> some View {
        background(RightClickArea { _, e in
            let list = items()
            guard !list.isEmpty else { return false }
            ModMenu.shared.show(list, at: NSEvent.mouseLocation, event: e, title: title, subtitle: subtitle)
            return true
        })
    }
}

// MARK: - Menuknap

final class MenuAnchorBox {
    weak var view: NSView?

    func show(_ items: [MMItem]) {
        guard let v = view, let w = v.window else { return }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        ModMenu.shared.show(items, at: NSPoint(x: r.minX - 4, y: r.minY - 4))
    }
}

final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct MenuAnchorView: NSViewRepresentable {
    let box: MenuAnchorBox

    func makeNSView(context: Context) -> PassthroughView {
        let v = PassthroughView()
        box.view = v
        return v
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        box.view = nsView
    }
}

/// Knap der åbner en MODULR-menu lige under sig.
struct ModMenuButton<Label: View>: View {
    let items: () -> [MMItem]
    let label: Label
    @State private var box = MenuAnchorBox()

    init(items: @escaping () -> [MMItem], @ViewBuilder label: () -> Label) {
        self.items = items
        self.label = label()
    }

    var body: some View {
        Button { box.show(items()) } label: { label }
            .buttonStyle(.plain)
            .background(MenuAnchorView(box: box))
    }
}

// MARK: - Dialoger

struct DialogRequest: Identifiable {
    enum Kind {
        case confirm(button: String, destructive: Bool, action: () -> Void, cancel: (() -> Void)?)
        case name(NamePrompt)
    }

    let id = UUID()
    var icon: String
    var title: String
    var message: String
    var kind: Kind
}

final class Dialogs: ObservableObject {
    static let shared = Dialogs()
    @Published var current: DialogRequest?

    func confirm(_ title: String, message: String, icon: String = "questionmark.circle.fill", button: String,
                 destructive: Bool = false, cancel: (() -> Void)? = nil, _ action: @escaping () -> Void) {
        ModMenu.shared.close()
        current = DialogRequest(icon: icon, title: title, message: message,
                                kind: .confirm(button: button, destructive: destructive, action: action, cancel: cancel))
    }

    func name(_ prompt: NamePrompt) {
        ModMenu.shared.close()
        current = DialogRequest(icon: prompt.icon, title: prompt.title, message: "", kind: .name(prompt))
    }

    func dismiss(cancelled: Bool) {
        if cancelled, let d = current, case .confirm(_, _, _, let cancel) = d.kind { cancel?() }
        current = nil
    }
}

/// Lægges over hele vinduet (RootView): dæmpet baggrund og et kort i midten.
struct DialogHost: View {
    @ObservedObject private var dialogs = Dialogs.shared

    var body: some View {
        ZStack {
            if let d = dialogs.current {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dialogs.dismiss(cancelled: true) }
                    .transition(.opacity)
                card(d)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: dialogs.current?.id)
    }

    @ViewBuilder
    func card(_ d: DialogRequest) -> some View {
        switch d.kind {
        case .name(let prompt):
            NameSheet(prompt: prompt) { dialogs.dismiss(cancelled: false) }
                .dialogCard()
                .id(d.id)
        case .confirm(let button, let destructive, let action, _):
            ConfirmCard(request: d, button: button, destructive: destructive,
                        confirm: {
                            dialogs.dismiss(cancelled: false)
                            DispatchQueue.main.async(execute: action)
                        },
                        cancel: { dialogs.dismiss(cancelled: true) })
                .dialogCard()
                .id(d.id)
        }
    }
}

struct ConfirmCard: View {
    let request: DialogRequest
    let button: String
    let destructive: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(destructive ? Color.red.opacity(0.16) : Color.ember.opacity(0.15))
                    Image(systemName: request.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(destructive ? AnyShapeStyle(Color(red: 1, green: 0.42, blue: 0.36)) : AnyShapeStyle(Color.emberGradient))
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color.mist)
                    if !request.message.isEmpty {
                        Text(request.message)
                            .font(.system(size: 13))
                            .foregroundColor(Color.mist.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Annullér", action: cancel)
                    .buttonStyle(.ghost)
                    .keyboardShortcut(.cancelAction)
                if destructive {
                    Button(button, action: confirm)
                        .buttonStyle(DangerButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(button, action: confirm)
                        .buttonStyle(.ember)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.88, green: 0.22, blue: 0.2))
                .opacity(configuration.isPressed ? 0.75 : 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

extension View {
    /// Kortet bag en dialog: mørk flade, ember-kant og dyb skygge.
    func dialogCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return self
            .background(shape.fill(Color(white: 0.11)))
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.6), radius: 30, y: 12)
    }
}

// MARK: - Segmentvælger

/// Fanevælger i MODULRs look (ember-markering der glider mellem valgene).
struct ModSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]
    @Namespace private var ns

    init(selection: Binding<T>, options: [(T, String)]) {
        _selection = selection
        self.options = options
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let value: T = options[i].0
                let on: Bool = value == selection
                Text(options[i].1)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(on ? Color.void : Color.mist.opacity(0.7))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.emberGradient)
                                .matchedGeometryEffect(id: "seg", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { selection = value }
                    }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.hairline, lineWidth: 1))
    }
}
