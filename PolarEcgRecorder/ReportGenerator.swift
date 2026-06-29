//
//  ReportGenerator.swift
//  PolarEcgRecorder
//
//  Created by Marek Janosik on 27.06.2026.
//

import Foundation
import UIKit
import CoreML
import Accelerate

// MARK: - Data models
struct ECGSample { let timestamp: UInt64; let microVolts: Int32; let isEvent: Bool }
struct HRSample  { let timestamp: UInt64; let bpm: UInt8 }
struct HRVSample { let timestamp: UInt64; let rmssd: Double; let rrIntervals: [Int] }

// MARK: - DataIntegrityError
enum DataIntegrityError: LocalizedError {
    case insufficientECGData(expected: Int, actual: Int)
    case insufficientHRData(expected: Int, actual: Int)
    case massiveECGGap(gapMs: UInt64)
    case massiveHRVGap(gapMs: UInt64)
    case noData
    
    var errorDescription: String? {
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

// MARK: - Report Generator
class ReportGenerator {
    static let W: CGFloat = 595     // A4
    static let H: CGFloat = 842
    static let M: CGFloat = 44      // margin
    static let CW: CGFloat = 595 - 2 * 44 // content width

    // MARK: - Public entry point
    static func generate(group: SessionGroup, summary: SessionSummary, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var ecg = parseECG(group.ecgURL)
            var hr  = parseHR (group.hrURL)
            var hrv = parseHRV(group.hrvURL)
            
            do {
                try validateDataIntegrity(ecg: &ecg, hr: &hr, hrv: &hrv)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            
            if let url = buildPDF(group: group, ecg: ecg, hr: hr, hrv: hrv, summary: summary) {
                DispatchQueue.main.async { completion(.success(url)) }
            } else {
                DispatchQueue.main.async { completion(.failure(DataIntegrityError.noData)) }
            }
        }
    }

    static func validateDataIntegrity(ecg: inout [ECGSample], hr: inout [HRSample], hrv: inout [HRVSample]) throws {
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

    // MARK: - CSV Parsers
    static func parseECG(_ url: URL?) -> [ECGSample] {
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

    static func parseHR(_ url: URL?) -> [HRSample] {
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

    static func parseHRV(_ url: URL?) -> [HRVSample] {
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

    // MARK: - PDF builder
    private static func buildPDF(
        group: SessionGroup,
        ecg: [ECGSample], hr: [HRSample], hrv: [HRVSample], summary: SessionSummary
    ) -> URL? {

        // ── Stats ────────────────────────────────────────────────────────────
        let bpms    = hr.map  { Double($0.bpm) }
        let rmssds  = hrv.map { $0.rmssd }.filter { $0 > 0 }
        let avgHR   = bpms.isEmpty   ? 0.0 : bpms.reduce(0,+)   / Double(bpms.count)
        let minHR   = bpms.min()  ?? 0
        let maxHR   = bpms.max()  ?? 0
        let avgHRV  = rmssds.isEmpty ? 0.0 : rmssds.reduce(0,+) / Double(rmssds.count)
        let minHRV  = rmssds.min() ?? 0
        let maxHRV  = rmssds.max() ?? 0
        let duration: TimeInterval = {
            guard let a = hr.first?.timestamp, let b = hr.last?.timestamp else { return 0 }
            return Double(b - a) / 1000.0
        }()

        struct ReportEvent {
            let index: Int
            let typeName: String
            let timestamp: UInt64
            let color: UIColor
        }

        var combinedEvents: [ReportEvent] = []
        for idx in ecg.indices where ecg[idx].isEvent {
            combinedEvents.append(ReportEvent(index: idx, typeName: "MANUAL EVENT MARKER", timestamp: ecg[idx].timestamp, color: .systemBlue))
        }
        for anomaly in summary.anomalies {
            if let idx = ecg.firstIndex(where: { $0.timestamp >= anomaly.timestamp }) {
                let color = anomaly.type == .dropout ? UIColor.systemRed : UIColor.systemOrange
                combinedEvents.append(ReportEvent(index: idx, typeName: "ANOMALY: \(anomaly.type.rawValue.uppercased())", timestamp: anomaly.timestamp, color: color))
            }
        }
        combinedEvents.sort(by: { $0.timestamp < $1.timestamp })

        // ── PDF setup ────────────────────────────────────────────────────────

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: W, height: H))
        let data = renderer.pdfData { ctx in
            var currentPage = 1
            func addNewPage() {
                ReportGenerator.drawFooter(ctx: ctx.cgContext, pageNum: currentPage)
                currentPage += 1
                ctx.beginPage()
            }

            // ── PAGE 1: Summary ──────────────────────────────────────────────
            ctx.beginPage()
            var y = M

            // Logo strip
            let cgc = ctx.cgContext
            cgc.setFillColor(UIColor.systemRed.withAlphaComponent(0.9).cgColor)
            cgc.fill(CGRect(x: 0, y: 0, width: W, height: 6))

            // Title
            attr("COMPREHENSIVE ECG & HRV REPORT",
                 font: .boldSystemFont(ofSize: 20), color: .black)
                .draw(at: CGPoint(x: M, y: y)); y += 28

            let df = DateFormatter(); df.dateStyle = .long; df.timeStyle = .medium
            attr("Recorded: \(df.string(from: group.sessionDate))   •   Duration: \(fmtDur(duration))   •   Device: Polar H10",
                 font: .systemFont(ofSize: 10), color: .darkGray)
                .draw(at: CGPoint(x: M, y: y)); y += 16
                
            let reportId = UserDefaults.standard.string(forKey: "reportIdentification") ?? ""
            if !reportId.trimmingCharacters(in: .whitespaces).isEmpty {
                attr("Patient / ID: \(reportId)",
                     font: .systemFont(ofSize: 10, weight: .medium), color: .black)
                    .draw(at: CGPoint(x: M, y: y)); y += 16
            }

            attr("Analyzed by ECG Polar H10 App  •  Local Processing  •  Single-lead ECG (130 Hz)",
                 font: .italicSystemFont(ofSize: 9), color: .gray)
                .draw(at: CGPoint(x: M, y: y)); y += 20

            hLine(ctx: cgc, x: M, y: y, w: CW); y += 16

            // Stats grid — Heart Rate
            sectionTitle("Measurement Summary", ctx: cgc, y: &y, x: M, w: CW)
            let stats: [(String, String, String)] = [
                ("Avg HR",           fmtD(avgHR, dec: 0), "BPM"),
                ("Min HR",           "\(Int(minHR))",     "BPM"),
                ("Max HR",           "\(Int(maxHR))",     "BPM"),
                ("Avg RMSSD",        avgHRV > 0 ? fmtD(avgHRV) : "N/A", "ms"),
                ("Min RMSSD",        minHRV > 0 ? fmtD(minHRV) : "N/A", "ms"),
                ("Max RMSSD",        maxHRV > 0 ? fmtD(maxHRV) : "N/A", "ms"),
                ("Events Found",     "\(combinedEvents.count)", "")            ]
            y = drawStatsGrid(stats: stats, ctx: cgc, y: y, x: M, cw: CW)
            y += 10

            // Stats grid — Advanced ECG Analysis
            sectionTitle("ECG Signal Quality & Rhythm Analysis", ctx: cgc, y: &y, x: M, w: CW)
            let ecgStats: [(String, String, String)] = [
                ("Total Beats",       "\(summary.totalBeats)",              ""),
                ("Artifact / Noise",  fmtD(summary.artifactPercent) + "%", "of windows"),
                ("pNN50",             fmtD(summary.pNN50) + "%",           "HRV index"),
                ("Tachy Burden",      fmtD(summary.tachycardiaBurden) + "%", ">100 bpm"),
                ("Brady Burden",      fmtD(summary.bradycardiaBurden) + "%", "<50 bpm"),
                ("AI Anomalies",      "\(summary.anomalies.count)",        "detected"),
            ]
            y = drawStatsGrid(stats: ecgStats, ctx: cgc, y: y, x: M, cw: CW)
            y += 14

            if avgHRV > 0 {
                let interp = hrvInterpretation(avgHRV)
                drawInfoBox(text: "HRV Interpretation: \(interp)",
                            ctx: cgc, y: &y, x: M, w: CW, color: hrvColor(avgHRV))
                y += 12
            }

            if hr.count > 1 {
                sectionTitle("Heart Rate Trend", ctx: cgc, y: &y, x: M, w: CW)
                drawHRChart(hr: hr, ctx: cgc,
                            rect: CGRect(x: M, y: y, width: CW, height: 110))
                y += 124
            }

            if hrv.count > 1 {
                let halfW = (CW - 16) / 2
                let topY = y
                
                sectionTitle("HRV (RMSSD) Trend", ctx: cgc, y: &y, x: M, w: halfW)
                drawHRVChart(hrv: hrv, ctx: cgc,
                             rect: CGRect(x: M, y: y, width: halfW, height: 130))
                
                var py = topY
                sectionTitle("Poincaré Plot (RR Intervals)", ctx: cgc, y: &py, x: M + halfW + 16, w: halfW)
                drawPoincarePlot(hrv: hrv, ctx: cgc,
                                 rect: CGRect(x: M + halfW + 16, y: py, width: halfW, height: 130))
                
                y += 140
            }

            // ── EVENT PAGES ──────────────────────────────────────────────────
            for (evNum, event) in combinedEvents.enumerated() {
                addNewPage()
                let cgc2 = ctx.cgContext
                cgc2.setFillColor(event.color.withAlphaComponent(0.9).cgColor)
                cgc2.fill(CGRect(x: 0, y: 0, width: W, height: 6))

                var ey = M
                let eventTime = dateFromPolarTimestamp(event.timestamp)
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .medium
                let eventTimeStr = df.string(from: eventTime)

                attr("RECORDED EVENT \(evNum + 1) / \(combinedEvents.count)   •   \(eventTimeStr)",
                     font: .boldSystemFont(ofSize: 15), color: event.color)
                    .draw(at: CGPoint(x: M, y: ey)); ey += 22
                    
                attr("Type: \(event.typeName)", font: .boldSystemFont(ofSize: 12), color: .black)
                    .draw(at: CGPoint(x: M, y: ey)); ey += 16

                attr("ECG Window: 30s before event (▼) and 30s after  •  130 Hz  •  units µV",
                     font: .systemFont(ofSize: 9), color: .darkGray)
                    .draw(at: CGPoint(x: M, y: ey)); ey += 18

                hLine(ctx: cgc2, x: M, y: ey, w: CW); ey += 12

                // Extract 30 s before and 30 s after at index level
                let before = 130 * 30
                let after  = 130 * 30
                let start  = max(0, event.index - before)
                let end    = min(ecg.count - 1, event.index + after)
                let window = Array(ecg[start...end])
                let eventPosInWindow = event.index - start   // where marker falls in window

                // Draw 10-second strips
                let stripSamples = 130 * 10   // 1 300 samples per strip
                let stripH: CGFloat = 68
                let stripGap: CGFloat = 18
                var stripStart = 0

                while stripStart < window.count {
                    let stripEnd = min(stripStart + stripSamples, window.count)
                    let strip    = Array(window[stripStart..<stripEnd])
                    let secLabel = (stripStart - eventPosInWindow) / 130  // signed seconds relative to event
                    
                    let sampleIdx = start + stripStart
                    let stripTime = dateFromPolarTimestamp(ecg[sampleIdx].timestamp)
                    let tf = DateFormatter()
                    tf.dateFormat = "HH:mm:ss"
                    let timeStr = tf.string(from: stripTime)
                    
                    let labelStr = "\(secLabel >= 0 ? "+" : "")\(secLabel)s\n\(timeStr)"
                    let hasEvent = (stripStart...stripEnd).contains(eventPosInWindow)
                    let evXFrac: CGFloat? = hasEvent
                        ? CGFloat(eventPosInWindow - stripStart) / CGFloat(strip.count)
                        : nil

                    // Time label
                    attr(labelStr, font: .monospacedSystemFont(ofSize: 6.5, weight: .regular),
                         color: .darkGray)
                        .draw(at: CGPoint(x: M, y: ey + 4))

                    let rect = CGRect(x: M + 36, y: ey, width: CW - 36, height: stripH)
                    drawECGStrip(samples: strip.map { Double($0.microVolts) },
                                 ctx: cgc2, rect: rect,
                                 eventXFraction: evXFrac)
                    ey += stripH + stripGap

                    if ey > H - M - stripH - stripGap {
                        addNewPage()
                        ey = M
                        cgc2.setFillColor(event.color.withAlphaComponent(0.9).cgColor)
                        cgc2.fill(CGRect(x: 0, y: 0, width: W, height: 6))
                    }
                    stripStart += stripSamples
                }
            }

            // If no manual events: short note page
            if combinedEvents.isEmpty {
                addNewPage()
                var ny = M
                attr("No manual events were recorded during this session.",
                     font: .systemFont(ofSize: 13), color: .darkGray)
                    .draw(at: CGPoint(x: M, y: ny)); ny += 20
                attr("The MARK EVENT button was not pressed.",
                     font: .systemFont(ofSize: 11), color: .gray)
                    .draw(at: CGPoint(x: M, y: ny))
            }

            // ── SNIPPET PAGES (AI-detected events + HR extremes) ─────────────
            if !summary.snippets.isEmpty {
                addNewPage()
                let cgcS = ctx.cgContext
                cgcS.setFillColor(UIColor.systemPurple.withAlphaComponent(0.9).cgColor)
                cgcS.fill(CGRect(x: 0, y: 0, width: W, height: 6))
                var sy = M
                attr("AI ECG ANALYSIS — EVENT SNIPPETS (\(summary.snippets.count))",
                     font: .boldSystemFont(ofSize: 16), color: .black)
                    .draw(at: CGPoint(x: M, y: sy)); sy += 22
                attr("3-second windows centered on detected events  •  130 Hz filtered signal",
                     font: .systemFont(ofSize: 9), color: .darkGray)
                    .draw(at: CGPoint(x: M, y: sy)); sy += 18
                hLine(ctx: cgcS, x: M, y: sy, w: CW); sy += 12

                let snippetH: CGFloat = 90
                let snippetGap: CGFloat = 14

                for snippet in summary.snippets {
                    // Check if we need a new page
                    if sy + snippetH + snippetGap + 20 > H - M {
                        addNewPage()
                        sy = M
                        let cgcN = ctx.cgContext
                        cgcN.setFillColor(UIColor.systemPurple.withAlphaComponent(0.9).cgColor)
                        cgcN.fill(CGRect(x: 0, y: 0, width: W, height: 6))
                    }

                    // Snippet label
                    attr(snippet.label,
                         font: .boldSystemFont(ofSize: 10), color: snippet.color)
                        .draw(at: CGPoint(x: M, y: sy)); sy += 14

                    // Draw the snippet graph with memory safety
                    autoreleasepool {
                        let rect = CGRect(x: M, y: sy, width: CW, height: snippetH)
                        drawSnippetGraph(snippet: snippet, ctx: ctx.cgContext, rect: rect)
                    }
                    sy += snippetH + snippetGap
                }
            }

            ReportGenerator.drawFooter(ctx: ctx.cgContext, pageNum: currentPage)
        }

        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ECG_Report_\(group.sessionKey).pdf")
        do { try data.write(to: out); return out }
        catch { print("❌ PDF write: \(error)"); return nil }
    }

    // MARK: - Drawing primitives

    private static func drawECGStrip(
        samples: [Double],
        ctx: CGContext,
        rect: CGRect,
        eventXFraction: CGFloat?
    ) {
        // Background
        ctx.setFillColor(UIColor.white.cgColor); ctx.fill(rect)

        // Minor grid
        ctx.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.06).cgColor)
        ctx.setLineWidth(0.3)
        let cols = 50; let rows = 20
        for i in 0...cols { let x = rect.minX + CGFloat(i)/CGFloat(cols)*rect.width
            ctx.move(to:.init(x:x,y:rect.minY)); ctx.addLine(to:.init(x:x,y:rect.maxY)) }
        for i in 0...rows { let y = rect.minY + CGFloat(i)/CGFloat(rows)*rect.height
            ctx.move(to:.init(x:rect.minX,y:y)); ctx.addLine(to:.init(x:rect.maxX,y:y)) }
        ctx.strokePath()

        // Major grid (5 columns per big square)
        ctx.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.6)
        for i in 0...10 { let x = rect.minX + CGFloat(i)/10.0*rect.width
            ctx.move(to:.init(x:x,y:rect.minY)); ctx.addLine(to:.init(x:x,y:rect.maxY)) }
        for i in 0...4  { let y = rect.minY + CGFloat(i)/4.0*rect.height
            ctx.move(to:.init(x:rect.minX,y:y)); ctx.addLine(to:.init(x:rect.maxX,y:y)) }
        ctx.strokePath()

        // Event marker
        if let fx = eventXFraction {
            let ex = rect.minX + fx * rect.width
            ctx.setFillColor(UIColor.systemOrange.withAlphaComponent(0.08).cgColor)
            ctx.fill(CGRect(x: ex - 6, y: rect.minY, width: 12, height: rect.height))
            ctx.setStrokeColor(UIColor.systemOrange.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.5); ctx.setLineDash(phase: 0, lengths: [4,3])
            ctx.move(to:.init(x:ex,y:rect.minY)); ctx.addLine(to:.init(x:ex,y:rect.maxY))
            ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
        }

        // Border
        ctx.setStrokeColor(UIColor(white: 0.80, alpha: 1.0).cgColor); ctx.setLineWidth(0.5); ctx.stroke(rect)

        // ECG line
        guard samples.count >= 2 else { return }
        ctx.setStrokeColor(UIColor.systemRed.cgColor)
        ctx.setLineWidth(1.1); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let path = CGMutablePath()
        let minV = -800.0, maxV = 1400.0, range = maxV - minV
        for (i, s) in samples.enumerated() {
            let x = rect.minX + CGFloat(i) / CGFloat(samples.count) * rect.width
            let y = rect.maxY - CGFloat((min(maxV, max(minV, s)) - minV) / range) * rect.height
            i == 0 ? path.move(to:.init(x:x,y:y)) : path.addLine(to:.init(x:x,y:y))
        }
        ctx.addPath(path); ctx.strokePath()
    }

    private static func drawSnippetGraph(snippet: EventSnippet, ctx: CGContext, rect: CGRect) {
        // Background
        ctx.setFillColor(UIColor.white.cgColor); ctx.fill(rect)

        // Minor grid (every 0.04s -> 1/25 of a second. At 130Hz, 3s = 390 samples. Let's make a grid for 3 seconds)
        // 3 seconds = 3000 ms. Minor grid every 40ms = 75 cols.
        ctx.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.06).cgColor)
        ctx.setLineWidth(0.3)
        let cols = 75; let rows = 20
        for i in 0...cols { let x = rect.minX + CGFloat(i)/CGFloat(cols)*rect.width
            ctx.move(to:.init(x:x,y:rect.minY)); ctx.addLine(to:.init(x:x,y:rect.maxY)) }
        for i in 0...rows { let y = rect.minY + CGFloat(i)/CGFloat(rows)*rect.height
            ctx.move(to:.init(x:rect.minX,y:y)); ctx.addLine(to:.init(x:rect.maxX,y:y)) }
        ctx.strokePath()

        // Major grid (every 0.2s -> 5 minor blocks = 15 cols total)
        ctx.setStrokeColor(UIColor.systemRed.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(0.6)
        for i in 0...15 { let x = rect.minX + CGFloat(i)/15.0*rect.width
            ctx.move(to:.init(x:x,y:rect.minY)); ctx.addLine(to:.init(x:x,y:rect.maxY)) }
        for i in 0...4  { let y = rect.minY + CGFloat(i)/4.0*rect.height
            ctx.move(to:.init(x:rect.minX,y:y)); ctx.addLine(to:.init(x:rect.maxX,y:y)) }
        ctx.strokePath()

        // Center marker
        let ex = rect.minX + 0.5 * rect.width
        ctx.setFillColor(snippet.color.withAlphaComponent(0.08).cgColor)
        ctx.fill(CGRect(x: ex - 6, y: rect.minY, width: 12, height: rect.height))
        ctx.setStrokeColor(snippet.color.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.5); ctx.setLineDash(phase: 0, lengths: [4,3])
        ctx.move(to:.init(x:ex,y:rect.minY)); ctx.addLine(to:.init(x:ex,y:rect.maxY))
        ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])

        // Border
        ctx.setStrokeColor(UIColor(white: 0.80, alpha: 1.0).cgColor); ctx.setLineWidth(0.5); ctx.stroke(rect)

        // Signal line
        guard snippet.samples.count >= 2 else { return }
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(1.0); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let path = CGMutablePath()
        
        // Auto-scale Y axis slightly based on this snippet, but clamp it so flatlines look flat
        let minV = min(-500.0, (snippet.samples.min() ?? -500.0) - 100)
        let maxV = max(1000.0, (snippet.samples.max() ?? 1000.0) + 100)
        let range = max(maxV - minV, 1.0)
        
        for (i, s) in snippet.samples.enumerated() {
            let x = rect.minX + CGFloat(i) / CGFloat(snippet.samples.count) * rect.width
            let y = rect.maxY - CGFloat((s - minV) / range) * rect.height
            i == 0 ? path.move(to:.init(x:x,y:y)) : path.addLine(to:.init(x:x,y:y))
        }
        ctx.addPath(path); ctx.strokePath()
    }

    private static func drawHRChart(hr: [HRSample], ctx: CGContext, rect: CGRect) {
        ctx.setFillColor(UIColor(white: 0.95, alpha: 1.0).cgColor); ctx.fill(rect)
        let bpms = hr.map { Double($0.bpm) }
        let lo = (bpms.min() ?? 40) - 8, hi = (bpms.max() ?? 180) + 8, rng = hi - lo
        // Grid
        ctx.setStrokeColor(UIColor(white: 0.85, alpha: 1.0).cgColor); ctx.setLineWidth(0.3)
        for v in stride(from: 40.0, through: 200.0, by: 20.0) {
            guard v > lo && v < hi else { continue }
            let y = rect.maxY - CGFloat((v - lo) / rng) * rect.height
            ctx.move(to:.init(x:rect.minX,y:y)); ctx.addLine(to:.init(x:rect.maxX,y:y))
            attr("\(Int(v)) ", font: .systemFont(ofSize: 6.5), color: .secondaryLabel)
                .draw(at: CGPoint(x: rect.minX + 2, y: y - 7))
        }
        ctx.strokePath()
        // Line
        ctx.setStrokeColor(UIColor.systemRed.cgColor); ctx.setLineWidth(1.3)
        let p = CGMutablePath()
        for (i, s) in hr.enumerated() {
            let x = rect.minX + CGFloat(i)/CGFloat(hr.count)*rect.width
            let y = rect.maxY - CGFloat((Double(s.bpm)-lo)/rng)*rect.height
            i == 0 ? p.move(to:.init(x:x,y:y)) : p.addLine(to:.init(x:x,y:y))
        }
        ctx.addPath(p); ctx.strokePath()
        ctx.setStrokeColor(UIColor(white: 0.70, alpha: 1.0).cgColor); ctx.setLineWidth(0.5); ctx.stroke(rect)
    }

    private static func drawHRVChart(hrv: [HRVSample], ctx: CGContext, rect: CGRect) {
        let valid = hrv.filter { $0.rmssd > 0 }
        guard valid.count > 1 else { return }
        let lo = (valid.map{$0.rmssd}.min() ?? 0) * 0.85
        let hi = (valid.map{$0.rmssd}.max() ?? 100) * 1.15
        let rng = hi - lo
        // Fill
        let fill = CGMutablePath()
        for (i, s) in valid.enumerated() {
            let x = rect.minX + CGFloat(i)/CGFloat(valid.count)*rect.width
            let y = rect.maxY - CGFloat((s.rmssd-lo)/rng)*rect.height
            if i == 0 { fill.move(to:.init(x:x,y:rect.maxY)); fill.addLine(to:.init(x:x,y:y)) }
            else       { fill.addLine(to:.init(x:x,y:y)) }
        }
        fill.addLine(to:.init(x:rect.maxX,y:rect.maxY)); fill.closeSubpath()
        ctx.setFillColor(UIColor.systemIndigo.withAlphaComponent(0.12).cgColor)
        ctx.addPath(fill); ctx.fillPath()
        // Line
        ctx.setStrokeColor(UIColor.systemIndigo.cgColor); ctx.setLineWidth(1.3)
        let p = CGMutablePath()
        for (i, s) in valid.enumerated() {
            let x = rect.minX + CGFloat(i)/CGFloat(valid.count)*rect.width
            let y = rect.maxY - CGFloat((s.rmssd-lo)/rng)*rect.height
            i == 0 ? p.move(to:.init(x:x,y:y)) : p.addLine(to:.init(x:x,y:y))
        }
        ctx.addPath(p); ctx.strokePath()
        ctx.setStrokeColor(UIColor(white: 0.80, alpha: 1.0).cgColor); ctx.setLineWidth(0.5); ctx.stroke(rect)
    }

    private static func drawPoincarePlot(hrv: [HRVSample], ctx: CGContext, rect: CGRect) {
        let rrs = hrv.flatMap { $0.rrIntervals }
        guard rrs.count > 1 else { return }
        let sorted = rrs.sorted()
        let lo = CGFloat(sorted.first ?? 300) * 0.9
        let hi = CGFloat(sorted.last ?? 1200) * 1.1
        let rng = max(hi - lo, 1)
        
        ctx.setFillColor(UIColor(white: 0.95, alpha: 1.0).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(UIColor(white: 0.80, alpha: 1.0).cgColor)
        ctx.setLineWidth(0.5)
        ctx.stroke(rect)
        
        ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        ctx.strokePath()
        
        ctx.setFillColor(UIColor.systemRed.withAlphaComponent(0.5).cgColor)
        for i in 0..<(rrs.count - 1) {
            let rr_n = CGFloat(rrs[i])
            let rr_np1 = CGFloat(rrs[i+1])
            let x = rect.minX + ((rr_n - lo) / rng) * rect.width
            let y = rect.maxY - ((rr_np1 - lo) / rng) * rect.height
            if x >= rect.minX && x <= rect.maxX && y >= rect.minY && y <= rect.maxY {
                ctx.fillEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
            }
        }
        attr("RR(n)", font: .systemFont(ofSize: 7), color: .darkGray).draw(at: CGPoint(x: rect.midX - 10, y: rect.maxY + 2))
        attr("RR(n+1)", font: .systemFont(ofSize: 7), color: .darkGray).draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 4))
    }

    private static func drawStatsGrid(
        stats: [(String, String, String)],
        ctx: CGContext, y: CGFloat, x: CGFloat, cw: CGFloat
    ) -> CGFloat {
        let cols = 3; let cellW = cw / CGFloat(cols); let cellH: CGFloat = 56
        for (i, item) in stats.enumerated() {
            let col = CGFloat(i % cols); let row = CGFloat(i / cols)
            let cx = x + col * cellW; let cy = y + row * cellH
            ctx.setFillColor(UIColor(white: 0.95, alpha: 1.0).cgColor)
            ctx.fill(CGRect(x: cx + 3, y: cy + 2, width: cellW - 6, height: cellH - 4))
            attr(item.0, font: .systemFont(ofSize: 8.5), color: .darkGray)
                .draw(at: CGPoint(x: cx + 8, y: cy + 6))
            attr(item.1, font: .boldSystemFont(ofSize: 18), color: .black)
                .draw(at: CGPoint(x: cx + 8, y: cy + 18))
            attr(item.2, font: .systemFont(ofSize: 9), color: .darkGray)
                .draw(at: CGPoint(x: cx + 8, y: cy + 40))
        }
        let rows = CGFloat((stats.count + cols - 1) / cols)
        return y + rows * cellH
    }

    private static func drawInfoBox(text: String, ctx: CGContext,
                                    y: inout CGFloat, x: CGFloat, w: CGFloat, color: UIColor) {
        let boxH: CGFloat = 30
        ctx.setFillColor(color.withAlphaComponent(0.1).cgColor)
        ctx.fill(CGRect(x: x, y: y, width: w, height: boxH))
        ctx.setStrokeColor(color.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(0.8); ctx.stroke(CGRect(x: x, y: y, width: w, height: boxH))
        attr(text, font: .systemFont(ofSize: 10.5, weight: .medium), color: color)
            .draw(at: CGPoint(x: x + 10, y: y + 8))
        y += boxH
    }

    private static func drawFooter(ctx: CGContext, pageNum: Int) {
        let footerText = "Page \(pageNum)  •  ECG Polar H10 Report (Single-lead ECG, informational/fitness purposes only. Not a medical device.)"
        let font = UIFont.systemFont(ofSize: 7)
        let color = UIColor.lightGray
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = footerText.size(withAttributes: attrs)
        
        ctx.saveGState()
        let rect = CGRect(
            x: (W - size.width) / 2.0,
            y: H - 25,
            width: size.width,
            height: size.height
        )
        footerText.draw(in: rect, withAttributes: attrs)
        ctx.restoreGState()
    }

    // MARK: - Formatting helpers
    private static func sectionTitle(_ s: String, ctx: CGContext, y: inout CGFloat, x: CGFloat, w: CGFloat) {
        attr(s.uppercased(), font: .systemFont(ofSize: 10, weight: .semibold), color: .darkGray)
            .draw(at: CGPoint(x: x, y: y))
        y += 14
        ctx.setStrokeColor(UIColor(white: 0.85, alpha: 1.0).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to:.init(x:x,y:y)); ctx.addLine(to:.init(x:x+w,y:y)); ctx.strokePath()
        y += 8
    }

    private static func hLine(ctx: CGContext, x: CGFloat, y: CGFloat, w: CGFloat) {
        ctx.setStrokeColor(UIColor(white: 0.80, alpha: 1.0).cgColor); ctx.setLineWidth(0.8)
        ctx.move(to:.init(x:x,y:y)); ctx.addLine(to:.init(x:x+w,y:y)); ctx.strokePath()
    }

    private static func attr(_ s: String, font: UIFont, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    private static func fmtD(_ v: Double, dec: Int = 1) -> String {
        String(format: "%.\(dec)f", v)
    }

    private static func fmtDur(_ t: TimeInterval) -> String {
        String(format: "%02d:%02d:%02d", Int(t)/3600, (Int(t)%3600)/60, Int(t)%60)
    }

    // Converts Unix epoch timestamp (ms) to Date
    private static func dateFromPolarTimestamp(_ ts: UInt64) -> Date {
        let seconds = Double(ts) / 1000.0
        return Date(timeIntervalSince1970: seconds)
    }

    private static func hrvInterpretation(_ rmssd: Double) -> String {
        switch rmssd {
        case ..<20:  return "Low HRV (< 20 ms) — increased ANS load, fatigue, or pathology"
        case ..<50:  return "Normal HRV (20–50 ms) — typical adult range"
        default:     return "High HRV (> 50 ms) — good variability, healthy ANS"
        }
    }

    private static func hrvColor(_ rmssd: Double) -> UIColor {
        rmssd < 20 ? .systemRed : rmssd < 50 ? .systemOrange : .systemGreen
    }
    
    // MARK: - Anomaly Report Generator
}

enum AnomalyType: String {
    case dropout = "Pause (>1.5s)"
    case pvc = "Ventricular Extrasystole (PVC)"
    case abnormal = "Abnormal Beat (PAC/Other)"
}

struct AnomalyEvent: Identifiable {
    let id = UUID()
    let type: AnomalyType
    let timestamp: UInt64
    let rrInterval: Double
}

/// 3-second ECG snippet centered around an event for PDF graphs
struct EventSnippet {
    let label: String           // "PVC @ 14:32:07", "Min HR @ 13:58:22"
    let timestamp: UInt64
    let samples: [Double]       // ~390 filtered samples (3s × 130Hz)
    let color: UIColor          // red for PVC, orange for PAC, blue for min/max HR
}

/// Advanced session statistics computed during the single O(N) pass
struct SessionSummary {
    let totalBeats: Int
    let artifactPercent: Double       // % of windows failing 150µV p2p
    let pNN50: Double                 // % of successive RR diffs > 50ms
    let tachycardiaBurden: Double     // % of beats with RR < 600ms (>100 bpm)
    let bradycardiaBurden: Double     // % of beats with RR > 1200ms (<50 bpm)
    let anomalies: [AnomalyEvent]
    let snippets: [EventSnippet]      // Capped at 50 anomaly + 2 HR extreme
    let minHRBpm: Double
    let maxHRBpm: Double
    let avgHRBpm: Double
}

// MARK: - ECG Analyzer

class ECGAnalyzer {
    
    static let maxAnomalySnippets = 50
    static let snippetHalfWindow = 195   // 1.5s × 130Hz = 195 samples → 3s total
    
    // MARK: - High-Pass Filter (Baseline Wander Removal)
    
    /// 2nd-order Butterworth IIR high-pass filter. Removes baseline drift below cutoff.
    static func applyHighPassFilter(
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
    static func analyze(ecgData: [ECGSample]) -> SessionSummary {
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

