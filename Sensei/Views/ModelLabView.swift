import SwiftUI

struct ModelLabView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        intro
                        drivePanel
                        modelCards
                        loadPanel
                        benchmarkPanel
                    }
                    .padding(16)
                }
            }
            .navigationTitle("MODEL LAB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
            }
            .task {
                chat.refreshDownloadState()
            }

        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SENSEI BRAIN")
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(.red)

            Text("Choose the strongest model this iPhone can run reliably. Downloads are saved inside SENSEI, are resumable, and remain available after normal app restarts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var drivePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("GOOGLE DRIVE BACKUP", systemImage: "externaldrive.badge.icloud")
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(.red)

            Text("SENSEI keeps the working model on this iPhone. After Google sign-in, completed model downloads can be backed up automatically to Drive so a future IPA reinstall can restore them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Google Drive connection is being enabled in this build.")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var modelCards: some View {
        VStack(spacing: 10) {
            ForEach(LocalModelOption.allCases) { model in
                Button {
                    chat.selectModel(model)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: chat.selectedModel == model ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(chat.selectedModel == model ? .red : .secondary)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(model.name)
                                    .font(.headline)
                                    .foregroundStyle(.white)

                                Text(model.tier)
                                    .font(.caption2.monospaced().weight(.black))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.red.opacity(0.12), in: Capsule())

                                Spacer()

                                Text(model.approximateDownload)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            Text(model.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(14)
                    .background(
                        chat.selectedModel == model
                        ? Color.red.opacity(0.10)
                        : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                chat.selectedModel == model
                                ? Color.red.opacity(0.5)
                                : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var loadPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.statusText)
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(
                            ["LOCAL", "READY"].contains(chat.statusText)
                            ? .red
                            : .secondary
                        )

                    Text(chat.modelStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if chat.isDownloadingModel {
                ProgressView(value: chat.modelProgress)
                    .tint(.red)

                HStack {
                    Text("\(Int(chat.modelProgress * 100))%")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("BACKGROUND ACTIVE")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(.red)
                }
            }

            Button {
                chat.loadSelectedModel()
            } label: {
                HStack {
                    Image(systemName: buttonIcon)
                    Text(buttonTitle)
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(chat.isDownloadingModel || chat.isLoadingModel || chat.isThinking)
            .opacity(chat.isDownloadingModel || chat.isLoadingModel ? 0.55 : 1)

            Text("Completed model files are stored inside SENSEI and remain available after closing or restarting the app. Do not force-quit while an active download is being handed off to iOS.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var buttonTitle: String {
        if chat.isDownloadingModel {
            return "DOWNLOADING IN BACKGROUND"
        }

        if chat.isLoadingModel {
            return "LOADING MODEL"
        }

        if chat.loadedModel == chat.selectedModel {
            return "RELOAD LOCAL MODEL"
        }

        if chat.modelDownloadReady {
            return "LOAD LOCAL MODEL"
        }

        return "DOWNLOAD MODEL"
    }

    private var buttonIcon: String {
        if chat.modelDownloadReady || chat.loadedModel == chat.selectedModel {
            return "cpu"
        }

        return "arrow.down.circle.fill"
    }

    private var benchmarkPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ON-DEVICE TEST")
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(.red)

            Text("Runs a fixed reasoning sanity test and times the local response. It does not pretend one tiny test can rank overall intelligence.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                chat.runBenchmark()
            } label: {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                    Text("RUN TEST")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(.white)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
            }
            .disabled(
                chat.loadedModel != chat.selectedModel
                || chat.isLoadingModel
                || chat.isDownloadingModel
                || chat.isThinking
            )

            if let result = chat.benchmarkResult {
                Divider().overlay(.white.opacity(0.1))

                HStack {
                    Text(result.reasoningPassed ? "REASONING: PASS" : "REASONING: REVIEW")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(result.reasoningPassed ? .red : .secondary)

                    Spacer()

                    Text(String(format: "%.2fs", result.responseSeconds))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                if result.loadSeconds > 0 {
                    Text("Initial load: \(String(format: "%.2fs", result.loadSeconds))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                Text(result.response)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let error = chat.benchmarkError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }
}
