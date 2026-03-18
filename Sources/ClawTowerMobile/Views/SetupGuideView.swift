import SwiftUI

struct SetupGuideView: View {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let features: [FeatureItem]
    var onRetry: (() async -> Void)?

    @Environment(\.themeColor) private var themeColor
    @State private var isRetrying = false
    @State private var retryTimerTask: Task<Void, Never>?

    struct FeatureItem: Identifiable {
        let id = UUID()
        let icon: String
        let text: LocalizedStringKey
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                featureSection
                setupStepsSection
                connectionStatus
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
        }
    }

    // MARK: - Feature Section

    private var featureSection: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(themeColor)
                .padding(.bottom, 4)

            Text(title)
                .font(.title2.bold())

            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            VStack(spacing: 12) {
                ForEach(features) { feature in
                    HStack(spacing: 12) {
                        Image(systemName: feature.icon)
                            .font(.system(size: 16))
                            .foregroundStyle(themeColor)
                            .frame(width: 24)
                        Text(feature.text)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Setup Steps

    private var setupStepsSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(themeColor)
                Text("guide.setup.title")
                    .font(.headline)
            }
            .padding(.bottom, 4)

            stepRow(number: 1, icon: "desktopcomputer.and.arrow.down", text: "guide.setup.step1")
            stepRow(number: 2, icon: "person.icloud", text: "guide.setup.step2")
            stepRow(number: 3, icon: "checkmark.circle", text: "guide.setup.step3")
        }
    }

    private func stepRow(number: Int, icon: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(themeColor, in: Circle())

            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Connection Status

    private var connectionStatus: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.caption)
                Text("guide.status.waiting")
                    .font(.caption)
            }
            .foregroundStyle(.tertiary)

            if onRetry != nil {
                Button {
                    startRetry()
                } label: {
                    HStack(spacing: 6) {
                        if isRetrying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline.weight(.medium))
                        }
                        Text("guide.status.retry")
                            .font(.subheadline.weight(.medium))
                    }
                    .foregroundStyle(isRetrying ? .secondary : themeColor)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        (isRetrying ? Color.secondary.opacity(0.1) : themeColor.opacity(0.1)),
                        in: Capsule()
                    )
                }
                .disabled(isRetrying)
                .animation(.easeInOut(duration: 0.2), value: isRetrying)
            }
        }
        .padding(.top, 8)
    }

    private func startRetry() {
        guard !isRetrying else { return }
        isRetrying = true
        retryTimerTask?.cancel()
        retryTimerTask = Task {
            await onRetry?()
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled {
                isRetrying = false
            }
        }
    }
}

// MARK: - Reusable Retry Button (used in list disconnect banners)

struct RetryButton: View {
    let action: () async -> Void

    @State private var isRetrying = false
    @State private var timerTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard !isRetrying else { return }
            isRetrying = true
            timerTask?.cancel()
            timerTask = Task {
                await action()
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled {
                    isRetrying = false
                }
            }
        } label: {
            if isRetrying {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("guide.status.retry")
                    .font(.subheadline.weight(.medium))
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .disabled(isRetrying)
        .animation(.easeInOut(duration: 0.2), value: isRetrying)
    }
}
