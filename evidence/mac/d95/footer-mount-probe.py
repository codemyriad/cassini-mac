from pathlib import Path
import subprocess
import os
root=Path(__file__).resolve().parents[3]
out=Path(os.environ['D95_FOOTER_EVIDENCE_DIR']).expanduser().resolve()
assert root not in (out,*out.parents), 'Use an external evidence directory'
out.mkdir(parents=True,exist_ok=True)
source=(root/'Cassini/Library/LibraryView.swift').read_text()
footer=source[source.index('struct UpdateReadyFooter: View {'):]
(out/'main.swift').write_text('''import AppKit
import SwiftUI
import Observation
import Darwin
@MainActor @Observable final class ApplicationUpdates { var readyWhenIdle = true }
enum UXText { static func text(_ key: String) -> String { "Update ready when idle" } }
enum LibraryTheme { static let dim = Color.secondary }
'''+footer+'''
@MainActor final class Signal {
 var seen=Set<Bool>(),pending:[Bool:CheckedContinuation<Void,Error>]=[:]
 func send(_ value:Bool) { if let c=pending.removeValue(forKey:value) { c.resume() } else { seen.insert(value) } }
 func wait(_ value:Bool) async throws {
  if seen.remove(value) != nil { return }
  try await withCheckedThrowingContinuation { c in
   pending[value]=c
   DispatchQueue.main.asyncAfter(deadline:.now()+5) { [self] in
    pending.removeValue(forKey:value)?.resume(throwing:NSError(domain:"Missing footer mount/removal",code:1))
   }
  }
 }
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
 do {
  for mode in ["detach","hide","ancestor-hide"] {
   var events:[Bool]=[]
   let mount=UpdateFooterVisibility.Mount(changed:{events.append($0)})
   mount.viewDidMoveToWindow()
   mount.removed()
   assert(events.isEmpty,"An initial nil window must not prove removal")
   let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:70),styleMask:[.titled],backing:.buffered,defer:false)
   let container=NSView(frame:NSRect(x:0,y:0,width:600,height:70));container.addSubview(mount)
   window.isReleasedWhenClosed=false;window.contentView=container;window.orderFront(nil)
   assert(events==[true],"Native mount precedes removal")
   if mode=="hide" {mount.isHidden=true} else if mode=="ancestor-hide" {container.isHidden=true} else {mount.removeFromSuperview()}
   assert(events==[true,false],"Native hiding or detachment must signal removal")
   mount.removed()
   assert(events==[true,false],"Removal is one-shot")
   window.close()
  }
  for i in 0..<40 {
   let updates=ApplicationUpdates(),signal=Signal()
   let footer=NSHostingView(rootView:UpdateReadyFooter(updates:updates,fixtureVisibility:{signal.send($0)}))
   let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:70),styleMask:[.titled],backing:.buffered,defer:false)
   window.isReleasedWhenClosed=false;window.contentView=footer;window.orderFront(nil)
   footer.layoutSubtreeIfNeeded()
   try await signal.wait(true)
   updates.readyWhenIdle=false
   try await signal.wait(false)
   assert(!updates.readyWhenIdle)
   window.close()
   print("mounted footer removed",i)
  }
  exit(0)
 } catch { fputs("FAILED: \\(error)\\n",stderr);exit(1) }
}
app.run()
''')
subprocess.run(['xcrun','swiftc','-D','DEBUG','-g',str(out/'main.swift'),'-o',str(out/'probe')],check=True)
subprocess.run([str(out/'probe')],check=True,timeout=120)

# Optional full production updater/self-test run with a reviewed Sparkle 2.10.1 SDK.
if frameworks := os.environ.get('D95_SPARKLE_FRAMEWORKS'):
    base=(out/'main.swift').read_text().split('let app=NSApplication.shared')[0]
    base=base.replace('@MainActor @Observable final class ApplicationUpdates { var readyWhenIdle = true }',
                      (root/'Cassini/Settings/ApplicationUpdates.swift').read_text())
    base+="""
@MainActor enum RecordingOverview { static let active=false,starting=false,saving=false }
@MainActor enum RecordingPageModel { static let hasPendingEdits=false }
@MainActor enum SettingsFixture { static let id:UUID?=UUID() }
"""
    for name,field in [('TranscriptionQueue','isBusy'),('LibraryImportCoordinator','isBusy'),('MeetingExportCoordinator','isBusy'),('LibraryMoveCoordinator','busy'),('MeetingRenameCoordinator','working'),('MeetingTrashCoordinator','busy'),('LibraryStore','isRefreshing')]:
        base+=f'@MainActor final class {name} {{ static let shared={name}(); let {field}=false }}\n'
    base+=(root/'Cassini/Settings/UpdateDeferralSelfTest.swift').read_text()
    base+="""
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
 do { try await UpdateDeferralSelfTest.run(); print("PASS actual updater, Sparkle ready window and mounted footer for every activity and Quit");exit(0) }
 catch { fputs("FAILED: \\(error)\\n",stderr);exit(1) }
}
app.run()
"""
    (out/'sparkle.swift').write_text(base)
    subprocess.run(['xcrun','swiftc','-D','DEBUG','-g',str(out/'sparkle.swift'),'-F',frameworks,'-framework','Sparkle','-Xlinker','-rpath','-Xlinker',frameworks,'-o',str(out/'sparkle-probe')],check=True)
    subprocess.run([str(out/'sparkle-probe')],check=True,timeout=120)
