from pathlib import Path
import hashlib,json,os,shutil,subprocess
root=Path(__file__).resolve().parents[5]
ev=Path(os.environ['D88_EVIDENCE_DIR']).resolve();ev.mkdir(parents=True,exist_ok=True)
project=ev/'project';project.mkdir(exist_ok=True)
for name in ('CassiniKit','CassiniRecording'):
 target=project/'Sources'/name
 if target.exists():shutil.rmtree(target)
 shutil.copytree(root/'Sources'/name,target)
(project/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name:"D88MicWindowProof",platforms:[.macOS(.v15)],targets:[.target(name:"CassiniKit"),.target(name:"CassiniRecording",dependencies:["CassiniKit"]),.testTarget(name:"DCProof",dependencies:["CassiniRecording","CassiniKit"])])
''')
source=(root/'Cassini/Browser/CaptureSelfTest.swift').read_text()
old=subprocess.check_output(['git','show','e5c3bb0a9542811487c9d0bdc4596d4220a8feb5:Cassini/Browser/CaptureSelfTest.swift'],cwd=root,text=True)
collection=(root/'Cassini/Browser/CaptureCollection.swift').read_text()
helper=source.split('@MainActor enum CaptureSelfTest {',1)[1].split('    static func run() async {',1)[0].replace('timeout: Double = 8','timeout: Double = 1')
def method(signature):
 start=collection.index(signature);brace=collection.index('{',start);depth=1;end=brace+1
 while depth:
  if collection[end]=='{':depth+=1
  if collection[end]=='}':depth-=1
  end+=1
 return collection[start:end].replace('private func','func')
refresh=method('    private func refreshLevels(')
clock=method('    func setMicrophoneUptimeForTesting(')
mic=collection.split('    @MainActor var microphoneSilent: Bool {',1)[1].split('    var elapsedMs:',1)[0]
def boundary(text):return text.split('            let ownedIDs =',1)[1].split('            try require(RecordingMenuPayload',1)[0]
body_old='let ownedIDs ='+boundary(old)
body_fixed='let ownedIDs ='+boundary(source)
prelude='''import Foundation
import AVFoundation
import Observation
import Testing
@testable import CassiniRecording
struct Track { let kind:String; let frames:UInt64 }
struct Manifest { let id:UUID; let tracks:[Track] }
struct Snapshot { let manifest:Manifest; let me=true; let browserAlive=false; let others=false; let levelTimestamp=0.0; let browserLevel:Float=0 }
final class Writer: RecordingSinkWriter, @unchecked Sendable {
 let id:UUID; let lock=NSLock(); var frames=UInt64(0)
 init(_ id:UUID) { self.id=id }
 var recordingProblem:String? { nil }
 func addTrack(id:String,label:String,kind:String,sampleRate:Int,channels:Int) throws {}
 func appendNative(id:String,pcm:Data,offsetMs:Double) throws { lock.withLock { frames += UInt64(pcm.count/2) } }
 func finish(problem:String?) throws {}
 var snapshot:Snapshot { lock.withLock { .init(manifest:.init(id:id,tracks:[.init(kind:"microphone",frames:frames)])) } }
}
final class Owner { let writer:Writer; init(_ writer:Writer) { self.writer=writer }; var snapshot:Snapshot { writer.snapshot } }
enum Side { case me,others }
typealias Status=(levels:[String:Float],frames:[String:UInt64],droppedMs:Double,gapMs:Double,warnings:[String])
final class Input {
 let writer:Writer, sink:RecordingSink
 let origin=AVAudioTime.hostTime(forSeconds:10); var frames=UInt64(0)
 init(_ writer:Writer) { self.writer=writer; sink=RecordingSink(session:writer,originHostTime:AVAudioTime.hostTime(forSeconds:10),onFailure:{ fatalError($0) }) }
 var failedSides:[Side] { [] }
 func status()->[Side:Status] { [.me:sink.status()] }
 func emit(_ count:Int,tone:Bool=false) {
  let format=AVAudioFormat(standardFormatWithSampleRate:8000,channels:1)!
  let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(count))!; buffer.frameLength=AVAudioFrameCount(count)
  for i in 0..<count { buffer.floatChannelData![0][i]=0.35 + (tone ? Float(sin(Double(frames+UInt64(i))/8000*2*Double.pi*440))*0.12 : 0) }
  sink.receive(buffer,hostTime:origin+AVAudioTime.hostTime(forSeconds:Double(frames)/8000),id:"microphone",label:"Generated mic",kind:"microphone")
  frames += UInt64(count); sink.flush()
 }
}
@MainActor struct LiveCapture {
 let owner:Owner,input:Input
 var snapshot:Snapshot { owner.snapshot }
 var levels=[Side:Float](); var lastMicSound=0.0; var fixtureMicrophoneUptime:Double?
 var microphoneUptime:Double { fixtureMicrophoneUptime ?? 0 }
 @MainActor var microphoneSilent:Bool {
'''+mic+'''
}
@MainActor enum CaptureFixture { static let enabled=true }
@MainActor @Observable final class CaptureCollection {
 static let shared=CaptureCollection(); var captures=[UUID:LiveCapture](); var peers=[Int]()
'''+refresh+'\n'+clock+'''
}
@MainActor enum RecordingOverview {
 static var microphoneSilent:Bool { CaptureCollection.shared.captures.values.allSatisfy { $0.microphoneSilent } }
}
@MainActor struct Editor {
 let id:UUID
 var microphoneSilent:Bool { CaptureCollection.shared.captures[id]!.microphoneSilent }
}
@MainActor enum CaptureSelfTest {
'''+helper+'''
 @MainActor static func exercise(_ collection:CaptureCollection,_ first:LiveCapture,_ second:LiveCapture,_ originalEditor:Editor) async throws {
'''
suffix='''
 }
}
struct DCMicrophoneProbe {
 @Test @MainActor func realWindowReachesTheAppSilenceAssertion() async throws {
  let collection=CaptureCollection.shared; collection.captures=[:]
  let ids=[UUID(),UUID()]
  for id in ids {
   let writer=Writer(id), input=Input(writer); input.emit(800)
   collection.captures[id]=LiveCapture(owner:Owner(writer),input:input)
  }
  let first=collection.captures[ids[0]]!, second=collection.captures[ids[1]]!
  let before=ids.map { collection.captures[$0]!.owner.snapshot.manifest.tracks[0].frames }
  let delivery=Task { @MainActor in
   guard ProcessInfo.processInfo.environment["MIC_NO_FRAMES"] != "1" else { return }
   for _ in 0..<5 {
    await Task.yield(); guard !Task.isCancelled else { return }
    for id in ids {
     guard let value=collection.captures[id],value.fixtureMicrophoneUptime == 20 else { continue }
     value.input.emit(160,tone:ProcessInfo.processInfo.environment["MIC_LOUD"] == "1")
     collection.refreshLevels(id,value)
     collection.captures[id]=collection.captures[id]
    }
   }
  }
  defer { delivery.cancel() }
  try await CaptureSelfTest.exercise(collection,first,second,Editor(id:ids[0]))
  print("new mic frames at uptime 20:",zip(ids,before).map { collection.captures[$0.0]!.owner.snapshot.manifest.tracks[0].frames-$0.1 })
 }
}
'''
tests=project/'Tests/DCProof';tests.mkdir(parents=True,exist_ok=True)
sink=project/'Sources/CassiniRecording/RecordingSink.swift';original=sink.read_text()
assert original.count('let mean = sum / Double(count)')==1
cases=[('before-broken-dc',body_old,True,{},True),('fixed',body_fixed,False,{},True),('broken-dc',body_fixed,True,{},False),('no-frames',body_fixed,False,{'MIC_NO_FRAMES':'1'},False),('loud-mic',body_fixed,False,{'MIC_LOUD':'1'},False),('restored',body_fixed,False,{},True)]
results=[]
for name,body,broken,extra,expected in cases:
 (tests/'Generated.swift').write_text(prelude+body+suffix)
 sink.write_text(original.replace('let mean = sum / Double(count)','let mean = 0.0') if broken else original)
 with (ev/(name+'.log')).open('w') as stream:
  run=subprocess.run(['swift','test','--scratch-path',str(ev/'build'),'--jobs','4','--filter','DCMicrophoneProbe'],cwd=project,env={**os.environ,**extra},stdout=stream,stderr=subprocess.STDOUT,timeout=240)
 log=(ev/(name+'.log')).read_text()
 assert (run.returncode==0) if expected else (run.returncode!=0 and 'recorded an issue' in log),(name,run.returncode)
 print(name,run.returncode,flush=True);results.append({'case':name,'exit':run.returncode})
sink.write_text(original)
(ev/'results.json').write_text(json.dumps({'cases':results,'app_source_sha256':hashlib.sha256(source.encode()).hexdigest(),'sink_sha256':hashlib.sha256(original.encode()).hexdigest()},indent=2)+'\n')
