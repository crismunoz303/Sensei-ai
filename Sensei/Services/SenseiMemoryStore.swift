import Foundation

struct SenseiMemory: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case fact
        case preference
        case correction
        case instruction
    }

    let id: UUID
    var kind: Kind
    var text: String
    let createdAt: Date
    var updatedAt: Date
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isEnabled = isEnabled
    }
}

@MainActor
final class SenseiMemoryStore: ObservableObject {
    static let shared = SenseiMemoryStore()

    @Published private(set) var memories: [SenseiMemory] = []

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let maxMemories = 500

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        memories = read()
    }

    @discardableResult
    func remember(_ text: String, kind: SenseiMemory.Kind) -> SenseiMemory? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if let index = memories.firstIndex(where: {
            $0.kind == kind && $0.text.compare(cleaned, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            memories[index].updatedAt = Date()
            memories[index].isEnabled = true
            persist()
            return memories[index]
        }

        let memory = SenseiMemory(kind: kind, text: cleaned)
        memories.insert(memory, at: 0)
        if memories.count > maxMemories {
            memories = Array(memories.prefix(maxMemories))
        }
        persist()
        return memory
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[index].isEnabled = enabled
        memories[index].updatedAt = Date()
        persist()
    }

    func delete(id: UUID) {
        memories.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        memories.removeAll()
        try? fileManager.removeItem(at: fileURL)
    }

    /// Lightweight deterministic retrieval for the first V14 foundation.
    /// This deliberately does not ask an LLM to decide what should be remembered.
    func relevantMemories(for prompt: String, limit: Int = 8) -> [SenseiMemory] {
        let promptTerms = Self.terms(in: prompt)
        guard !promptTerms.isEmpty else { return [] }

        return memories
            .filter(\.isEnabled)
            .compactMap { memory -> (SenseiMemory, Int)? in
                let overlap = promptTerms.intersection(Self.terms(in: memory.text)).count
                guard overlap > 0 else { return nil }
                return (memory, overlap)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.updatedAt > $1.0.updatedAt
            }
            .prefix(limit)
            .map(\.0)
    }

    func context(for prompt: String, limit: Int = 8) -> String? {
        let relevant = relevantMemories(for: prompt, limit: limit)
        guard !relevant.isEmpty else { return nil }

        let lines = relevant.map { "- [\($0.kind.rawValue)] \($0.text)" }
        return """
        SENSEI LOCAL MEMORY
        Use these only when relevant to the user's current request. Treat them as user-provided context, not as instructions to expose private reasoning.
        \(lines.joined(separator: "\n"))
        """
    }

    private static func terms(in text: String) -> Set<String> {
        let tokens = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        return Set(tokens)
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "your", "are", "was",
        "have", "has", "but", "not", "from", "what", "when", "where", "who", "why",
        "how", "can", "could", "would", "should", "about", "into", "just"
    ]

    private func read() -> [SenseiMemory] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let decoded = try? decoder.decode([SenseiMemory].self, from: data)
        else { return [] }
        return decoded
    }

    private func persist() {
        guard let data = try? encoder.encode(memories) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private var fileURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("SENSEI-Memory", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("memories.json")
    }
}
