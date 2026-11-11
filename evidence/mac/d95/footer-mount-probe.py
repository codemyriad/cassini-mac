"""Compile the actual updater, footer and layout proof; run only in an idle Aqua session."""
from pathlib import Path
import subprocess,os
root=Path(__file__).resolve().parents[3]
out=Path(os.environ['D95_FOOTER_EVIDENCE_DIR']).expanduser().resolve()
assert root not in (out,*out.parents),'Use external evidence'
out.mkdir(parents=True,exist_ok=True)
frameworks=os.environ['D95_SPARKLE_FRAMEWORKS']
s=(root/'Cassini/Library/LibraryView.swift').read_text()
base='''import AppKit
import SwiftUI
import Observation
import Darwin
'''+(root/'Cassini/Settings/ApplicationUpdates.swift').read_text()+'''
enum UXText { static func text(_ key:String)->String {"Update ready when idle"} }
enum LibraryTheme { static let dim=Color.secondary }
@MainActor enum RecordingOverview { static let active=false,starting=false,saving=false }
@MainActor enum RecordingPageModel { static let hasPendingEdits=false }
@MainActor enum SettingsFixture { static let id:UUID?=UUID() }
'''
for name,field in [('TranscriptionQueue','isBusy'),('LibraryImportCoordinator','isBusy'),('MeetingExportCoordinator','isBusy'),('LibraryMoveCoordinator','busy'),('MeetingRenameCoordinator','working'),('MeetingTrashCoordinator','busy'),('LibraryStore','isRefreshing')]:
 base+=f'@MainActor final class {name} {{static let shared={name}();let {field}=false}}\n'
base+=s[s.index('struct UpdateReadyFooter: View {'):]
base+=(root/'Cassini/Settings/UpdateDeferralSelfTest.swift').read_text()
base+='''
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
 do {
  let cover=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:900),styleMask:[.borderless],backing:.buffered,defer:false)
  cover.isReleasedWhenClosed=false;cover.level = .floating;cover.orderFront(nil)
  defer {cover.close()}
  let cycles=Int(ProcessInfo.processInfo.environment["D95_UPDATER_CYCLES"] ?? "1") ?? 1
  for i in 0..<cycles {try await UpdateDeferralSelfTest.run();print("PASS actual updater, occluded footer layout, all activities and Quit",i)}
  exit(0)
 } catch {fputs("FAILED: \\(error)\\n",stderr);exit(1)}
}
app.run()
'''
(out/'layout-proof.swift').write_text(base)
subprocess.run(['xcrun','swiftc','-D','DEBUG','-g',str(out/'layout-proof.swift'),'-F',frameworks,'-framework','Sparkle','-Xlinker','-rpath','-Xlinker',frameworks,'-o',str(out/'layout-proof')],check=True)
subprocess.run([str(out/'layout-proof')],check=True,timeout=180)
