//
//  ReportGenerator.swift
//  PolarEcgRecorder
//
//  Created by Marek Janosik on 27.06.2026.
//

import Foundation
import UIKit

// MARK: - Data models
struct ECGSample { let timestamp: UInt64; let microVolts: Int32; let isEvent: Bool }
struct HRSample  { let timestamp: UInt64; let bpm: UInt8 }
struct HRVSample { let timestamp: UInt64; let rmssd: Double; let rrIntervals: [Int] }

// MARK: - Report Generator
class ReportGenerator {
    static let W: CGFloat = 595     // A4
    static let H: CGFloat = 842
    static let M: CGFloat = 44      // margin
    static let CW: CGFloat = 595 - 2 * 44 // content width

    // MARK: - Public entry point
    static func generate(group: SessionGroup, anomalies: [AnomalyEvent] = [], completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ecg = parseECG(group.ecgURL)
            let hr  = parseHR (group.hrURL)
            let hrv = parseHRV(group.hrvURL)
            let url = buildPDF(group: group, ecg: ecg, hr: hr, hrv: hrv, anomalies: anomalies)
            DispatchQueue.main.async { completion(url) }
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

    private static func parseHR(_ url: URL?) -> [HRSample] {
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

    private static func parseHRV(_ url: URL?) -> [HRVSample] {
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
        ecg: [ECGSample], hr: [HRSample], hrv: [HRVSample], anomalies: [AnomalyEvent]
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
        for anomaly in anomalies {
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

            // Stats grid
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

            // If no events: short note page
            if combinedEvents.isEmpty {
                addNewPage()
                var ny = M
                attr("No events were recorded during this session.",
                     font: .systemFont(ofSize: 13), color: .darkGray)
                    .draw(at: CGPoint(x: M, y: ny)); ny += 20
                attr("The MARK EVENT button was not pressed.",
                     font: .systemFont(ofSize: 11), color: .gray)
                    .draw(at: CGPoint(x: M, y: ny))
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
    case premature = "Premature Beat (<0.4s)"
}

struct AnomalyEvent: Identifiable {
    let id = UUID()
    let type: AnomalyType
    let timestamp: UInt64
    let rrInterval: Double
}

class ECGAnalyzer {
    
    /// Analyzes an array of ECG samples to detect structural RR interval anomalies.
    /// Uses a dynamic thresholding approach to identify R-peaks in O(N) time.
    static func analyze(ecgData: [ECGSample]) -> [AnomalyEvent] {
        guard ecgData.count > 130 else { return [] }
        
        // 1. Chronological Sorting explicitly by timestamp
        let sortedEcgData = ecgData.sorted { $0.timestamp < $1.timestamp }
        
        var anomalies: [AnomalyEvent] = []
        var rPeaks: [ECGSample] = []
        
        // 2. Dynamic Refractory Lockout
        var threshold: Int32 = 400
        var lastPeakTimestamp: UInt64 = 0
        var rollingRRs: [Double] = []
        
        var i = 0
        while i < sortedEcgData.count {
            if sortedEcgData[i].microVolts > threshold {
                // Candidate found. Search the next ~115ms (15 samples) for the true local maximum
                let endIdx = min(i + 15, sortedEcgData.count)
                var peakIdx = i
                var peakVal = sortedEcgData[i].microVolts
                
                for j in i..<endIdx {
                    if sortedEcgData[j].microVolts > peakVal {
                        peakVal = sortedEcgData[j].microVolts
                        peakIdx = j
                    }
                }
                
                let detectedPeak = sortedEcgData[peakIdx]
                rPeaks.append(detectedPeak)
                
                // Update rolling RRs (last 4 beats)
                if lastPeakTimestamp > 0 && detectedPeak.timestamp > lastPeakTimestamp {
                    let rr = Double(detectedPeak.timestamp - lastPeakTimestamp)
                    rollingRRs.append(rr)
                    if rollingRRs.count > 4 { rollingRRs.removeFirst() }
                }
                lastPeakTimestamp = detectedPeak.timestamp
                
                // Calculate Dynamic Lockout (40% of avg RR, clamped 200-350ms)
                let lockoutMs: Double
                if rollingRRs.isEmpty {
                    lockoutMs = 300.0
                } else {
                    let avgRR = rollingRRs.reduce(0, +) / Double(rollingRRs.count)
                    lockoutMs = min(350.0, max(200.0, avgRR * 0.40))
                }
                
                // Convert to samples (130 Hz = 0.13 samples/ms)
                let lockoutSamples = Int(lockoutMs * 0.13)
                
                // Adaptive threshold: set to 60% of current peak, min 250 µV to avoid noise
                threshold = max(250, Int32(Double(peakVal) * 0.6))
                
                // Skip iterator past the true peak PLUS the dynamic refractory period
                i = peakIdx + lockoutSamples
            } else {
                // If no peak found for > 2 seconds, slowly decay threshold to avoid getting stuck
                let timeSinceLastPeak = lastPeakTimestamp > 0 && sortedEcgData[i].timestamp > lastPeakTimestamp 
                    ? sortedEcgData[i].timestamp - lastPeakTimestamp 
                    : 0
                
                if timeSinceLastPeak > 2000 {
                    threshold = max(200, Int32(Double(threshold) * 0.95))
                }
                i += 1
            }
        }
        
        // Evaluate RR intervals using a rolling baseline to handle high heart rates
        var recentRRs: [Double] = []
        for k in 1..<rPeaks.count {
            let rr = Double(rPeaks[k].timestamp - rPeaks[k-1].timestamp)
            
            let baselineRR = recentRRs.isEmpty ? 800.0 : recentRRs.sorted()[recentRRs.count / 2]
            
            // Dropout: Gap > 1.5s AND significantly longer than baseline
            if rr > max(1500.0, baselineRR * 1.75) {
                anomalies.append(AnomalyEvent(type: .dropout, timestamp: rPeaks[k].timestamp, rrInterval: rr))
            } 
            // Premature Beat: >25% shorter than baseline, but don't flag normal fast HR
            else if rr < baselineRR * 0.75 && rr > 250.0 {
                anomalies.append(AnomalyEvent(type: .premature, timestamp: rPeaks[k].timestamp, rrInterval: rr))
            }
            
            // Track baseline (only normal-ish beats)
            if rr > 300 && rr < 1500 {
                recentRRs.append(rr)
                if recentRRs.count > 10 { recentRRs.removeFirst() }
            }
        }
        
        return anomalies
    }
}
