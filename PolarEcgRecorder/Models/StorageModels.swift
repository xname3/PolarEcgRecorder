import Foundation
import Combine
import SwiftUI

// MARK: - Session Group (ECG + HR + HRV file triplet)
public struct SessionGroup: Identifiable {
    public let id = UUID()
    public let sessionKey: String          // "2025-01-15_14-30-00"
    public var ecgURL: URL?
    public var hrURL:  URL?
    public var hrvURL: URL?

    public init(sessionKey: String, ecgURL: URL? = nil, hrURL: URL? = nil, hrvURL: URL? = nil) {
        self.sessionKey = sessionKey
        self.ecgURL = ecgURL
        self.hrURL = hrURL
        self.hrvURL = hrvURL
    }

    public var allURLs: [URL] { [ecgURL, hrURL, hrvURL].compactMap { $0 } }

    public var sessionDate: Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.date(from: sessionKey) ?? .distantPast
    }

    public var displayName: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium
        return f.string(from: sessionDate)
    }

    public var totalSizeString: String {
        let bytes = allURLs.reduce(Int64(0)) { acc, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return acc + size
        }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB]; fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}

// MARK: - Event Marker
public class EventState: ObservableObject {
    @Published public var isEventMarked: Bool = false
    public init() {}
    @MainActor
    public func triggerEvent() { isEventMarked = true }
}

public struct ShareableFile: Identifiable {
    public let id = UUID()
    public let url: URL
    
    public init(url: URL) {
        self.url = url
    }
}
