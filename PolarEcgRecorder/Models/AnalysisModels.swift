import Foundation
import UIKit

public enum AnomalyType: String {
    case dropout = "Pause (>1.5s)"
    case pvc = "Ventricular Extrasystole (PVC)"
    case abnormal = "Abnormal Beat (PAC/Other)"
}

public struct AnomalyEvent: Identifiable {
    public let id = UUID()
    public let type: AnomalyType
    public let timestamp: UInt64
    public let rrInterval: Double
    
    public init(type: AnomalyType, timestamp: UInt64, rrInterval: Double) {
        self.type = type
        self.timestamp = timestamp
        self.rrInterval = rrInterval
    }
}

/// 3-second ECG snippet centered around an event for PDF graphs
public struct EventSnippet {
    public let label: String           // "PVC @ 14:32:07", "Min HR @ 13:58:22"
    public let timestamp: UInt64
    public let samples: [Double]       // ~390 filtered samples (3s × 130Hz)
    public let color: UIColor          // red for PVC, orange for PAC, blue for min/max HR
    
    public init(label: String, timestamp: UInt64, samples: [Double], color: UIColor) {
        self.label = label
        self.timestamp = timestamp
        self.samples = samples
        self.color = color
    }
}

/// Advanced session statistics computed during the single O(N) pass
public struct SessionSummary {
    public let totalBeats: Int
    public let artifactPercent: Double       // % of windows failing 150µV p2p
    public let pNN50: Double                 // % of successive RR diffs > 50ms
    public let tachycardiaBurden: Double     // % of beats with RR < 600ms (>100 bpm)
    public let bradycardiaBurden: Double     // % of beats with RR > 1200ms (<50 bpm)
    public let anomalies: [AnomalyEvent]
    public let snippets: [EventSnippet]      // Capped at 50 anomaly + 2 HR extreme
    public let minHRBpm: Double
    public let maxHRBpm: Double
    public let avgHRBpm: Double
    
    public init(totalBeats: Int, artifactPercent: Double, pNN50: Double, tachycardiaBurden: Double, bradycardiaBurden: Double, anomalies: [AnomalyEvent], snippets: [EventSnippet], minHRBpm: Double, maxHRBpm: Double, avgHRBpm: Double) {
        self.totalBeats = totalBeats
        self.artifactPercent = artifactPercent
        self.pNN50 = pNN50
        self.tachycardiaBurden = tachycardiaBurden
        self.bradycardiaBurden = bradycardiaBurden
        self.anomalies = anomalies
        self.snippets = snippets
        self.minHRBpm = minHRBpm
        self.maxHRBpm = maxHRBpm
        self.avgHRBpm = avgHRBpm
    }
}
