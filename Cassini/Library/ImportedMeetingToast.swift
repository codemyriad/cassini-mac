// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Message comes from the shared WP7 catalog at the Library presentation site.
struct ImportedMeetingToast: View {
    let message: String
    let didAppear: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").font(.system(size: 14)).opacity(0.8).accessibilityHidden(true)
            Text(message).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("imported-notice-message")
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Circle())
            }.buttonStyle(.plain).foregroundStyle(CassiniTheme.onInverse.opacity(0.7))
                .accessibilityLabel(UXText.text("common.close"))
                .accessibilityIdentifier("imported-notice-close")
        }
        .padding(.vertical, 9).padding(.leading, 14).padding(.trailing, 10)
        .foregroundStyle(CassiniTheme.onInverse)
        .background(CassiniTheme.inverse, in: Capsule())
        .shadow(color: CassiniTheme.shadow, radius: 10, y: 8)
        .accessibilityElement(children: .contain).accessibilityIdentifier("imported-notice")
        .onAppear(perform: didAppear)
    }
}
