// MODULR – fortryd og gentag (⌘Z / ⇧⌘Z) for alt du retter på en sang: hot cues, memory cues, grid,
// sektioner, EQ og EQ-områder. Ét fælles forløb, som i rekordbox. Hurtige ændringer af samme slags
// (fx en knap der drejes, eller en sektionsgrænse der trækkes) bliver til ét skridt.

import Foundation
import SwiftUI

/// De dele af en sang du selv kan rette.
struct TrackEditState: Equatable {
    var bpm: Double?
    var firstBeatMs: Double?
    var gridEdited: Bool?
    var cues: [Double]?
    var hotCues: [String: Double]?
    var eqRegions: [EQRegionData]?
    var sections: [SongSection]?

    init(_ t: LibTrack) {
        bpm = t.bpm
        firstBeatMs = t.firstBeatMs
        gridEdited = t.gridEdited
        cues = t.cues
        hotCues = t.hotCues
        eqRegions = t.eqRegions
        sections = t.sections
    }

    func apply(to t: inout LibTrack) {
        t.bpm = bpm
        t.firstBeatMs = firstBeatMs
        t.gridEdited = gridEdited
        t.cues = cues
        t.hotCues = hotCues
        t.eqRegions = eqRegions
        t.sections = sections
    }
}

final class EditHistory: ObservableObject {
    static let shared = EditHistory()

    enum Change: Equatable {
        case track(before: TrackEditState, after: TrackEditState)
        case eq(before: EQSettings, after: EQSettings)
    }

    struct Step: Identifiable {
        let id = UUID()
        var track: UUID
        var label: String
        var change: Change
        var at: Date
    }

    @Published private(set) var undoStack: [Step] = []
    @Published private(set) var redoStack: [Step] = []
    private var restoring = false
    static let maxSteps = 300
    static let mergeWindow: TimeInterval = 1.2

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoLabel: String? { undoStack.last.map { "Fortryd: \($0.label)" } }
    var redoLabel: String? { redoStack.last.map { "Gentag: \($0.label)" } }

    // MARK: Optag

    func record(track: UUID, label: String, before: TrackEditState, after: TrackEditState) {
        guard before != after else { return }
        push(Step(track: track, label: label, change: .track(before: before, after: after), at: Date()))
    }

    func recordEQ(track: UUID, before: EQSettings, after: EQSettings) {
        guard before != after else { return }
        push(Step(track: track, label: "EQ", change: .eq(before: before, after: after), at: Date()))
    }

    private func push(_ step: Step) {
        let go = { [self] in
            guard !restoring else { return }
            // Samme slags ændring lige efter den forrige (knap der drejes, grænse der trækkes) → ét skridt
            if var last = undoStack.last, last.track == step.track, last.label == step.label,
               step.at.timeIntervalSince(last.at) < Self.mergeWindow {
                switch (last.change, step.change) {
                case (.track(let b, _), .track(_, let a)): last.change = .track(before: b, after: a)
                case (.eq(let b, _), .eq(_, let a)): last.change = .eq(before: b, after: a)
                default: undoStack.append(step); redoStack.removeAll(); trim(); return
                }
                last.at = step.at
                undoStack[undoStack.count - 1] = last
            } else {
                undoStack.append(step)
                trim()
            }
            redoStack.removeAll()
        }
        if Thread.isMainThread { go() } else { DispatchQueue.main.async(execute: go) }
    }

    private func trim() {
        if undoStack.count > Self.maxSteps { undoStack.removeFirst(undoStack.count - Self.maxSteps) }
    }

    // MARK: Fortryd / gentag

    func undo() {
        guard let s = undoStack.popLast() else { return }
        apply(s, forward: false)
        redoStack.append(s)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        apply(s, forward: true)
        undoStack.append(s)
    }

    private func apply(_ s: Step, forward: Bool) {
        restoring = true
        defer { restoring = false }
        let lib = LibraryStore.shared
        switch s.change {
        case .track(let b, let a):
            let state = forward ? a : b
            lib.update(s.track) { state.apply(to: &$0) }
        case .eq(let b, let a):
            let p = PlayerModel.shared
            if p.track?.id == s.track { p.eq = forward ? a : b }
        }
        lib.lastMessage = "\(forward ? "Gentaget" : "Fortrudt"): \(s.label)"
        // Hop hen til sangen, hvis det er en anden end den der spiller
        if PlayerModel.shared.track?.id != s.track, let t = lib.index.track(s.track) {
            lib.lastMessage! += " (\(t.title))"
        }
    }

    /// Bruges af afspilleren, så EQ der sættes tilbage ved fortryd ikke selv bliver et nyt skridt.
    var isRestoring: Bool { restoring }
}

extension LibraryStore {
    /// Som `update`, men kan fortrydes: før og efter gemmes i fortryd-forløbet.
    func edit(_ id: UUID, _ label: String, _ change: (inout LibTrack) -> Void) {
        guard let current = snapshot().track(id) else { return }
        let before = TrackEditState(current)
        var probe = current
        change(&probe)
        let after = TrackEditState(probe)
        update(id, change)
        EditHistory.shared.record(track: id, label: label, before: before, after: after)
    }
}

/// Fortryd- og gentag-knapperne (bruges i afspilleren).
struct UndoRedoButtons: View {
    @ObservedObject private var history = EditHistory.shared

    var body: some View {
        HStack(spacing: 2) {
            button("arrow.uturn.backward", help: history.undoLabel.map { "\($0)  (⌘Z)" } ?? "Intet at fortryde",
                   enabled: history.canUndo) { history.undo() }
            button("arrow.uturn.forward", help: history.redoLabel.map { "\($0)  (⇧⌘Z)" } ?? "Intet at gentage",
                   enabled: history.canRedo) { history.redo() }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))
    }

    func button(_ icon: String, help: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.mist.opacity(enabled ? 0.9 : 0.3))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .disabled(!enabled)
        .help(help)
    }
}
