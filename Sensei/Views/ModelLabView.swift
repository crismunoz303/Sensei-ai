import SwiftUI

struct ModelLabView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var drive = GoogleDriveBackupManager.shared
    @State private var showDiagnostics = false
    @State private var showMemory = false
    @State private var storageRefreshID = UUID()
    @State private var reclaimableBytes: Int64 = 0
    @State private var storageMessage: String?
    @State private var isCleaningStorage = false
    @State private var section: LabSection = .models

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        intro
                        sectionPicker
                        sectionContent
                    }
                    .padding(16)
                }
            }
            .navigationTitle("MODEL LAB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.red)

                    Button {
                        showMemory = true
                    } label: {
                        Image(systemName: "brain")
                    }
                    .foregroundStyle(.red)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.red)
                }
            }
            .task {
                chat.refreshDownloadState()
                reclaimableBytes = await BackgroundModelDownloadManager.shared.removablePartialBytes()
            }
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
                    .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showMemory) {
                MemoryView()
                    .preferredColorScheme(.dark)
            }

        }
    }

    private enum LabSection: String, CaseIterable, Identifiable {
        case models = "Models"
        case storage = "Storage"
        case backup = "Backup"
        case tools = "Tools"
        var id: String { rawValue }
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(LabSection.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        section = item
                    }
                } label: {
                    Text(item.rawValue.uppercased())
                        .font(.caption2.monospaced().weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(section == item ? .white : .secondary)
                        .background(section == item ? Color.red : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
        .padding(4)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .models:
            modelCards
            loadPanel
        case .storage:
            storagePanel
        case .backup:
            drivePanel
        case .tools:
            benchmarkPanel
            Button {
                showMemory = true
            } label: {
                Label("MEMORY MANAGER", systemImage: "brain")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            }
            Button {
                showDiagnostics = true
            } label: {
                Label("DIAGNOSTICS", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
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

            HStack {
                Text(drive.status)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(drive.isSignedIn ? .red : .secondary)
                Spacer()
                if let email = drive.accountEmail {
                    Text(email)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text(drive.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if drive.isBackingUp {
                ProgressView(value: drive.backupProgress)
                    .tint(.red)
                HStack {
                    Text("\(Int(drive.backupProgress * 100))% uploaded")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let eta = drive.backupETA {
                        Text(eta)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if drive.isSignedIn && chat.modelDownloadReady {
                Button {
                    Task {
                        do {
                            try await drive.retryBackup(chat.selectedModel)
                        } catch {
                            // Manager publishes the failure state and keeps retry available.
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise.icloud")
                        Text(drive.status == "BACKUP FAILED" ? "RETRY BACKUP" : "BACK UP DOWNLOADED MODEL")
                            .fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(drive.isBackingUp)
            }

            Button {
                Task {
                    if drive.isSignedIn {
                        drive.signOut()
                    } else {
                        try? await drive.signIn()
                    }
                }
            } label: {
                HStack {
                    Image(systemName: drive.isSignedIn ? "rectangle.portrait.and.arrow.right" : "person.crop.circle.badge.checkmark")
                    Text(drive.isSignedIn ? "SIGN OUT OF GOOGLE" : "SIGN IN WITH GOOGLE")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(.white)
                .background(drive.isSignedIn ? .white.opacity(0.09) : Color.red, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var storagePanel: some View {
        let rows = BackgroundModelDownloadManager.shared.storageBreakdown()
        let total = BackgroundModelDownloadManager.shared.modelsRootBytes()
        let orphaned = BackgroundModelDownloadManager.shared.orphanedModelStorage()
        let orphanedBytes = orphaned.reduce(Int64(0)) { $0 + $1.bytes }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("LOCAL MODEL STORAGE", systemImage: "internaldrive")
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(.red)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(.white)
            }

            Text("Exact allocated size of SENSEI model files currently stored on this iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(rows, id: \.model.rawValue) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.model.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(row.ready ? "COMPLETE" : (row.bytes > 0 ? "PARTIAL" : "NOT STORED"))
                            .font(.caption2.monospaced())
                            .foregroundStyle(row.ready ? .red : .secondary)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: row.bytes, countStyle: .file))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if orphanedBytes > 0 {
                Divider().overlay(Color.white.opacity(0.08))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UNRECOGNIZED MODEL DATA")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(.orange)
                        Text("Retired or unknown folders are shown for review only. Nothing here is deleted automatically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: orphanedBytes, countStyle: .file))
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(.orange)
                }

                ForEach(Array(orphaned.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.name)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if reclaimableBytes > 0 {
                HStack {
                    Text("SAFE TO CLEAN")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(.red)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Button {
                    isCleaningStorage = true
                    Task {
                        do {
                            let reclaimed = try await BackgroundModelDownloadManager.shared.cleanIncompleteModelData()
                            storageMessage = "Reclaimed " + ByteCountFormatter.string(fromByteCount: reclaimed, countStyle: .file) + "."
                        } catch {
                            storageMessage = error.localizedDescription
                        }
                        reclaimableBytes = await BackgroundModelDownloadManager.shared.removablePartialBytes()
                        storageRefreshID = UUID()
                        isCleaningStorage = false
                    }
                } label: {
                    Label(isCleaningStorage ? "CLEANING…" : "CLEAN INCOMPLETE DOWNLOADS", systemImage: "trash")
                        .font(.caption.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(isCleaningStorage)
            }

            if let storageMessage {
                Text(storageMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task {
                    reclaimableBytes = await BackgroundModelDownloadManager.shared.removablePartialBytes()
                    storageRefreshID = UUID()
                }
            } label: {
                Label("REFRESH STORAGE", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .id(storageRefreshID)
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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Int(chat.modelProgress * 100))%")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        if let eta = chat.downloadETA {
                            Text(eta)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

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
            .disabled(chat.loadedModel != chat.selectedModel || chat.isLoadingModel || chat.isDownloadingModel || chat.isThinking || chat.isRunningBenchmark)
            .opacity(chat.loadedModel == chat.selectedModel && !chat.isLoadingModel && !chat.isDownloadingModel && !chat.isThinking ? 1 : 0.55)

            if chat.loadedModel != chat.selectedModel && !chat.isLoadingModel {
                Text("Load (chat.selectedModel.name) before running the test.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if chat.isRunningBenchmark {
                HStack(spacing: 8) {
                    ProgressView().tint(.red)
                    Text("RUNNING ON-DEVICE TEST…")
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }

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
