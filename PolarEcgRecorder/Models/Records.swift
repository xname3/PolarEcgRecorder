import Foundation

// MARK: - Data models
public struct ECGSample { 
    public let timestamp: UInt64
    public let microVolts: Int32
    public let isEvent: Bool 
    
    public init(timestamp: UInt64, microVolts: Int32, isEvent: Bool) {
        self.timestamp = timestamp
        self.microVolts = microVolts
        self.isEvent = isEvent
    }
}

public struct HRSample { 
    public let timestamp: UInt64
    public let bpm: UInt8 
    
    public init(timestamp: UInt64, bpm: UInt8) {
        self.timestamp = timestamp
        self.bpm = bpm
    }
}

public struct HRVSample { 
    public let timestamp: UInt64
    public let rmssd: Double
    public let rrIntervals: [Int] 
    
    public init(timestamp: UInt64, rmssd: Double, rrIntervals: [Int]) {
        self.timestamp = timestamp
        self.rmssd = rmssd
        self.rrIntervals = rrIntervals
    }
}
