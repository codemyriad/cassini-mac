import Foundation
import Darwin

private let outputLock = NSLock()
private func note(_ message: String) {
    outputLock.lock(); defer { outputLock.unlock() }
    print(message); fflush(stdout)
}
private func command(_ executable: String, _ arguments: [String]) -> String {
    let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath:executable)
    p.arguments = arguments; p.standardOutput = pipe; p.standardError = pipe
    do { try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return String(decoding:data,as:UTF8.self) }
    catch { return "diagnostic command failed: \(error)" }
}
private func snapshot(_ pid: Int32, _ tag: String) {
    note("SNAPSHOT \(tag) pid=\(pid)\n" + command("/bin/ps",["-p",String(pid),"-o","pid=,ppid=,state=,etime=,comm="]))
    note(command("/usr/bin/sample",[String(pid),"1","10","-file","build/pipe-diagnostics/\(tag)-\(pid).sample.txt"]))
}
private func pipeCase(_ label: String, _ executable: String, _ arguments: [String]) {
    let p = Process(), output = Pipe(), input = Pipe(), errors = Pipe()
    p.executableURL = URL(fileURLWithPath:executable); p.arguments = arguments
    p.standardInput = input; p.standardOutput = output; p.standardError = errors
    let exited = DispatchSemaphore(value:0); p.terminationHandler = { _ in exited.signal() }
    let start = Date()
    do {
        try p.run()
        note("START \(label) pid=\(p.processIdentifier)")
        let fd = output.fileHandleForReading.fileDescriptor
        var item = pollfd(fd:fd,events:Int16(POLLIN|POLLHUP),revents:0)
        let ready = poll(&item,1,3000)
        var bytes: Int32 = -1; let counted = ioctl(fd,UInt(0x4004667f),&bytes)
        note("POLL \(label) ready=\(ready) revents=\(item.revents) queued=\(bytes) ioctl=\(counted) running=\(p.isRunning) elapsed=\(Date().timeIntervalSince(start))")
        if ready == 0 { snapshot(p.processIdentifier,label) }
        _ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK)
        var buffer = [UInt8](repeating:0,count:4096)
        let readCount = read(fd,&buffer,buffer.count)
        note("READ \(label) count=\(readCount) errno=\(errno) bytes=\(String(decoding:buffer.prefix(max(0,readCount)),as:UTF8.self))")
        try? input.fileHandleForWriting.write(contentsOf:Data("start\n".utf8))
        try? input.fileHandleForWriting.close()
        if p.isRunning { p.terminate() }
        if exited.wait(timeout:.now()+3) == .timedOut, p.isRunning { kill(p.processIdentifier,SIGKILL); _ = exited.wait(timeout:.now()+2) }
        if !p.isRunning { p.waitUntilExit() }
        _ = fcntl(errors.fileHandleForReading.fileDescriptor,F_SETFL,O_NONBLOCK)
        let count = read(errors.fileHandleForReading.fileDescriptor,&buffer,buffer.count)
        note("END \(label) stderr=\(String(decoding:buffer.prefix(max(0,count)),as:UTF8.self)) elapsed=\(Date().timeIntervalSince(start))")
    } catch { note("ERROR \(label): \(error)") }
}
@main struct PipeProgress {
    static func main() async {
        note(command("/usr/bin/sw_vers",[]))
        note("Resolved PATH python: " + command("/usr/bin/env",["python3","-c","import sys; print(sys.executable,flush=True)"]))
        let program = "import sys; print('ready',flush=True); sys.stdin.readline()"
        pipeCase("shell","/bin/sh",["-c","printf 'ready\\n'; read value"])
        pipeCase("python-system","/usr/bin/python3",["-c",program])
        pipeCase("python-env","/usr/bin/env",["python3","-c",program])
        pipeCase("http-fixture","/usr/bin/env",["python3","Tests/CassiniModelsTests/Fixtures/server.py","--scenario","normal","--log","build/pipe-diagnostics/requests.jsonl"])
        await withCheckedContinuation { done in
            Thread.detachNewThread { pipeCase("python-thread","/usr/bin/python3",["-c",program]); done.resume() }
        }
        let complete = DispatchSemaphore(value:0)
        Thread.detachNewThread {
            if complete.wait(timeout:.now()+3) == .timedOut {
                note("WHISTLE TREE\n" + command("/bin/ps",["-axo","pid=,ppid=,state=,etime=,comm="]))
                let rows = command("/bin/ps",["-axo","pid=,ppid=,comm="]).split(separator:"\n")
                for row in rows {
                    let fields = row.split(separator:" ",maxSplits:2,omittingEmptySubsequences:true)
                    if fields.count == 3, Int32(fields[1]) == getpid(), let child = Int32(fields[0]), fields[2].contains("python") {
                        snapshot(child,"whistle")
                    }
                }
            }
        }
        do {
            let value = try await WhistleSubprocess.run(executable:URL(fileURLWithPath:"/usr/bin/python3"),arguments:["-c","import sys; sys.stderr.buffer.write(b'e'*800000); sys.stderr.flush(); print('done',flush=True)"],environment:["PATH":"/usr/bin:/bin"],input:Data(),timeout:10)
            note("WHISTLE status=\(value.status) stdout=\(String(decoding:value.stdout,as:UTF8.self)) stderrBytes=\(value.stderr.count)")
        } catch { note("WHISTLE error=\(error)") }
        complete.signal()
    }
}
