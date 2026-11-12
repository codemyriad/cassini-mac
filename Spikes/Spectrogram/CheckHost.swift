// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@main struct CheckHost {
    static func main() {
        let hosted=["GITHUB_ACTIONS":"true","RUNNER_ENVIRONMENT":"github-hosted"]
        let gui=["GITHUB_ACTIONS":"true","RUNNER_ENVIRONMENT":"self-hosted","CASSINI_CI_GUI":"1"]
        precondition(SpectrogramFixtureHost.admits(hosted,uid:501,consoleUID:501,aqua:false))
        precondition(SpectrogramFixtureHost.admits(gui,uid:503,consoleUID:503,aqua:true))
        for (environment,uid,console,aqua) in [
            (gui,UInt32(501),UInt32(503),true),(gui,503,501,true),(gui,503,503,false),
            (gui.filter { $0.key != "CASSINI_CI_GUI" },503,503,true),
            (gui.filter { $0.key != "GITHUB_ACTIONS" },503,503,true),
            (hosted.filter { $0.key != "GITHUB_ACTIONS" },501,501,true)] {
            precondition(!SpectrogramFixtureHost.admits(environment,uid:uid,consoleUID:console,aqua:aqua))
        }
        print("PASS hosted and dedicated Aqua admission; six unsafe contexts rejected")
    }
}
