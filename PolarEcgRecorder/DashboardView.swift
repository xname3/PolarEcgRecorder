import SwiftUI

struct DashboardView: View {
    @StateObject private var polarManager = PolarManager.shared
    @StateObject private var eventState   = EventState()
    @AppStorage("livePreviewEnabled") private var livePreviewEnabled: Bool = true

    @State private var sessionDuration: TimeInterval = 0
    @State private var sessionTimer: Timer? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {

                // ── Device header ────────────────────────────────────────────
                HStack {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                        .font(.largeTitle)
                    VStack(alignment: .leading) {
                        Text(polarManager.isConnected
                             ? "H10: \(polarManager.deviceId)" : "Not Connected")
                            .font(.headline)
                        if polarManager.isConnected {
                            Text("Battery: \(polarManager.batteryLevel == 0 ? "Loading…" : "\(polarManager.batteryLevel)%")")
                                .font(.subheadline).foregroundColor(.gray)
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

                // ── HRV Stats row (visible only when data is present) ──────────────
                if polarManager.isConnected {
                    HStack(spacing: 0) {
                        HRVStatCell(
                            icon: "waveform.path.ecg",
                            iconColor: rmssdColor,
                            title: "RMSSD",
                            value: polarManager.currentRMSSD > 0
                                   ? "\(Int(polarManager.currentRMSSD))" : "—",
                            unit: "ms"
                        )
                        Divider().frame(height: 44)
                        HRVStatCell(
                            icon: "timer",
                            iconColor: .blue,
                            title: "RR Interval",
                            value: polarManager.lastRRInterval > 0
                                   ? "\(polarManager.lastRRInterval)" : "—",
                            unit: "ms"
                        )
                        Divider().frame(height: 44)
                        HRVStatCell(
                            icon: "chart.bar.fill",
                            iconColor: rmssdColor,
                            title: "HRV Status",
                            value: rmssdLabel,
                            unit: ""
                        )
                    }
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 15).fill(Color(.systemGray6)))
                    .padding(.horizontal)
                }

                // ── ECG Canvas ────────────────────────────────────────────────
                LiveECGGraphView()
                    .padding(.horizontal)

                // ── Controls ──────────────────────────────────────────────────
                HStack(spacing: 12) {
                    if polarManager.isConnected {
                        Button { polarManager.isStreaming ? stopSession() : startSession() } label: {
                            Text(polarManager.isStreaming ? "STOP" : "START RECORDING")
                                .font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding()
                                .background(polarManager.isStreaming ? Color.red : Color.green)
                                .cornerRadius(10)
                        }
                        .disabled(polarManager.isEventRecording)

                        Button { polarManager.disconnect() } label: {
                            Text("Disconnect").foregroundColor(.red).padding()
                                .background(Color(.systemGray6)).cornerRadius(10)
                        }
                    } else {
                        Button { polarManager.autoConnect() } label: {
                            Text("CONNECT POLAR H10")
                                .font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.blue).cornerRadius(10)
                        }
                    }
                }
                .padding(.horizontal)

                // Status
                Group {
                    if polarManager.isStreaming {
                        Text("Recording: \(formattedDuration)")
                            .font(.system(.body, design: .monospaced)).foregroundColor(.green)
                    } else if polarManager.isEventRecording {
                        Text("⚠️ SAVING EVENT (−30 s / +15 s)…")
                            .font(.system(.body, design: .monospaced)).foregroundColor(.orange).bold()
                    } else {
                        Text("Live Preview (5 s)").font(.subheadline).foregroundColor(.gray)
                    }
                }

                Spacer()

                // ── MARK EPISODE ───────────────────────────────────────────────
                Button {
                    eventState.triggerEvent()
                    StorageManager.shared.markEvent()
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    if !polarManager.isStreaming { polarManager.startEventRecordingWindow() }
                } label: {
                    VStack {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40))
                        Text("MARK EPISODE").font(.title2.bold())
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 36)
                    .background(Color.orange).cornerRadius(20)
                }
                .padding(.horizontal)
                .disabled(!polarManager.isConnected)
                .opacity(polarManager.isConnected ? 1 : 0.5)
            }
            .navigationTitle("Polar ECG")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        NavigationLink(destination: SettingsView()) {
                            Image(systemName: "gear").font(.title3).foregroundColor(.blue)
                        }
                        NavigationLink(destination: HistoryView()) {
                            Image(systemName: "folder.fill").font(.title3).foregroundColor(.blue)
                        }
                    }
                }
            }
            .onAppear {
                StorageManager.shared.eventState = eventState
            }
        }
    }

    // MARK: - HRV helpers
    private var rmssdColor: Color {
        let v = polarManager.currentRMSSD
        guard v > 0 else { return .gray }
        if v < 20 { return .red }
        if v < 50 { return .orange }
        return .green
    }
    private var rmssdLabel: String {
        let v = polarManager.currentRMSSD
        guard v > 0 else { return "—" }
        if v < 20 { return "Low" }
        if v < 50 { return "Normal" }
        return "High"
    }



    // MARK: - Session
    private func startSession() {
        polarManager.startStreaming()
        StorageManager.shared.startNewSession()   // single authoritative call
        sessionDuration = 0
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in sessionDuration += 1 }
    }
    private func stopSession() {
        polarManager.stopStreaming()
        StorageManager.shared.stopSession()
        sessionTimer?.invalidate(); sessionTimer = nil
    }
    private var formattedDuration: String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .positional; f.zeroFormattingBehavior = .pad
        return f.string(from: sessionDuration) ?? "00:00:00"
    }
}

// MARK: - HRV stat cell
struct HRVStatCell: View {
    let icon: String; let iconColor: Color
    let title: String; let value: String; let unit: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundColor(iconColor)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.title3.bold())
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundColor(.secondary) }
            }
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
