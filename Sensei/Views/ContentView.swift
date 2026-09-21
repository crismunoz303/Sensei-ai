import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @FocusState private var inputFocused: Bool
    @State private var showModelLab = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    Divider().overlay(Color.red.opacity(0.35))
                    conversation
                    composer
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showModelLab) {
                ModelLabView()
                    .environmentObject(chat)
                    .preferredColorScheme(.dark)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SENSEI")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Button {
                    showModelLab = true
                } label: {
                    HStack(spacing: 5) {
                        Text("MODEL LAB")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption2.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(.red)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(chat.statusText == "LOCAL" ? Color.red : Color.gray)
                        .frame(width: 7, height: 7)

                    Text(chat.statusText)
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(chat.statusText == "LOCAL" ? .red : .secondary)
                }

                Text(chat.loadedModel?.name ?? chat.selectedModel.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                showModelLab = true
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(chat.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if chat.isThinking {
                        HStack {
                            ProgressView()
                                .tint(.red)
                            Text(chat.thinkingStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                chat.stopThinking()
                            } label: {
                                Label("STOP", systemImage: "stop.fill")
                                    .font(.caption2.monospaced().weight(.bold))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(.red.opacity(0.12), in: Capsule())
                            }
                        }
                        .padding(.horizontal, 18)
                    }
                }
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.count) {
                guard let last = chat.messages.last else { return }
                withAnimation {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        chat.activateFastMode()
                    } label: {
                        Text("FAST")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(!chat.collaborationMode && !chat.individualMode ? Color.white : Color.secondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(!chat.collaborationMode && !chat.individualMode ? Color.red.opacity(0.8) : Color.white.opacity(0.06), in: Capsule())
                    }

                    Button {
                        chat.activateTeamMode()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "person.2.fill")
                            Text("TEAM")
                        }
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(chat.collaborationMode ? Color.white : (chat.collaborationAvailable ? Color.red : Color.secondary))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(chat.collaborationMode ? Color.red.opacity(0.8) : Color.white.opacity(0.06), in: Capsule())
                    }
                    .disabled(!chat.collaborationAvailable)

                    Menu {
                        ForEach(chat.downloadedModels) { model in
                            Button {
                                chat.activateIndividualMode(model)
                            } label: {
                                if chat.individualMode && chat.selectedModel == model {
                                    Label(model.name, systemImage: "checkmark")
                                } else {
                                    Text(model.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "person.fill")
                            Text("SOLO")
                        }
                        .font(.caption2.monospaced().weight(.bold))
                        .foregroundStyle(chat.individualMode ? Color.white : (chat.downloadedModels.isEmpty ? Color.secondary : Color.red))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(chat.individualMode ? Color.red.opacity(0.8) : Color.white.opacity(0.06), in: Capsule())
                    }
                    .disabled(chat.downloadedModels.isEmpty || chat.isThinking || chat.isLoadingModel)

                    Spacer()
                }

                if chat.individualMode {
                    Text("SOLO • \\(chat.selectedModel.name)")
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if chat.collaborationMode {
                    Text("\\(chat.downloadedModels.count) LOCAL AIs • sequential collaboration")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                } else if !chat.collaborationAvailable {
                    Text("TEAM unlocks with 2+ downloaded models")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                TextField("Ask SENSEI…", text: $chat.draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        chat.send()
                    }

                Button {
                    chat.send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.white)
                        .background(Color.red, in: Circle())
                }
                .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isThinking)
                .opacity(chat.isThinking ? 0.5 : 1)
            }
            .padding(10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))

            HStack {
                Text("LOCAL MLX • NO PAID API")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Clear") {
                    chat.clearConversation()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.black)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 52)
            }

            Text(message.text)
                .font(.body)
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    message.role == .user
                    ? Color.red.opacity(0.82)
                    : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 17)
                )

            if message.role == .assistant {
                Spacer(minLength: 52)
            }
        }
        .padding(.horizontal, 14)
    }
}
