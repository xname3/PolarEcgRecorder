import SwiftUI

struct LiveECGGraphView: View {
    @ObservedObject var polarManager = PolarManager.shared
    @AppStorage("livePreviewEnabled") private var livePreviewEnabled: Bool = true

    let maxChartPoints = 650
    @State private var ecgBuffer: [Int32?] = Array(repeating: nil, count: 650)
    @State private var writeIndex = 0
    @State private var incomingPoints: [Int32] = []
    @State private var displayTimer: Timer? = nil

    var body: some View {
        Group {
            if livePreviewEnabled || polarManager.isStreaming || polarManager.isEventRecording {
                Canvas { context, size in
                    var path = Path()
                    var first = true
                    for i in 0..<maxChartPoints {
                        guard let v = ecgBuffer[i] else { first = true; continue }
                        let x  = CGFloat(i) / CGFloat(maxChartPoints) * size.width
                        let minV = -800.0
                        let maxV = 1400.0
                        let cv = max(minV, min(maxV, Double(v)))
                        let y  = size.height - CGFloat((cv - minV) / (maxV - minV)) * size.height
                        if first { path.move(to: .init(x: x, y: y)); first = false }
                        else      { path.addLine(to: .init(x: x, y: y)) }
                    }
                    context.stroke(path, with: .color(.red),
                                   style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
                .frame(height: 200)
                .background(
                    ZStack {
                        Color(.systemGray6)
                        GeometryReader { geo in
                            Path { p in
                                stride(from: 0, to: geo.size.width,  by: 20).forEach { x in
                                    p.move(to: .init(x: x, y: 0)); p.addLine(to: .init(x: x, y: geo.size.height))
                                }
                                stride(from: 0, to: geo.size.height, by: 30).forEach { y in
                                    p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: geo.size.width, y: y))
                                }
                            }
                            .stroke(Color.red.opacity(0.07), lineWidth: 0.5)
                        }
                    }
                )
                .cornerRadius(15)
            } else {
                // Placeholder when Live Preview is off and not recording
                VStack {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text("Live Preview is OFF")
                        .font(.headline)
                        .foregroundColor(.gray)
                        .padding(.top, 8)
                    Text("ECG streams invisibly to save battery.")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .background(RoundedRectangle(cornerRadius: 15).fill(Color(.systemGray6)))
            }
        }
        .onAppear {
            incomingPoints.removeAll() // Clear buffer to prevent catch-up effect
            startDisplayTimer()
        }
        .onDisappear {
            stopDisplayTimer()
        }
        .onReceive(polarManager.ecgDataPublisher) { pts in
            if displayTimer != nil { incomingPoints.append(contentsOf: pts) }
        }
    }

    // MARK: - Display timer (30 Hz sweep)
    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { _ in
            guard !incomingPoints.isEmpty else { return }
            
            // Self-regulating buffer: naturally stabilizes around ~40 points to prevent stuttering
            // between BLE packets, while adapting to higher latency if needed.
            let targetConsume = max(4, Int(ceil(Double(incomingPoints.count) / 10.0)))
            let toConsume = min(incomingPoints.count, targetConsume)
            
            for _ in 0..<toConsume {
                let v = incomingPoints.removeFirst()
                ecgBuffer[writeIndex] = v
                for gap in 1...44 { ecgBuffer[(writeIndex + gap) % maxChartPoints] = nil }
                writeIndex = (writeIndex + 1) % maxChartPoints
            }
        }
    }
    private func stopDisplayTimer() { displayTimer?.invalidate(); displayTimer = nil }
}
