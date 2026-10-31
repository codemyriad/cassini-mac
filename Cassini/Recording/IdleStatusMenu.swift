// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

/// The document, voice rows and play badge from the app icon, drawn as a
/// monochrome template so macOS supplies the correct menu-bar appearance.
@MainActor private enum CassiniMenuGlyph {
    static let image: NSImage = {
        let image = NSImage(size:NSSize(width:20,height:18),flipped:false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor); context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(1.25)
            context.addPath(CGPath(roundedRect:CGRect(x:1.5,y:2,width:13,height:14),cornerWidth:2,cornerHeight:2,transform:nil)); context.strokePath()
            for y in [6.0,9.5,13.0] {
                context.fillEllipse(in:CGRect(x:4,y:y-0.7,width:1.4,height:1.4))
                context.fill(CGRect(x:7,y:y-0.55,width:y == 9.5 ? 4 : 5,height:1.1))
            }
            context.setBlendMode(.clear); context.fillEllipse(in:CGRect(x:10,y:0,width:10,height:10))
            context.setBlendMode(.normal); context.fillEllipse(in:CGRect(x:11,y:1,width:8,height:8))
            context.setBlendMode(.clear)
            context.move(to:CGPoint(x:14,y:2.6)); context.addLine(to:CGPoint(x:17.4,y:5)); context.addLine(to:CGPoint(x:14,y:7.4)); context.closePath(); context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct IdleStatusLabel: View {
    var body: some View {
        Image(nsImage:CassiniMenuGlyph.image)
            .accessibilityLabel(UXText.text("app.name"))
            .accessibilityIdentifier("idle-menu-bar")
            .help(UXText.text("hidden.status.watching"))
    }
}

struct IdleStatusMenu: View {
    @State private var hovered: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Text(UXText.text("hidden.status.watching")).foregroundStyle(.secondary)
            Divider()
            action("hidden.openCassini",id:"open") {
                dismiss(); LibrarySearchModel.shared.close(); MeetingNavigation.shared.back()
                ApplicationWindows.library(); NSApp.activate(ignoringOtherApps:true)
            }
            action("hidden.menu.settings",id:"settings") {
                dismiss(); NSApp.activate(ignoringOtherApps:true); openSettings()
            }
            Divider()
            action("hidden.menu.quit",id:"quit") { dismiss(); NSApp.activate(ignoringOtherApps:true); NSApp.terminate(nil) }
        }.buttonStyle(.plain).font(.system(size:13)).padding(14)
            .frame(width:300)
            .accessibilityElement(children:.contain).accessibilityIdentifier("idle-menu-payload")
    }
    private func action(_ title: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action:perform) {
            Text(UXText.text(title)).frame(maxWidth:.infinity,alignment:.leading)
                .padding(.horizontal,6).frame(height:24).contentShape(Rectangle())
        }.foregroundStyle(hovered == id ? Color.white : Color.primary)
            .background(hovered == id ? Color.accentColor : Color.clear,in:RoundedRectangle(cornerRadius:4))
            .onHover { hovered = $0 ? id : nil }.accessibilityIdentifier("idle-menu-" + id)
    }
}
