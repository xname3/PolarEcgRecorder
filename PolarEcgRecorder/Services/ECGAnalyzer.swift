import Foundation
import UIKit
import CoreML

// MARK: - DataIntegrityError
public enum DataIntegrityError: LocalizedError {
    case insufficientECGData(expected: Int, actual: Int)
    case insufficientHRData(expected: Int, actual: Int)
    case massiveECGGap(gapMs: UInt64)
    case massiveHRVGap(gapMs: UInt64)
    case noData
    
    public var errorDescription: String? {
        switch self {
        case .insufficientECGData(let expected, let actual):
            return "Corrupted Session: Missing too much ECG data. Expected ~\(expected) samples, but found only \(actual)."
        case .insufficientHRData(let expected, let actual):
            return "Corrupted Session: Missing too much HR data. Expected ~\(expected) samples, but found only \(actual)."
        case .massiveECGGap(let gapMs):
            return "Corrupted Session: Detected a massive gap in ECG data (\(gapMs) ms). The Bluetooth connection was heavily dropped."
        case .massiveHRVGap(let gapMs):
            return "Corrupted Session: Detected a massive gap in HRV data (\(gapMs) ms). The Bluetooth connection was heavily dropped."
        case .noData:
            return "Corrupted Session: No data found to generate a report."
        }
    }
}

// MARK: - ECG Analyzer
public class ECGAnalyzer {
    
    static let maxAnomalySnippets = 50
    static let snippetHalfWindow = 195   // 1.5s × 130Hz = 195 samples → 3s total
    
    // MARK: - Data Validation & Parsing
    
    public static func validateDataIntegrity(ecg: inout [ECGSample], hr: inout [HRSample], hrv: inout [HRVSample]) throws {
        // 1. Universal Sorting
        ecg.sort { $0.timestamp < $1.timestamp }
        hr.sort { $0.timestamp < $1.timestamp }
        hrv.sort { $0.timestamp < $1.timestamp }
        
        guard let firstEcg = ecg.first, let lastEcg = ecg.last else { throw DataIntegrityError.noData }
        let durationInSeconds = Double(lastEcg.timestamp - firstEcg.timestamp) / 1000.0
        guard durationInSeconds > 0 else { throw DataIntegrityError.noData }
        
        // 2. Type-Specific Integrity Math
        
        // ECG Check
        let expectedECG = Int(durationInSeconds * 130.0)
        if Double(ecg.count) < Double(expectedECG) * 0.80 {
            throw DataIntegrityError.insufficientECGData(expected: expectedECG, actual: ecg.count)
        }
        for i in 1..<ecg.count {
            let gap = ecg[i].timestamp - ecg[i-1].timestamp
            if gap > 3000 {
                throw DataIntegrityError.massiveECGGap(gapMs: gap)
            }
        }
        
        // HR Check
        let expectedHR = Int(durationInSeconds * 1.0)
        if Double(hr.count) < Double(expectedHR) * 0.70 {
            throw DataIntegrityError.insufficientHRData(expected: expectedHR, actual: hr.count)
        }
        
        // HRV Check
        for i in 1..<hrv.count {
            let gap = hrv[i].timestamp - hrv[i-1].timestamp
            if gap > 5000 {
                throw DataIntegrityError.massiveHRVGap(gapMs: gap)
            }
        }
    }

    public static func parseECG(_ url: URL?) -> [ECGSample] {
        guard let url, let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").dropFirst().compactMap { line in
            let p = line.split(separator: ",")
            guard p.count >= 2,
                  let ts = UInt64(p[0].trimmingCharacters(in: .whitespaces)),
                  let uv = Int32 (p[1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            return ECGSample(timestamp: ts, microVolts: uv,
                             isEvent: p.count >= 3 && p[2].contains("EVENT"))
        }
    }

    public static func parseHR(_ url: URL?) -> [HRSample] {
        guard let url, let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").dropFirst().compactMap { line in
            let p = line.split(separator: ",")
            guard p.count >= 2,
                  let ts  = UInt64(p[0].trimmingCharacters(in: .whitespaces)),
                  let bpm = UInt8 (p[1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            return HRSample(timestamp: ts, bpm: bpm)
        }
    }

    public static func parseHRV(_ url: URL?) -> [HRVSample] {
        guard let url, let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").dropFirst().compactMap { line in
            let p = line.split(separator: ",")
            guard p.count >= 2,
                  let ts    = UInt64(p[0].trimmingCharacters(in: .whitespaces)),
                  let rmssd = Double(p[1].trimmingCharacters(in: .whitespaces))
            else { return nil }
            var rrs: [Int] = []
            if p.count >= 3 {
                let rrString = String(p[2])
                    .replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "")
                    .trimmingCharacters(in: .whitespaces)
                rrs = rrString.split(separator: ";").compactMap { Int(String($0).trimmingCharacters(in: .whitespaces)) }
            }
            return HRVSample(timestamp: ts, rmssd: rmssd, rrIntervals: rrs)
        }
    }
    
    // MARK: - High-Pass Filter (Baseline Wander Removal)
    
    /// 2nd-order Butterworth IIR high-pass filter. Removes baseline drift below cutoff.
    public static func applyHighPassFilter(
        to samples: [ECGSample],
        sampleRate: Double = 130.0,
        cutoff: Double = 0.67
    ) -> [Double] {
        let n = samples.count
        guard n > 0 else { return [] }
        
        let signal = samples.map { Double($0.microVolts) }
        
        let omega = tan(Double.pi * cutoff / sampleRate)
        let omega2 = omega * omega
        let sqrt2 = sqrt(2.0)
        let denom = 1.0 + sqrt2 * omega + omega2
        
        let b0 =  1.0 / denom
        let b1 = -2.0 / denom
        let b2 =  1.0 / denom
        let a1 =  2.0 * (omega2 - 1.0) / denom
        let a2 =  (1.0 - sqrt2 * omega + omega2) / denom
        
        var w1: Double = 0.0
        var w2: Double = 0.0
        var filtered = [Double](repeating: 0.0, count: n)
        
        for k in 0..<n {
            let w0 = signal[k] - a1 * w1 - a2 * w2
            filtered[k] = b0 * w0 + b1 * w1 + b2 * w2
            w2 = w1
            w1 = w0
        }
        
        return filtered
    }
    
    // MARK: - Snippet Extraction Helper
    
    private static func extractSnippet(
        label: String,
        timestamp: UInt64,
        peakIdx: Int,
        filteredSignal: [Double],
        color: UIColor
    ) -> EventSnippet? {
        let start = peakIdx - snippetHalfWindow
        let end = peakIdx + snippetHalfWindow
        guard start >= 0 && end < filteredSignal.count else { return nil }
        return EventSnippet(
            label: label,
            timestamp: timestamp,
            samples: Array(filteredSignal[start...end]),
            color: color
        )
    }
    
    private static func timeLabel(_ ts: UInt64) -> String {
        let date = Date(timeIntervalSince1970: Double(ts) / 1000.0)
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: date)
    }
    
    // MARK: - Main Analysis Pipeline
    
    /// Single O(N) pass: filters baseline wander, detects R-peaks, classifies via CoreML,
    /// computes advanced statistics, extracts 3-second snippets.
    public static func analyze(ecgData: [ECGSample]) -> SessionSummary {
        let empty = SessionSummary(
            totalBeats: 0, artifactPercent: 0, pNN50: 0,
            tachycardiaBurden: 0, bradycardiaBurden: 0,
            anomalies: [], snippets: [],
            minHRBpm: 0, maxHRBpm: 0, avgHRBpm: 0
        )
        guard ecgData.count > 390 else { return empty }
        
        // Chronological sorting
        let sortedEcgData = ecgData.sorted { $0.timestamp < $1.timestamp }
        
        // Pre-processing: remove baseline wander
        let filteredSignal = applyHighPassFilter(to: sortedEcgData)
        
        // CoreML model
        var model: Any? = nil
        do {
            let config = MLModelConfiguration()
            model = try ECGMorphologyClassifier(configuration: config)
        } catch {
            print("Failed to load ECGMorphologyClassifier: \(error)")
        }
        
        // --- State ---
        var threshold: Double = 400.0
        var lastPeakTimestamp: UInt64 = 0
        var rollingNormalRRs: [Double] = []    // Last 4 CoreML-confirmed Normal beats
        
        // Anomalies & snippets
        var anomalies: [AnomalyEvent] = []
        var anomalySnippets: [EventSnippet] = []
        
        // Statistics accumulators
        var totalBeats = 0
        var artifactCount = 0
        var pNN50Count = 0
        var totalRRPairs = 0
        var tachyCount = 0
        var bradyCount = 0
        var previousRR: Double = 0
        var rrSum: Double = 0
        
        // Min/Max HR tracking (by RR interval)
        var minRR: Double = Double.greatestFiniteMagnitude   // → max HR
        var maxRR: Double = 0                                 // → min HR
        var minRRIdx = 0
        var maxRRIdx = 0
        var minRRTimestamp: UInt64 = 0
        var maxRRTimestamp: UInt64 = 0
        
        // --- Main O(N) loop ---
        var i = 0
        while i < filteredSignal.count {
            if filteredSignal[i] > threshold {
                // STEP 1: Find true local maximum
                let endIdx = min(i + 15, filteredSignal.count)
                var peakIdx = i
                var peakVal = filteredSignal[i]
                
                for j in i..<endIdx {
                    if filteredSignal[j] > peakVal {
                        peakVal = filteredSignal[j]
                        peakIdx = j
                    }
                }
                
                let detectedPeak = sortedEcgData[peakIdx]
                totalBeats += 1
                
                // STEP 2: RR interval & dropout
                var currentRR: Double = 0
                if lastPeakTimestamp > 0 && detectedPeak.timestamp > lastPeakTimestamp {
                    currentRR = Double(detectedPeak.timestamp - lastPeakTimestamp)
                    
                    // Dropout detection
                    if currentRR > 1500.0 {
                        anomalies.append(AnomalyEvent(type: .dropout, timestamp: detectedPeak.timestamp, rrInterval: currentRR))
                        if anomalySnippets.count < maxAnomalySnippets {
                            if let s = extractSnippet(label: "Dropout @ \(timeLabel(detectedPeak.timestamp))", timestamp: detectedPeak.timestamp, peakIdx: peakIdx, filteredSignal: filteredSignal, color: .systemRed) {
                                anomalySnippets.append(s)
                            }
                        }
                    }
                    
                    // Accumulate statistics
                    rrSum += currentRR
                    
                    // pNN50: successive RR difference > 50ms
                    if previousRR > 0 {
                        totalRRPairs += 1
                        if abs(currentRR - previousRR) > 50.0 {
                            pNN50Count += 1
                        }
                    }
                    previousRR = currentRR
                    
                    // Tachy (RR < 600ms → >100bpm) / Brady (RR > 1200ms → <50bpm)
                    if currentRR < 600.0 { tachyCount += 1 }
                    if currentRR > 1200.0 { bradyCount += 1 }
                    
                    // Track min/max RR for HR extremes
                    if currentRR < minRR {
                        minRR = currentRR
                        minRRIdx = peakIdx
                        minRRTimestamp = detectedPeak.timestamp
                    }
                    if currentRR > maxRR && currentRR <= 1500.0 {
                        maxRR = currentRR
                        maxRRIdx = peakIdx
                        maxRRTimestamp = detectedPeak.timestamp
                    }
                }
                lastPeakTimestamp = detectedPeak.timestamp
                
                // STEP 3: Adaptive lockout (from Normal-beat baseline)
                let lockoutMs: Double
                if rollingNormalRRs.isEmpty {
                    lockoutMs = 300.0
                } else {
                    let avgRR = rollingNormalRRs.reduce(0, +) / Double(rollingNormalRRs.count)
                    lockoutMs = min(350.0, max(200.0, avgRR * 0.40))
                }
                let lockoutSamples = Int(lockoutMs * 0.13)
                
                // Adaptive threshold
                threshold = max(250.0, peakVal * 0.6)
                
                // STEP 4: Relative anomaly detection + CoreML classification
                let avgNormalRR = rollingNormalRRs.isEmpty ? 0.0 :
                    rollingNormalRRs.reduce(0, +) / Double(rollingNormalRRs.count)
                let isPrematureCandidate = rollingNormalRRs.count >= 2 &&
                    currentRR > 0 &&
                    currentRR < avgNormalRR * 0.80
                let shouldRunML = (isPrematureCandidate || rollingNormalRRs.count < 2) && currentRR > 0
                
                // Extract 130-sample window from filtered signal
                let startSlice = peakIdx - 65
                let endSlice = peakIdx + 64
                if startSlice >= 0 && endSlice < filteredSignal.count {
                    var values = Array(filteredSignal[startSlice...endSlice])
                    
                    // Amplitude check: reject noise/flatlines
                    if let maxVal = values.max(), let minVal = values.min(), (maxVal - minVal) >= 150.0 {
                        let mean = values.reduce(0, +) / Double(values.count)
                        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)
                        let std = sqrt(variance)
                        
                        if std > 0 {
                            values = values.map { ($0 - mean) / std }
                            
                            if shouldRunML {
                                do {
                                    let mlArray = try MLMultiArray(shape: [1, 130, 1], dataType: .float32)
                                    for (index, value) in values.enumerated() {
                                        mlArray[index] = NSNumber(value: Float32(value))
                                    }
                                    
                                    if let actualModel = model as? ECGMorphologyClassifier {
                                        let input = ECGMorphologyClassifierInput(signal: mlArray)
                                        let prediction = try actualModel.prediction(input: input)
                                        
                                        switch prediction.classLabel {
                                        case "V":
                                            anomalies.append(AnomalyEvent(type: .pvc, timestamp: detectedPeak.timestamp, rrInterval: currentRR))
                                            if anomalySnippets.count < maxAnomalySnippets {
                                                if let s = extractSnippet(label: "PVC @ \(timeLabel(detectedPeak.timestamp))", timestamp: detectedPeak.timestamp, peakIdx: peakIdx, filteredSignal: filteredSignal, color: .systemRed) {
                                                    anomalySnippets.append(s)
                                                }
                                            }
                                        case "A":
                                            anomalies.append(AnomalyEvent(type: .abnormal, timestamp: detectedPeak.timestamp, rrInterval: currentRR))
                                            if anomalySnippets.count < maxAnomalySnippets {
                                                if let s = extractSnippet(label: "PAC @ \(timeLabel(detectedPeak.timestamp))", timestamp: detectedPeak.timestamp, peakIdx: peakIdx, filteredSignal: filteredSignal, color: .systemOrange) {
                                                    anomalySnippets.append(s)
                                                }
                                            }
                                        case "N":
                                            // Normal beat: update rolling baseline
                                            rollingNormalRRs.append(currentRR)
                                            if rollingNormalRRs.count > 4 { rollingNormalRRs.removeFirst() }
                                        default:
                                            break
                                        }
                                    }
                                } catch {
                                    print("ML Inference failed: \(error)")
                                }
                            } else {
                                // Not a premature candidate, but passed amplitude check -> healthy normal-timing beat
                                rollingNormalRRs.append(currentRR)
                                if rollingNormalRRs.count > 4 { rollingNormalRRs.removeFirst() }
                            }
                        }
                    } else {
                        // Window failed amplitude check → artifact
                        artifactCount += 1
                    }
                }
                
                // STEP 5: Enforce lockout
                i = peakIdx + lockoutSamples
            } else {
                // Decay threshold if no peak for > 2 seconds
                let timeSinceLastPeak = lastPeakTimestamp > 0 && sortedEcgData[i].timestamp > lastPeakTimestamp
                    ? sortedEcgData[i].timestamp - lastPeakTimestamp
                    : 0
                
                if timeSinceLastPeak > 2000 {
                    threshold = max(200.0, threshold * 0.95)
                }
                i += 1
            }
        }
        
        // --- Post-loop: Build snippets for Min HR / Max HR ---
        var allSnippets = anomalySnippets
        
        if minRR < Double.greatestFiniteMagnitude && minRRTimestamp > 0 {
            let bpm = 60000.0 / minRR
            if let s = extractSnippet(
                label: "Max HR (\(Int(bpm)) bpm) @ \(timeLabel(minRRTimestamp))",
                timestamp: minRRTimestamp, peakIdx: minRRIdx,
                filteredSignal: filteredSignal, color: .systemBlue
            ) {
                allSnippets.append(s)
            }
        }
        
        if maxRR > 0 && maxRRTimestamp > 0 {
            let bpm = 60000.0 / maxRR
            if let s = extractSnippet(
                label: "Min HR (\(Int(bpm)) bpm) @ \(timeLabel(maxRRTimestamp))",
                timestamp: maxRRTimestamp, peakIdx: maxRRIdx,
                filteredSignal: filteredSignal, color: .systemTeal
            ) {
                allSnippets.append(s)
            }
        }
        
        // --- Compute final statistics ---
        let beatsWithRR = totalBeats > 1 ? totalBeats - 1 : 0  // First beat has no RR
        let artifactPct = totalBeats > 0 ? (Double(artifactCount) / Double(totalBeats)) * 100.0 : 0.0
        let pnn50 = totalRRPairs > 0 ? (Double(pNN50Count) / Double(totalRRPairs)) * 100.0 : 0.0
        let tachyBurden = beatsWithRR > 0 ? (Double(tachyCount) / Double(beatsWithRR)) * 100.0 : 0.0
        let bradyBurden = beatsWithRR > 0 ? (Double(bradyCount) / Double(beatsWithRR)) * 100.0 : 0.0
        let avgRRFinal = beatsWithRR > 0 ? rrSum / Double(beatsWithRR) : 0
        let avgBpm = avgRRFinal > 0 ? 60000.0 / avgRRFinal : 0
        let minBpm = maxRR > 0 ? 60000.0 / maxRR : 0       // max RR → min bpm
        let maxBpm = minRR < Double.greatestFiniteMagnitude ? 60000.0 / minRR : 0
        
        return SessionSummary(
            totalBeats: totalBeats,
            artifactPercent: artifactPct,
            pNN50: pnn50,
            tachycardiaBurden: tachyBurden,
            bradycardiaBurden: bradyBurden,
            anomalies: anomalies,
            snippets: allSnippets,
            minHRBpm: minBpm,
            maxHRBpm: maxBpm,
            avgHRBpm: avgBpm
        )
    }
}
