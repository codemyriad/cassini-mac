// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CassiniLibrary
import Observation
import SwiftUI

@MainActor @Observable
final class RecentlyDeletedModel {
    enum FailureKind {
        case restore
        case delete
    }

    static let shared = RecentlyDeletedModel()

    private(set) var entries: [TrashEntry] = []
    private(set) var busy = false
    private(set) var failure: FailureKind?
    var selectedId: String?

    @ObservationIgnored private var refreshGeneration = 0

    var failureMessage: String? {
        guard let failure else { return nil }
        switch failure {
        case .restore: return UXText.text("trash.restoreFailed")
        case .delete: return UXText.text("trash.deleteFailed")
        }
    }

    func dismissFailure() {
        failure = nil
    }

    private func currentRoots() -> (roots: [URL], access: LibraryAccess?) {
        let location = LibraryLocationModel.shared
        if location.available, let access = try? LibraryAccess(location.location, tolerateMissingPrevious: true) {
            return (access.roots, access)
        }
        let ctx = LibraryStore.shared.context
        return ([ctx.root] + ctx.previousRoots, nil)
    }

    func refresh() {
        Task { await refreshNow() }
    }

    func refreshNow() async {
        refreshGeneration &+= 1
        let gen = refreshGeneration
        let (roots, access) = currentRoots()
        let now = LibraryStore.shared.context.now ?? Date()
        let loaded = await Task.detached(priority: .userInitiated) { [access] () -> [TrashEntry] in
            defer { withExtendedLifetime(access) {} }
            var seenRoots = Set<String>()
            var all: [TrashEntry] = []
            for root in roots {
                let canon = LibraryLocation.canonical(root).path
                guard seenRoots.insert(canon).inserted else { continue }
                _ = try? LibraryTrash.purgeExpired(in: root, now: now)
                if let list = try? LibraryTrash.entries(in: root) {
                    all.append(contentsOf: list)
                }
            }
            all.sort { a, b in
                if a.deletedAtUtc != b.deletedAtUtc {
                    return a.deletedAtUtc > b.deletedAtUtc
                }
                return a.entryId > b.entryId
            }
            return all
        }.value

        guard gen == refreshGeneration else { return }
        entries = loaded
        if let selectedId, !loaded.contains(where: { $0.id == selectedId }) {
            self.selectedId = loaded.first?.id
        }
    }

    func restore(_ entry: TrashEntry) {
        guard !busy else { return }
        busy = true
        failure = nil
        let (_, access) = currentRoots()
        let untitled = UXText.text("library.untitled")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [access] in
                    defer { withExtendedLifetime(access) {} }
                    try LibraryTrash.restore(entryId: entry.entryId, in: entry.root, untitled: untitled)
                }.value
                await refreshNow()
                LibraryStore.shared.refresh()
            } catch {
                failure = .restore
                await refreshNow()
            }
            busy = false
        }
    }

    func deletePermanently(_ entry: TrashEntry) {
        guard !busy else { return }
        busy = true
        failure = nil
        let (_, access) = currentRoots()
        let untitled = UXText.text("library.untitled")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [access] in
                    defer { withExtendedLifetime(access) {} }
                    try LibraryTrash.purge(entryId: entry.entryId, in: entry.root, untitled: untitled)
                }.value
                await refreshNow()
            } catch {
                failure = .delete
                await refreshNow()
            }
            busy = false
        }
    }

    func deleteAll() {
        guard !busy, !entries.isEmpty else { return }
        busy = true
        failure = nil
        let (roots, access) = currentRoots()
        let untitled = UXText.text("library.untitled")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [access] in
                    defer { withExtendedLifetime(access) {} }
                    var seenRoots = Set<String>()
                    for root in roots {
                        let canon = LibraryLocation.canonical(root).path
                        guard seenRoots.insert(canon).inserted else { continue }
                        try LibraryTrash.emptyTrash(in: root, untitled: untitled)
                    }
                }.value
                await refreshNow()
            } catch {
                failure = .delete
                await refreshNow()
            }
            busy = false
        }
    }

    @discardableResult
    func promptDeleteSelected(window: NSWindow?) -> Bool {
        guard !busy,
              let selectedId,
              let entry = entries.first(where: { $0.id == selectedId }) else {
            return false
        }
        confirmDeletePermanently(entry, window: window)
        return true
    }

    /// HARMONY §7 Confirmation 4: Delete permanently. Both Return and Esc cancel.
    func confirmDeletePermanently(_ entry: TrashEntry, window: NSWindow?) {
        guard !busy else { return }
        let title = entry.display.title.isEmpty ? UXText.text("library.untitled") : entry.display.title
        presentDestructiveConfirmation(
            title: UXText.text("confirm.deletePermanently.title", ["title": title]),
            body: UXText.text("confirm.deletePermanently.body"),
            primaryTitle: UXText.text("confirm.deletePermanently.primary"),
            window: window
        ) { [weak self] confirmed in
            guard confirmed else { return }
            self?.deletePermanently(entry)
        }
    }

    /// HARMONY §7 Confirmation 5: Delete All. Both Return and Esc cancel.
    func confirmDeleteAll(window: NSWindow?) {
        guard !busy, !entries.isEmpty else { return }
        presentDestructiveConfirmation(
            title: UXText.text("confirm.emptyTrash.title"),
            body: UXText.text("confirm.emptyTrash.body"),
            primaryTitle: UXText.text("confirm.emptyTrash.primary"),
            window: window
        ) { [weak self] confirmed in
            guard confirmed else { return }
            self?.deleteAll()
        }
    }

    private func presentDestructiveConfirmation(
        title: String,
        body: String,
        primaryTitle: String,
        window: NSWindow?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = body

        let destructive = alert.addButton(withTitle: primaryTitle)
        destructive.hasDestructiveAction = true
        destructive.keyEquivalent = ""

        let cancel = alert.addButton(withTitle: UXText.text("common.cancel"))
        cancel.keyEquivalent = "\r"

        var monitor: Any?
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            if let token = monitor {
                NSEvent.removeMonitor(token)
                monitor = nil
            }
            completion(response == .alertFirstButtonReturn)
        }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard alert.window.isVisible else { return false }
                if let sheetParent = alert.window.sheetParent {
                    sheetParent.endSheet(alert.window, returnCode: .cancel)
                } else {
                    NSApp.stopModal(withCode: .cancel)
                }
                return true
            }
            return handled ? nil : event
        }

        if let window {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            let response = alert.runModal()
            finish(response)
        }
    }
}

struct RecentlyDeletedView: View {
    @State private var model = RecentlyDeletedModel.shared
    @State private var store = LibraryStore.shared
    @State private var hostWindow: NSWindow?

    private func rowSubtitle(for entry: TrashEntry) -> String {
        let format = store.format
        let now = store.context.now ?? Date()
        var parts: [String] = []
        if let recordedAt = entry.recordedAt {
            parts.append(format.previewSubtitle(recordedAt, durationMs: entry.display.durationMs.map(Int64.init)))
        } else if let ms = entry.display.durationMs {
            parts.append(LibraryFormat.meetingDuration(Int64(ms), locale: format.locale, language: format.language))
        }
        if let deletedAt = entry.deletedAt {
            let left = LibraryTrash.daysLeft(deletedAt: deletedAt, now: now)
            if left.daysLeft < 1 {
                parts.append(UXText.text("trash.row.lessThanDay"))
            } else {
                parts.append(UXText.text("trash.row.daysLeft", ["n": String(left.daysLeft)]))
            }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let _ = store.revision
        VStack(spacing: 0) {
            if let message = model.failureMessage {
                HStack(spacing: 12) {
                    Text(message)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .foregroundStyle(CassiniTheme.warnInk)
                .background(CassiniTheme.warnTint)
                .accessibilityIdentifier("recently-deleted-failure")
            }

            if model.entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "trash")
                        .font(.system(size: 30))
                        .foregroundStyle(CassiniTheme.ink3)
                        .accessibilityHidden(true)
                    Text(UXText.text("trash.empty"))
                        .font(.system(size: 14))
                        .foregroundStyle(CassiniTheme.ink2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CassiniTheme.windowGround)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("recently-deleted-empty")
            } else {
                HStack {
                    Text(UXText.text("trash.retentionNote"))
                        .font(.system(size: 12))
                        .foregroundStyle(CassiniTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(CassiniTheme.windowGround)
                .accessibilityIdentifier("trash-retention-note")

                Divider()

                List(selection: $model.selectedId) {
                    ForEach(model.entries) { entry in
                        let displayTitle = entry.display.title.isEmpty
                            ? UXText.text("library.untitled")
                            : entry.display.title
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayTitle)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(CassiniTheme.ink)
                                    .lineLimit(1)
                                Text(rowSubtitle(for: entry))
                                    .font(.system(size: 12))
                                    .foregroundStyle(CassiniTheme.ink2)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            HStack(spacing: 8) {
                                Button(UXText.text("trash.restore")) {
                                    model.restore(entry)
                                }
                                .disabled(model.busy)
                                .accessibilityIdentifier("trash-restore-\(entry.entryId)")

                                Button(UXText.text("trash.deletePermanently")) {
                                    model.confirmDeletePermanently(entry, window: hostWindow ?? NSApp.keyWindow)
                                }
                                .disabled(model.busy)
                                .foregroundStyle(CassiniTheme.error)
                                .accessibilityIdentifier("trash-delete-\(entry.entryId)")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 6)
                        .tag(entry.id)
                        .contextMenu {
                            Button(UXText.text("trash.restore")) {
                                model.restore(entry)
                            }
                            .disabled(model.busy)

                            Divider()

                            Button(UXText.text("trash.deletePermanently")) {
                                model.confirmDeletePermanently(entry, window: hostWindow ?? NSApp.keyWindow)
                            }
                            .disabled(model.busy)
                        }
                        .accessibilityIdentifier("trash-row-\(entry.entryId)")
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(CassiniTheme.windowGround)
                .accessibilityLabel(UXText.text("trash.list.a11y"))
                .accessibilityIdentifier("recently-deleted-list")
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(CassiniTheme.windowGround)
        .preferredColorScheme(
            LibraryLaunchContext.screenshotDark
                ? .dark
                : (LibraryLaunchContext.current.screenshot ? .light : nil)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(UXText.text("trash.emptyTrash")) {
                    model.confirmDeleteAll(window: hostWindow ?? NSApp.keyWindow)
                }
                .disabled(model.entries.isEmpty || model.busy)
                .accessibilityIdentifier("trash-delete-all")
            }
        }
        .background(WindowAccessor { window in
            guard let window else { return }
            hostWindow = window
            window.title = UXText.text("trash.title")
            window.setAccessibilityIdentifier("cassini-recently-deleted-window")
            RecordingConfirmation.attach(to: window)
        })
        .onAppear {
            model.dismissFailure()
            model.refresh()
        }
    }
}
