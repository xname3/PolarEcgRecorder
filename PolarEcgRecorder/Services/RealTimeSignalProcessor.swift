import Foundation
import CoreML
import UIKit
import Combine

public class RealTimeSignalProcessor: ObservableObject {
    @Published public var rtExtrasystoleCount: Int = 0
    public var rtDetectionEnabled: Bool = false
    public var rtBeepEnabled: Bool = true
    public var rtUseAIDetection: Bool = true
    
    private var morphologyModel: Any? // ECGMorphologyClassifier
    private var rtThreshold: Double = 400.0
    private var rtLastPeakTimestamp: UInt64 = 0
    private var rtNormalRRs: [Double] = []
    private var rtEcgBuffer: [(timestamp: UInt64, value: Double)] = [] 
    
    // Butterworth filter coefficients & state
    private var btB0: Double = 0.0
    private var btB1: Double = 0.0
    private var btB2: Double = 0.0
    private var btA1: Double = 0.0
    private var btA2: Double = 0.0
    private var btW1: Double = 0.0
    private var btW2: Double = 0.0

    // Real-time peak detector state
    private var rtSearchIdx: Int = 0
    private var rtLockoutEndIndex: Int = 0
    private var rtSamplesProcessed: Int = 0

    public init() {
        do {
            morphologyModel = try ECGMorphologyClassifier(configuration: MLModelConfiguration())
        } catch {
            print("Failed to load ECGMorphologyClassifier: \(error)")
        }
        
        let sampleRate: Double = 130.0
        let cutoff: Double = 0.67
        let omega = tan(Double.pi * cutoff / sampleRate)
        let omega2 = omega * omega
        let sqrt2 = sqrt(2.0)
        let denom = 1.0 + sqrt2 * omega + omega2
        
        self.btB0 =  1.0 / denom
        self.btB1 = -2.0 / denom
        self.btB2 =  1.0 / denom
        self.btA1 =  2.0 * (omega2 - 1.0) / denom
        self.btA2 =  (1.0 - sqrt2 * omega + omega2) / denom
    }
    
    public func reset() {
        DispatchQueue.main.async {
            self.rtExtrasystoleCount = 0
        }
        rtEcgBuffer.removeAll()
        rtNormalRRs.removeAll()
        rtLastPeakTimestamp = 0
        rtThreshold = 400.0
        btW1 = 0.0
        btW2 = 0.0
        rtSearchIdx = 0
        rtLockoutEndIndex = 0
        rtSamplesProcessed = 0
    }
    
    private func applyRtHighPass(_ sample: Double) -> Double {
        let w0 = sample - btA1 * btW1 - btA2 * btW2
        let filtered = btB0 * w0 + btB1 * btW1 + btB2 * btW2
        btW2 = btW1
        btW1 = w0
        return filtered
    }
    
    public func processSample(timestamp: UInt64, value: Int32) async {
        guard rtDetectionEnabled else { return }
        
        let v_bt = applyRtHighPass(Double(value))
        rtEcgBuffer.append((timestamp, v_bt))
        rtSamplesProcessed += 1
        
        if rtSamplesProcessed > 500 {
            while rtSearchIdx + 64 < rtEcgBuffer.count {
                let val = rtEcgBuffer[rtSearchIdx].value
                let ts = rtEcgBuffer[rtSearchIdx].timestamp
                
                if rtSearchIdx < rtLockoutEndIndex {
                    rtSearchIdx += 1
                    continue
                }
                
                if val > rtThreshold {
                    let endIdx = rtSearchIdx + 15
                    var peakIdx = rtSearchIdx
                    var peakVal = val
                    for j in rtSearchIdx...endIdx {
                        if rtEcgBuffer[j].value > peakVal {
                            peakVal = rtEcgBuffer[j].value
                            peakIdx = j
                        }
                    }
                    
                    if peakIdx + 64 >= rtEcgBuffer.count {
                        break 
                    }
                    
                    let detectedPeak = rtEcgBuffer[peakIdx]
                    var currentRR: Double = 0
                    if rtLastPeakTimestamp > 0 && detectedPeak.timestamp > rtLastPeakTimestamp {
                        currentRR = Double(detectedPeak.timestamp - rtLastPeakTimestamp)
                    }
                    
                    let windowStart = peakIdx - 65
                    let windowEnd = peakIdx + 64
                    if windowStart >= 0 {
                        let window = rtEcgBuffer[windowStart...windowEnd].map { $0.value }
                        if let maxVal = window.max(), let minVal = window.min(), (maxVal - minVal) >= 150.0 {
                            let mean = window.reduce(0, +) / Double(window.count)
                            let variance = window.map { pow($0 - mean, 2) }.reduce(0, +) / Double(window.count)
                            let std = sqrt(variance)
                            
                            if std > 0 {
                                let normalized = window.map { Float32(($0 - mean) / std) }
                                let avgNormalRR = rtNormalRRs.isEmpty ? 0.0 : rtNormalRRs.reduce(0, +) / Double(rtNormalRRs.count)
                                let isPrematureCandidate = rtNormalRRs.count >= 2 && currentRR > 0 && currentRR < avgNormalRR * 0.80
                                let shouldRunML = (isPrematureCandidate || rtNormalRRs.count < 2) && currentRR > 0
                                
                                if rtUseAIDetection {
                                    if shouldRunML, let model = morphologyModel as? ECGMorphologyClassifier {
                                        do {
                                            let mlArray = try MLMultiArray(shape: [1, 130, 1], dataType: .float32)
                                            for (index, value) in normalized.enumerated() {
                                                mlArray[index] = NSNumber(value: value)
                                            }
                                            let input = ECGMorphologyClassifierInput(signal: mlArray)
                                            let prediction = try await model.prediction(input: input)
                                            
                                            if prediction.classLabel == "V" || prediction.classLabel == "A" {
                                                await MainActor.run {
                                                    self.rtExtrasystoleCount += 1
                                                }
                                                if self.rtBeepEnabled {
                                                    await MainActor.run { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                                                }
                                            } else if prediction.classLabel == "N" {
                                                self.rtNormalRRs.append(currentRR)
                                                if self.rtNormalRRs.count > 4 { self.rtNormalRRs.removeFirst() }
                                            }
                                        } catch {
                                            print("Real-time CoreML prediction error: \(error)")
                                        }
                                    } else if currentRR > 0 {
                                        rtNormalRRs.append(currentRR)
                                        if rtNormalRRs.count > 4 { rtNormalRRs.removeFirst() }
                                    }
                                } else {
                                    if isPrematureCandidate {
                                        await MainActor.run {
                                            self.rtExtrasystoleCount += 1
                                        }
                                        if self.rtBeepEnabled {
                                            await MainActor.run { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
                                        }
                                    } else if currentRR > 0 {
                                        rtNormalRRs.append(currentRR)
                                        if rtNormalRRs.count > 4 { rtNormalRRs.removeFirst() }
                                    }
                                }
                            }
                        }
                    }
                    
                    rtLastPeakTimestamp = detectedPeak.timestamp
                    rtThreshold = max(250.0, peakVal * 0.6)
                    
                    let lockoutMs: Double
                    if rtNormalRRs.isEmpty {
                        lockoutMs = 300.0
                    } else {
                        let avgRR = rtNormalRRs.reduce(0, +) / Double(rtNormalRRs.count)
                        lockoutMs = min(350.0, max(200.0, avgRR * 0.40))
                    }
                    let lockoutSamples = Int(lockoutMs * 0.13)
                    rtLockoutEndIndex = peakIdx + lockoutSamples
                    rtSearchIdx = peakIdx + lockoutSamples
                } else {
                    let timeSinceLastPeak = rtLastPeakTimestamp > 0 && ts > rtLastPeakTimestamp ? ts - rtLastPeakTimestamp : 0
                    if timeSinceLastPeak > 2000 {
                        rtThreshold = max(200.0, rtThreshold * 0.95)
                    }
                    rtSearchIdx += 1
                }
            }
        } else {
            rtSearchIdx = max(0, rtEcgBuffer.count - 65)
        }
        
        let trimCount = rtSearchIdx - 100
        if trimCount > 0 {
            rtEcgBuffer.removeFirst(trimCount)
            rtSearchIdx -= trimCount
            rtLockoutEndIndex = max(0, rtLockoutEndIndex - trimCount)
        }
    }
}
