import Foundation

/// A named group of windows, typically one per project.
struct Workspace: Equatable, Identifiable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// The workspaces and which one is showing. Always holds at least one.
struct WorkspaceList: Equatable {
    private(set) var workspaces: [Workspace]
    private(set) var activeID: UUID

    init() {
        let first = Workspace(name: "Main")
        workspaces = [first]
        activeID = first.id
    }

    var active: Workspace { workspaces.first { $0.id == activeID } ?? workspaces[0] }

    @discardableResult
    mutating func add(name: String) -> Workspace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = Workspace(name: trimmed.isEmpty ? "Workspace \(workspaces.count + 1)" : trimmed)
        workspaces.append(workspace)
        return workspace
    }

    mutating func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].name = trimmed
    }

    mutating func activate(_ id: UUID) {
        if workspaces.contains(where: { $0.id == id }) { activeID = id }
    }

    /// The workspace `offset` places from the active one, wrapping around.
    func neighbor(offset: Int) -> Workspace {
        let index = workspaces.firstIndex { $0.id == activeID } ?? 0
        let count = workspaces.count
        return workspaces[((index + offset) % count + count) % count]
    }

    /// Removes a workspace unless it is the last one. If it was active, the one before it
    /// takes over.
    mutating func remove(_ id: UUID) {
        guard workspaces.count > 1, let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces.remove(at: index)
        if activeID == id {
            activeID = workspaces[max(index - 1, 0)].id
        }
    }
}
