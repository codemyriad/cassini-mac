// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit
import Observation
import UserNotifications
import CassiniLibrary

final class CaptureNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = CaptureNotifications()
    #if DEBUG
    @MainActor @Observable final class FixtureState { var titles: [String] = [] }
    @MainActor static let fixture = FixtureState()
    @MainActor static var savedFixtureTitles: [String] { fixture.titles }
    @MainActor static var authorizationFixture: (() async -> Void)?
    #endif
    @MainActor func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier:"cassini-capture",actions:[
            UNNotificationAction(identifier:"stop",title:UXText.text("common.stop"),options:[])
        ],intentIdentifiers:[])])
        CaptureCollection.shared.onAutomaticStart = { id in Self.shared.started(id) }
        CaptureCollection.shared.onFallback = { id in Self.shared.fallback(id) }
    }
    @MainActor private var authorizationTask: Task<Void,Never>?
    @MainActor private var authorizationRequested = false
    @MainActor func authorizeAfterStart() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        authorizationTask = Task { @MainActor in await self.authorize() }
    }
    #if DEBUG
    @MainActor func resetAuthorizationForFixture() {
        precondition(CaptureFixture.enabled)
        authorizationRequested = false; authorizationTask = nil
    }
    #endif
    @MainActor private func authorize() async {
        #if DEBUG
        if CaptureFixture.enabled, let authorization = Self.authorizationFixture { await authorization(); return }
        if CaptureFixture.enabled || RecordingFixture.enabled || LibraryLaunchContext.current.screenshot { return }
        #endif
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options:[.alert])
    }
    @MainActor func started(_ id: UUID) {
        // Only the notification waits for consent. Recording has already
        // admitted its inputs and keeps running if the banner is ignored.
        let authorization = authorizationTask
        Task { @MainActor in
            await authorization?.value
            guard let value = CaptureCollection.shared.captures[id], value.snapshot.phase == .recording,
                  value.savingSinceMs == nil else { return }
            post(id,title:UXText.text("states.badge.recording",["liveBadge":LibraryFormat.liveBadge(value.elapsedMs)]),body:value.displayTitle ?? value.snapshot.manifest.title,kind:"start")
        }
    }
    @MainActor func fallback(_ id: UUID) {
        guard let value = CaptureCollection.shared.captures[id] else { return }
        post(id,title:value.displayTitle ?? value.snapshot.manifest.title,body:UXText.text("errors.othersFallback.line"),kind:"fallback")
    }
    @MainActor func saved(folder: URL, title: String) {
        let message = UXText.text("recording.savedNotification",["title":title])
        #if DEBUG
        if CaptureFixture.enabled || RecordingFixture.enabled { Self.fixture.titles.append(message); return }
        #endif
        let content = UNMutableNotificationContent()
        content.title = message
        content.userInfo = ["meetingKey":folder.lastPathComponent]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"saved-" + folder.lastPathComponent,content:content,trigger:nil)) { _ in }
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
        let savedKey = response.notification.request.content.userInfo["meetingKey"] as? String
        Task { @MainActor in
            if let savedKey {
                MeetingNavigation.shared.openLibrary?()
                if let meeting = LibraryStore.shared.meetings.first(where:{ $0.libraryKey == savedKey }) { MeetingNavigation.shared.open(meeting) }
                NSApp.activate(ignoringOtherApps:true)
            } else { Self.handle(action:action,id:id) }
        }
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
