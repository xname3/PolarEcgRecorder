import SwiftUI

struct SettingsView: View {
    @AppStorage("reportIdentification") private var reportIdentification: String = ""
    @AppStorage("livePreviewEnabled") private var livePreviewEnabled: Bool = true
    @AppStorage("preventSleep") private var preventSleep: Bool = false
    @AppStorage("realTimeExtrasystoleDetection") private var rtDetectionEnabled: Bool = false
    @AppStorage("rtUseAIDetection") private var rtUseAIDetection: Bool = true
    @AppStorage("beepOnExtrasystole") private var beepOnExtrasystole: Bool = true
    
    var body: some View {
        Form {
            Section(header: Text("PDF Report Settings"), footer: Text("This text will be printed in the header of your exported comprehensive PDF report.")) {
                TextField("E.g. John Doe, +1 555-1234", text: $reportIdentification)
            }
            
            Section(header: Text("Dashboard"), footer: Text("Live Preview continuously streams and draws ECG data even when you are not recording. Disabling this saves significant battery on both the iPhone and the Polar sensor.")) {
                Toggle("Live preview when not recording", isOn: $livePreviewEnabled)
            }
            
            Section(header: Text("Display"), footer: Text("Prevents the iPhone screen from dimming and locking while the app is open.")) {
                Toggle("Prevent sleep phone", isOn: $preventSleep)
            }
            
            Section(header: Text("Real-time Detection"), footer: Text("Analyzes incoming ECG stream to detect premature beats. This runs locally on your device.")) {
                Toggle("Detect Extrasystoles (PVC/PAC)", isOn: $rtDetectionEnabled)
                if rtDetectionEnabled {
                    Picker("Detection Method", selection: $rtUseAIDetection) {
                        Text("AI Morphology Model").tag(true)
                        Text("RR Interval Deviation").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)
                    
                    Toggle("Beep on detection", isOn: $beepOnExtrasystole)
                }
            }
            
            Section(header: Text("Legal & Privacy")) {
                NavigationLink(destination: DisclaimerView()) {
                    HStack {
                        Image(systemName: "hand.raised.fill")
                            .foregroundColor(.orange)
                        Text("Disclaimer & Privacy Policy")
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DisclaimerView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    Text("Medical Disclaimer")
                        .font(.title3.bold())
                        .foregroundColor(.primary)
                    
                    Text("This application is for informational, fitness, and educational purposes only. It is designed to work with the Polar H10 heart rate sensor, which functions as a single-lead ECG monitor.")
                        .font(.body)
                        .foregroundColor(.secondary)
                    
                    Text("This app does NOT replace professional medical advice, clinical diagnosis, treatment, or hospital-grade ECG equipment. It cannot detect heart attacks (myocardial infarction), heart failure, stroke, or any acute cardiac emergencies.")
                        .font(.body)
                        .foregroundColor(.secondary)
                    
                    Text("If you feel unwell, experience chest pain, shortness of breath, pressure, or any symptoms you attribute to your heart, please seek immediate emergency medical care.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                Group {
                    Text("Data Privacy Policy")
                        .font(.title3.bold())
                        .foregroundColor(.primary)
                    
                    Text("Your privacy is absolute. All recorded ECG, Heart Rate (HR), and HRV data are processed and stored strictly locally on your device in CSV format.")
                        .font(.body)
                        .foregroundColor(.secondary)
                    
                    Text("No personal information, health telemetry, or physiological records are ever transmitted to external servers, cloud databases, or shared with third parties. You have total and exclusive control over your files.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Disclaimer & Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}
