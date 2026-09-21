import SwiftUI

struct MemoryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = SenseiMemoryStore.shared
    @State private var showClearConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Group {
                    if store.memories.isEmpty {
                        ContentUnavailableView(
                            "No Memories Yet",
                            systemImage: "brain",
                            description: Text("Teach SENSEI with “Remember that …”, “My preference is …”, or “Correction: …”.")
                        )
                    } else {
                        List {
                            Section {
                                ForEach(store.memories) { memory in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(memory.kind.rawValue.uppercased())
                                                .font(.caption2.monospaced().weight(.bold))
                                                .foregroundStyle(.red)
                                            Spacer()
                                            Toggle("", isOn: Binding(
                                                get: { memory.isEnabled },
                                                set: { store.setEnabled($0, id: memory.id) }
                                            ))
                                            .labelsHidden()
                                            .tint(.red)
                                        }
                                        Text(memory.text)
                                            .foregroundStyle(.white)
                                            .textSelection(.enabled)
                                        Text(memory.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 5)
                                    .listRowBackground(Color.white.opacity(0.05))
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            store.delete(id: memory.id)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                Text("\(store.memories.count) LOCAL MEMORIES")
                            }

                            Section {
                                Button("CLEAR ALL MEMORIES", role: .destructive) {
                                    showClearConfirmation = true
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.05))
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("MEMORY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.red)
                }
            }
            .confirmationDialog(
                "Clear every SENSEI memory?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All Memories", role: .destructive) {
                    store.clear()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes SENSEI’s learned local memories. It does not delete model files or chat history.")
            }
        }
    }
}
