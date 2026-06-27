import ActivityKit
import Foundation

struct EcgActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var isEventRecording: Bool
        var currentHR: Int
    }
    
    var sessionName: String
}
