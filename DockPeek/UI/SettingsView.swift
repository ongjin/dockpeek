import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updateChecker: UpdateChecker = .shared
    @State private var langRefresh = UUID()

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(L10n.general, systemImage: "gear") }
            behaviorTab
                .tabItem { Label(L10n.behavior, systemImage: "cursorarrow.click.2") }
            appearanceTab
                .tabItem { Label(L10n.appearance, systemImage: "paintbrush") }
            updateTab
                .tabItem {
                    if updateChecker.updateAvailable {
                        Label(L10n.update, systemImage: "exclamationmark.circle")
                    } else {
                        Label(L10n.update, systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            aboutTab
                .tabItem { Label(L10n.about, systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 480, height: 560)
        .id(langRefresh)
    }

    // MARK: - General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(L10n.enableDockPeek, isOn: $appState.isEnabled)
            Toggle(L10n.launchAtLogin, isOn: $appState.launchAtLogin)
                .onChange(of: appState.launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        dpLog("Login item registration failed: \(error)")
                    }
                }

            Divider()

            // Language picker
            HStack {
                Text(L10n.language)
                Spacer()
                Picker("", selection: $appState.language) {
                    ForEach(Language.allCases, id: \.rawValue) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: appState.language) { _, _ in
                    langRefresh = UUID()
                }
            }

            Divider()

            // Permissions
            permissionStatus

            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Behavior

    private var behaviorTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(L10n.forceNewWindowsToPrimary, isOn: $appState.forceNewWindowsToPrimary)

            Divider()

            Toggle(L10n.previewOnHover, isOn: $appState.previewOnHover)

            if appState.previewOnHover {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(L10n.hoverDelay): \(String(format: "%.1f", appState.hoverDelay))s")
                        .font(.caption).foregroundColor(.secondary)
                    Slider(value: $appState.hoverDelay, in: 0.3...2.0, step: 0.1)
                }
            }

            Divider()

            // Excluded apps
            exclusionList

            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(L10n.thumbnailSize): \(Int(appState.thumbnailSize))px")
                    .font(.caption).foregroundColor(.secondary)
                Slider(value: $appState.thumbnailSize, in: 120...360, step: 20)
            }

            Toggle(L10n.showWindowTitles, isOn: $appState.showWindowTitles)
            Toggle(L10n.livePreviewOnHover, isOn: $appState.livePreviewOnHover)

            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Update

    @State private var isCheckingUpdate = false

    private var updateTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(L10n.autoUpdateToggle, isOn: $appState.autoUpdateEnabled)

            if appState.autoUpdateEnabled {
                HStack {
                    Text(L10n.updateInterval)
                    Spacer()
                    Picker("", selection: $appState.updateCheckInterval) {
                        Text(L10n.daily).tag("daily")
                        Text(L10n.weekly).tag("weekly")
                        Text(L10n.manual).tag("manual")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }
            }

            Divider()

            // Current version
            HStack {
                Text(L10n.currentVersion)
                    .foregroundColor(.secondary)
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            }

            // Last checked
            HStack {
                Text(L10n.lastChecked)
                    .foregroundColor(.secondary)
                Spacer()
                Text(lastCheckedText)
            }

            Divider()

            // Check now button
            HStack {
                Button(action: performUpdateCheck) {
                    HStack(spacing: 6) {
                        if isCheckingUpdate {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(L10n.checkNow)
                    }
                }
                .disabled(isCheckingUpdate || {
                    if case .downloading = updateChecker.upgradeState { return true }
                    return false
                }())
                Spacer()
            }

            // Update available section
            if updateChecker.updateAvailable || updateChecker.upgradeState != .idle {
                Divider()
                updateAvailableSection
            }

            Spacer()
        }
        .padding(.top, 8)
    }

    private var lastCheckedText: String {
        guard let date = updateChecker.lastCheckDate else {
            return L10n.never
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func performUpdateCheck() {
        isCheckingUpdate = true
        updateChecker.check(force: true, intervalSetting: appState.updateCheckInterval) { _ in
            isCheckingUpdate = false
        }
    }

    private var updateAvailableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if updateChecker.updateAvailable {
                Text(String(format: L10n.newVersionAvailable, updateChecker.latestVersion))
                    .font(.headline)

                if !updateChecker.releaseBody.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.releaseNotes)
                            .font(.caption).foregroundColor(.secondary)
                        ScrollView {
                            Text(.init(updateChecker.releaseBody))
                                .font(.caption)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 120)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                    }
                }
            }

            // Upgrade state UI
            switch updateChecker.upgradeState {
            case .idle:
                if updateChecker.updateAvailable {
                    HStack {
                        Button(L10n.updateNow) {
                            updateChecker.downloadAndInstall()
                        }
                        .controlSize(.large)
                        Button(L10n.download) {
                            if let url = URL(string: updateChecker.releaseURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.large)
                    }
                }
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                    Text(L10n.upgrading)
                        .font(.caption).foregroundColor(.secondary)
                }
            case .completed:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(L10n.upgradeComplete)
                    Spacer()
                    Button(L10n.restart) {
                        updateChecker.relaunchApp()
                    }
                    .controlSize(.large)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text(L10n.upgradeFailed)
                    }
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                    Button(L10n.retry) {
                        updateChecker.resetUpgradeState()
                        updateChecker.downloadAndInstall()
                    }
                }
            }
        }
    }

    // MARK: - About

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()

            // App icon + name + version
            VStack(spacing: 8) {
                Image(systemName: "dock.rectangle")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                Text("DockPeek")
                    .font(.title2.bold())
                Text("\(L10n.version) \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Buy me a coffee
            VStack(spacing: 8) {
                Text(L10n.buyMeACoffeeDesc)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Button(action: {
                    if let url = URL(string: "https://buymeacoffee.com/zerry") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack {
                        Image(systemName: "cup.and.saucer.fill")
                        Text(L10n.buyMeACoffee)
                    }
                }
                .controlSize(.large)
            }

            // GitHub link
            Button(action: {
                if let url = URL(string: "https://github.com/ongjin/dockpeek") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack {
                    Image(systemName: "link")
                    Text(L10n.gitHub)
                }
            }
            .buttonStyle(.link)

            Spacer()

            // Quit button
            Button(L10n.quit) {
                NSApplication.shared.terminate(nil)
            }
            .foregroundColor(.red)
        }
        .padding(.top, 8)
    }

    // MARK: - Shared Components

    private var permissionStatus: some View {
        HStack {
            Text(L10n.permissions)
                .font(.caption).foregroundColor(.secondary)
            Spacer()
            Circle()
                .fill(AccessibilityManager.shared.isAccessibilityGranted ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(AccessibilityManager.shared.isAccessibilityGranted
                 ? L10n.accessibilityGranted : L10n.accessibilityRequired)
                .font(.caption).foregroundColor(.secondary)
            if !AccessibilityManager.shared.isAccessibilityGranted {
                Button(L10n.grantPermission) { AccessibilityManager.shared.openAccessibilitySettings() }
                    .font(.caption)
            }
        }
    }

    @State private var newExcludedID = ""

    private var exclusionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.excludedApps).font(.caption).foregroundColor(.secondary)

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
                TextField(L10n.addPlaceholder, text: $newExcludedID)
                    .textFieldStyle(.roundedBorder).font(.caption)
                Button(L10n.add) {
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
}
