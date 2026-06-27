import AppIntents
import Foundation
import UIKit

struct MarkEventIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Mark Event"
    
    init() {}
    
    func perform() async throws -> some IntentResult {
        // Post Darwin Notification to run event marking in main application background
        let notificationName = "com.ecgpolar.mark_event" as CFString
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(notificationName), nil, nil, true)
        return .result()
    }
}
