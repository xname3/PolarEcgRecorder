import SwiftUI

struct SettingsView: View {
    @AppStorage("reportIdentification") private var reportIdentification: String = ""
    @AppStorage("livePreviewEnabled") private var livePreviewEnabled: Bool = true
    @AppStorage("preventSleep") private var preventSleep: Bool = false
    
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
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
