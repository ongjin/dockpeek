import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var newExcludedID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            Toggle("Enable DockPeek", isOn: $appState.isEnabled)
            thumbnailSlider
            Toggle("Show window titles", isOn: $appState.showWindowTitles)
            Toggle("Live preview on hover", isOn: $appState.livePreviewOnHover)
            Toggle("Launch at login", isOn: $appState.launchAtLogin)
                .onChange(of: appState.launchAtLogin) { _, newValue in
                    if newValue {
                        try? SMAppService.mainApp.register()
                    } else {
                        try? SMAppService.mainApp.unregister()
                    }
                }
            Toggle("Force new windows to primary display", isOn: $appState.forceNewWindowsToPrimary)
            Divider()
            exclusionList
            Divider()
            permissionStatus
            quitButton
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "dock.rectangle")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("DockPeek").font(.headline)
            Spacer()
        }
    }

    private var thumbnailSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Thumbnail size: \(Int(appState.thumbnailSize))px")
                .font(.caption).foregroundColor(.secondary)
            Slider(value: $appState.thumbnailSize, in: 120...360, step: 20)
        }
    }

    private var exclusionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Excluded Apps").font(.caption).foregroundColor(.secondary)

            ForEach(Array(appState.excludedBundleIDs.sorted()), id: \.self) { bid in
                HStack {
                    Text(bid).font(.caption).lineLimit(1)
                    Spacer()
                    Button {
                        var ids = appState.excludedBundleIDs
                        ids.remove(bid)
                        appState.excludedBundleIDs = ids
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                TextField("com.example.app", text: $newExcludedID)
                    .textFieldStyle(.roundedBorder).font(.caption)
                Button("Add") {
                    let t = newExcludedID.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    var ids = appState.excludedBundleIDs
                    ids.insert(t)
                    appState.excludedBundleIDs = ids
                    newExcludedID = ""
                }
                .disabled(newExcludedID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var permissionStatus: some View {
        HStack {
            Circle()
                .fill(AccessibilityManager.shared.isAccessibilityGranted ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(AccessibilityManager.shared.isAccessibilityGranted
                 ? "Accessibility: Granted" : "Accessibility: Required")
                .font(.caption).foregroundColor(.secondary)
            if !AccessibilityManager.shared.isAccessibilityGranted {
                Button("Grant") { AccessibilityManager.shared.openAccessibilitySettings() }
                    .font(.caption)
            }
        }
    }

    private var quitButton: some View {
        HStack {
            Spacer()
            Button("Quit DockPeek") { NSApplication.shared.terminate(nil) }
                .font(.caption)
        }
    }
}
