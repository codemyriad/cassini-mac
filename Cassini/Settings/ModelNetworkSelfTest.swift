// SPDX-License-Identifier: GPL-3.0-or-later
#if DEBUG
import AppKit
import CassiniWhistle
import CassiniModels

private final class ModelProbeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<(Bool,Bool),Error>
    let connection = NSXPCConnection(serviceName:ModelDownloadClient.serviceName)
    init(_ continuation: CheckedContinuation<(Bool,Bool),Error>) { self.continuation = continuation }
    func finish(_ result: Result<(Bool,Bool),Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true; lock.unlock()
        connection.invalidationHandler = nil; connection.interruptionHandler = nil; connection.invalidate()
        continuation.resume(with:result)
    }
}
@MainActor enum ModelNetworkSelfTest {
    static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard env["CASSINI_LOCAL_WORKFLOW_TESTS"] == "1" || env["GITHUB_ACTIONS"] == "true" && env["RUNNER_ENVIRONMENT"] == "github-hosted",
              let raw = LibraryLaunchContext.argument("--models-network-self-test"), let port = UInt16(raw), port > 0 else { exit(78) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CassiniModelNetwork-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:root) }
            let bookmark = try root.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
            let result: (Bool,Bool) = try await withCheckedThrowingContinuation { continuation in
                let gate = ModelProbeReply(continuation), connection = gate.connection
                connection.remoteObjectInterface = NSXPCInterface(with:CassiniModelDownloadService.self)
                connection.invalidationHandler = { gate.finish(.failure(ModelDownloadError.response)) }
                connection.interruptionHandler = { gate.finish(.failure(ModelDownloadError.response)) }
                connection.resume()
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ gate.finish(.failure($0)) }) as? CassiniModelDownloadService else { gate.finish(.failure(ModelDownloadError.response)); return }
                proxy.probeEnvironment(port:port,destinationBookmark:bookmark,expectedDirectory:root.resolvingSymlinksInPath().path) { network,scope,error in
                    if let error { gate.finish(.failure(error)) } else { gate.finish(.success((network,scope))) }
                }
                Task { try? await Task.sleep(for:.seconds(10)); gate.finish(.failure(ModelDownloadError.response)) }
            }
            guard result.0 && result.1 else { throw ModelDownloadError.response }
            var denied: [String:Bool] = [:]
            for name in ["cassini-whistle-worker","cassini-parakeet-worker"] {
                let worker = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/" + name)
                let output = try await WhistleSubprocess.run(executable:worker,arguments:["--network-probe",String(port)],environment:WhistleEnvironment.worker(),input:Data(),timeout:10)
                let reply = try JSONSerialization.jsonObject(with:output.stdout) as? [String:Any]
                guard output.status == 0, reply?["networkDenied"] as? Bool == true else { throw WhistleFailure.runtime(name + " network denial failed: " + String(decoding:output.stdout + output.stderr,as:UTF8.self)) }
                denied[name] = true
            }
            let report: [String:Any] = ["downloadServiceConnected":result.0,"scopedModelDirectory":result.1,"workersNetworkDenied":denied,"audioDevicesOpened":false]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) + Data([10])); exit(0)
        } catch { FileHandle.standardError.write(Data("Model XPC/network proof failed: \(error)\n".utf8)); exit(1) }
    }
}
#endif
