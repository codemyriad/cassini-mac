// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UserNotifications
import CassiniLibrary

final class CaptureNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = CaptureNotifications()
    @MainActor func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier:"cassini-capture",actions:[
            UNNotificationAction(identifier:"stop",title:UXText.text("common.stop"),options:[])
        ],intentIdentifiers:[])])
        CaptureCollection.shared.onAutomaticStart = { id in Self.shared.started(id) }
        CaptureCollection.shared.onFallback = { id in Self.shared.fallback(id) }
    }
    @MainActor func authorize() async {
        #if DEBUG
        if CaptureFixture.enabled { return }
        #endif
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options:[.alert])
    }
    @MainActor func started(_ id: UUID) {
        guard let value = CaptureCollection.shared.captures[id] else { return }
        post(id,title:UXText.text("states.badge.recording",["liveBadge":LibraryFormat.liveBadge(value.elapsedMs)]),body:value.displayTitle ?? value.snapshot.manifest.title,kind:"start")
    }
    @MainActor func fallback(_ id: UUID) {
        guard let value = CaptureCollection.shared.captures[id] else { return }
        post(id,title:value.displayTitle ?? value.snapshot.manifest.title,body:UXText.text("errors.othersFallback.line"),kind:"fallback")
    }
    @MainActor private func post(_ id: UUID, title: String, body: String, kind: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.categoryIdentifier = "cassini-capture"
        content.userInfo = ["captureID":id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:kind + "-" + id.uuidString,content:content,trigger:nil)) { _ in }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let id = (response.notification.request.content.userInfo["captureID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in Self.handle(action:action,id:id) }
        completionHandler()
    }
    @MainActor static func handle(action: String, id: UUID?) {
        if action == "stop", let id { CaptureCollection.shared.stop(id) }
        else { RecordCoordinator.shared.openCurrent() }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner,.list])
    }
}
