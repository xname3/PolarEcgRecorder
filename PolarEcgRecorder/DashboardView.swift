import SwiftUI

struct DashboardView: View {
    @StateObject private var polarManager = PolarManager.shared
    @StateObject private var eventState = EventState()
    
    // 🚨 5 sekúnd dát pri 130 Hz = 650 bodov (Graf sa 2x roztiahne po osi X)
    let maxChartPoints = 650
    @State private var ecgBuffer: [Int32?] = Array(repeating: nil, count: 650)
    @State private var writeIndex = 0
    
    @State private var incomingPoints: [Int32] = []
    @State private var displayTimer: Timer? = nil
    
    @State private var sessionDuration: TimeInterval = 0
    @State private var sessionTimer: Timer? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // MARK: - Device Info Header
                HStack {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                        .font(.largeTitle)
                    
                    VStack(alignment: .leading) {
                        Text(polarManager.isConnected ? "H10: \(polarManager.deviceId)" : "Not Connected")
                            .font(.headline)
                        if polarManager.isConnected {
                            Text("Battery: \(polarManager.batteryLevel == 0 ? "Loading..." : "\(polarManager.batteryLevel)%")")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                    }
                    Spacer()
                    
                    Text("\(polarManager.currentHR) BPM")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(polarManager.isConnected ? .primary : .gray)
                }
                .padding()
                .background(RoundedRectangle(cornerRadius: 15).fill(Color(.systemGray6)))
                .padding(.horizontal)
                
                // MARK: - ECG Canvas Chart (Apple Watch Sweep - 5s)
                Canvas { context, size in
                    var path = Path()
                    var isFirstPoint = true
                    
                    for i in 0..<maxChartPoints {
                        guard let voltage = ecgBuffer[i] else {
                            isFirstPoint = true
                            continue
                        }
                        
                        let x = CGFloat(i) / CGFloat(maxChartPoints) * size.width
                        
                        // Limitácia hodnôt na osi Y, aby kmity nepretiekli mimo grafu
                        let clampedVoltage = max(-300, min(900, Double(voltage)))
                        let normalizedY = (clampedVoltage - (-300)) / (900 - (-300))
                        let y = size.height - (CGFloat(normalizedY) * size.height)
                        
                        if isFirstPoint {
                            path.move(to: CGPoint(x: x, y: y))
                            isFirstPoint = false
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    
                    context.stroke(
                        path,
                        with: .color(.red),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                    )
                }
                .frame(height: 220)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        Color(.systemGray6)
                        // Statická lekárska mriežka
                        GeometryReader { geo in
                            Path { path in
                                let linesCount = Int(geo.size.width / 20)
                                for i in 0..<linesCount {
                                    let x = CGFloat(i) * 20
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                                }
                                let horizontalLines = Int(geo.size.height / 30)
                                for i in 0..<horizontalLines {
                                    let y = CGFloat(i) * 30
                                    path.move(to: CGPoint(x: 0, y: y))
                                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                                }
                            }
                            .stroke(Color.red.opacity(0.06), lineWidth: 0.5)
                        }
                    }
                )
                .cornerRadius(15)
                .padding(.horizontal)
                
                // MARK: - Controls
                HStack(spacing: 30) {
                    if polarManager.isConnected {
                        Button(action: {
                            polarManager.isStreaming ? stopSession() : startSession()
                        }) {
                            Text(polarManager.isStreaming ? "STOP RECORDING" : "START RECORDING")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(polarManager.isStreaming ? Color.red : Color.green)
                                .cornerRadius(10)
                        }
                        .disabled(polarManager.isEventRecording)
                        
                        Button(action: {
                            polarManager.disconnect()
                        }) {
                            Text("Disconnect")
                                .foregroundColor(.red)
                                .padding()
                                .background(Color(.systemGray6))
                                .cornerRadius(10)
                        }
                    } else {
                        Button(action: {
                            polarManager.autoConnect()
                        }) {
                            Text("CONNECT POLAR H10")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(Color.blue)
                                .cornerRadius(10)
                        }
                    }
                }
                .padding(.horizontal)
                
                // Status Bar
                if polarManager.isStreaming {
                    Text("Manual Recording: \(formattedDuration)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.green)
                } else if polarManager.isEventRecording {
                    Text("⚠️ SAVING EVENT WINDOW (-1m / +1m)...")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.orange)
                        .bold()
                } else {
                    Text("Live Preview (5 Seconds)")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // MARK: - BIG MARK EVENT BUTTON
                Button(action: {
                    eventState.triggerEvent()
                    let generator = UIImpactFeedbackGenerator(style: .heavy)
                    generator.impactOccurred()
                    
                    if !polarManager.isStreaming {
                        polarManager.startEventRecordingWindow()
                    }
                }) {
                    VStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 40))
                        Text("MARK EVENT")
                            .font(.title2.bold())
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(Color.orange)
                    .cornerRadius(20)
                }
                .padding(.horizontal)
                .disabled(!polarManager.isConnected)
                .opacity(polarManager.isConnected ? 1.0 : 0.5)
            }
            .navigationTitle("Polar ECG")
            // 🚨 PRIDANÉ: Tlačidlo v navigačnej lište na prechod do histórie súborov
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(destination: HistoryView()) {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                    }
                }
            }
            .onAppear {
                StorageManager.shared.eventState = eventState
                startDisplayTimer()
            }
            .onDisappear {
                stopDisplayTimer()
            }
            .onReceive(polarManager.ecgDataPublisher) { voltage in
                incomingPoints.append(voltage)
            }
        }
    }
    
    // MARK: - Plynulé vykresľovanie (30 Hz)
    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { _ in
            guard !incomingPoints.isEmpty else { return }
            
            let pointsToProcess = min(incomingPoints.count, 6)
            
            for _ in 0..<pointsToProcess {
                let voltage = incomingPoints.removeFirst()
                
                ecgBuffer[writeIndex] = voltage
                
                for gap in 1...22 {
                    let gapIndex = (writeIndex + gap) % maxChartPoints
                    ecgBuffer[gapIndex] = nil
                }
                
                writeIndex = (writeIndex + 1) % maxChartPoints
            }
        }
    }
    
    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }
    
    // MARK: - Helpers
    private func startSession() {
        polarManager.startStreaming()
        StorageManager.shared.startNewSession() // 🚨 PRIDANÉ: Spustenie zápisu súborov na disk
        sessionDuration = 0
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            sessionDuration += 1
        }
    }
    
    private func stopSession() {
        polarManager.stopStreaming()
        StorageManager.shared.stopSession() // 🚨 PRIDANÉ: Bezpečné uzatvorenie súborov na disku
        sessionTimer?.invalidate()
        sessionTimer = nil
    }
    
    private var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: sessionDuration) ?? "00:00:00"
    }
}
