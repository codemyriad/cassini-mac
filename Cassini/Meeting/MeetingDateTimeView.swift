// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

struct MeetingDateTimeView: View {
    @State private var coordinator = MeetingDateTimeCoordinator.shared
    private var timeZone: TimeZone { LibraryStore.shared.format.timeZone }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(UXText.text("meeting.setDateTime.title"))
                    .font(.system(size: 18, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                if coordinator.fromFileSavedTime {
                    Text(UXText.text("meeting.setDateTime.prefillSavedHint"))
                        .font(.system(size: 12))
                        .foregroundStyle(CassiniTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("set-date-time-hint")
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(UXText.text("meeting.setDateTime.dateLabel") + ":")
                        .gridColumnAlignment(.trailing)
                    SystemDatePickerField(
                        date: $coordinator.selectedDay,
                        mode: .date,
                        timeZone: timeZone,
                        enabled: !coordinator.working,
                        accessibilityID: "set-date-time-date",
                        accessibilityLabel: UXText.text("meeting.setDateTime.dateLabel"),
                        cancel: { coordinator.cancel() },
                        confirm: { coordinator.apply() }
                    )
                    .fixedSize()
                }
                GridRow {
                    Text(UXText.text("meeting.setDateTime.timeLabel") + ":")
                        .gridColumnAlignment(.trailing)
                    SystemDatePickerField(
                        date: $coordinator.selectedClock,
                        mode: .time,
                        timeZone: timeZone,
                        enabled: !coordinator.working,
                        accessibilityID: "set-date-time-time",
                        accessibilityLabel: UXText.text("meeting.setDateTime.timeLabel"),
                        cancel: { coordinator.cancel() },
                        confirm: { coordinator.apply() }
                    )
                    .fixedSize()
                }
            }

            HStack(spacing: 10) {
                Spacer()
                if coordinator.working { ProgressView().controlSize(.small) }
                Button(UXText.text("common.cancel")) { coordinator.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(coordinator.working)
                    .accessibilityIdentifier("set-date-time-cancel")
                Button(UXText.text("savedVoices.rename.save")) { coordinator.apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(coordinator.working)
                    .accessibilityIdentifier("set-date-time-save")
            }
        }
        .font(.system(size: 13))
        .padding(24)
        .frame(width: 400)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("set-date-time-meeting")
        .onExitCommand { if !coordinator.working { coordinator.cancel() } }
    }
}

private struct SystemDatePickerField: NSViewRepresentable {
    enum Mode { case date, time }

    @Binding var date: Date
    let mode: Mode
    let timeZone: TimeZone
    let enabled: Bool
    let accessibilityID: String
    let accessibilityLabel: String
    let cancel: () -> Void
    let confirm: () -> Void

    final class Picker: NSDatePicker {
        var onCancel: (() -> Void)?
        var onConfirm: (() -> Void)?
        var focusInitially = false
        private var didFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard focusInitially, window != nil, !didFocus else { return }
            didFocus = true
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76 {
                onConfirm?()
                return
            }
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            super.keyDown(with: event)
        }
    }

    final class Coordinator: NSObject {
        var parent: SystemDatePickerField
        init(_ parent: SystemDatePickerField) { self.parent = parent }
        @objc func valueChanged(_ sender: NSDatePicker) {
            parent.date = sender.dateValue
        }
    }

    func makeCoordinator() -> Coordinator { .init(self) }

    func makeNSView(context: Context) -> Picker {
        let picker = Picker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.datePickerElements = mode == .date ? .yearMonthDay : .hourMinute
        picker.presentsCalendarOverlay = mode == .date
        picker.focusInitially = mode == .date
        picker.locale = UXText.locale
        picker.calendar = Calendar(identifier: .gregorian)
        picker.timeZone = timeZone
        picker.dateValue = date
        picker.isEnabled = enabled
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.valueChanged(_:))
        picker.onCancel = cancel
        picker.onConfirm = confirm
        picker.setAccessibilityIdentifier(accessibilityID)
        picker.setAccessibilityLabel(accessibilityLabel)
        return picker
    }

    func updateNSView(_ picker: Picker, context: Context) {
        context.coordinator.parent = self
        picker.onCancel = cancel
        picker.onConfirm = confirm
        picker.timeZone = timeZone
        picker.locale = UXText.locale
        if abs(picker.dateValue.timeIntervalSince(date)) >= 0.5 {
            picker.dateValue = date
        }
        picker.isEnabled = enabled
    }
}
