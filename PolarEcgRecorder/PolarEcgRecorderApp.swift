//
//  PolarEcgRecorderApp.swift
//  PolarEcgRecorder
//
//  Created by Marek Janosik on 27.06.2026.
//

import SwiftUI
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        setupNotificationCategories()
        
        // Request authorization on launch
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        return true
    }

    private func setupNotificationCategories() {
        let markEventAction = UNNotificationAction(
            identifier: "MARK_EVENT",
            title: "Označiť udalosť ⚠️",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: "ECG_RECORDING",
            actions: [markEventAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == "MARK_EVENT" {
            // Trigger the event in PolarManager
            DispatchQueue.main.async {
                if PolarManager.shared.isConnected {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    if let s = StorageManager.shared.eventState {
                        s.triggerEvent()
                    }
                    if !PolarManager.shared.isStreaming {
                        PolarManager.shared.startEventRecordingWindow()
                    }
                }
            }
        }
        completionHandler()
    }
}

@main
struct PolarEcgRecorderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            DashboardView()
        }
    }
}
