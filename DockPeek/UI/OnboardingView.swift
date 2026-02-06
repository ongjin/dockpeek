import SwiftUI

struct OnboardingView: View {
    let onDismiss: () -> Void
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("DockPeek needs Accessibility access")
                .font(.headline)

            Text("To detect clicks on Dock icons, DockPeek needs Accessibility permission.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                stepRow(1, "Open System Settings")
                stepRow(2, "Go to Privacy & Security → Accessibility")
                stepRow(3, "Enable DockPeek in the list")
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.1)))

            HStack(spacing: 12) {
                Button("Open Settings") {
                    AccessibilityManager.shared.openAccessibilitySettings()
                }
                .buttonStyle(.borderedProminent)

                Button("I've enabled it") {
                    isChecking = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        isChecking = false
                        if AccessibilityManager.shared.isAccessibilityGranted { onDismiss() }
                    }
                }
                .disabled(isChecking)
            }

            if isChecking { ProgressView().scaleEffect(0.8) }
        }
        .padding(32)
        .frame(width: 400)
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n).").font(.body.bold()).frame(width: 24)
            Text(text).font(.body)
        }
    }
}
