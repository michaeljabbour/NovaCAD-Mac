import Foundation

/// Backs the command-bar text field's *entry experience* — autocomplete
/// suggestions, inline ghost-text completion, and command history — while
/// `ContentView.executeCommand()` keeps owning the actual command-dispatch
/// logic unchanged (this type never calls into `CommandParser` itself for
/// dispatch, only for the `complete(prefix:)` suggestions computed from
/// `CommandRegistry`).
@MainActor
final class CommandLineState: ObservableObject {
    @Published var text: String = ""
    @Published var suggestions: [CommandSpec] = []
    @Published var selectedSuggestionIndex: Int? = nil
    /// Inline completion remainder shown after the cursor (e.g. typing "LI"
    /// shows ghost "NE" to complete "LINE"). Empty when there's no single
    /// clear match.
    @Published var ghost: String = ""

    private(set) var history: [String] = []
    private var historyCursor: Int? = nil
    var lastCommand: String? = nil

    private static let historyLimit = 100

    /// Recomputes `suggestions` and `ghost` from the current `text`. Ignores
    /// a leading "/" (the popover trigger prefix) the same way
    /// `executeCommand()` does, so suggestions match what will actually run.
    func onTextChanged() {
        var body = text
        if body.hasPrefix("/") { body.removeFirst() }
        let query = body.trimmingCharacters(in: .whitespaces)

        suggestions = CommandRegistry.complete(prefix: query, limit: 8)
        selectedSuggestionIndex = nil

        guard !query.isEmpty, let first = suggestions.first else {
            ghost = ""
            return
        }
        let upperQuery = query.uppercased()
        // Only offer ghost text when the query is itself a genuine prefix of
        // the top suggestion's canonical name (not just an alias match —
        // completing an alias into the full name would be surprising, e.g.
        // typing "L" should not silently grow into "LINE" as ghost text
        // since "L" is already a complete, valid command on its own).
        guard first.name.hasPrefix(upperQuery), first.name != upperQuery else {
            ghost = ""
            return
        }
        ghost = String(first.name.dropFirst(upperQuery.count))
    }

    /// Appends `ghost` to `text` and clears it (Tab / Right-arrow acceptance).
    func acceptGhost() {
        guard !ghost.isEmpty else { return }
        text += ghost
        ghost = ""
        onTextChanged()
    }

    /// Steps through submitted-command history. `direction`: -1 = older,
    /// +1 = newer. Clamps at both ends rather than wrapping around.
    func recallHistory(direction: Int) {
        guard !history.isEmpty else { return }
        let lastIndex = history.count - 1
        let newCursor: Int
        if let cursor = historyCursor {
            newCursor = max(0, min(lastIndex, cursor + direction))
        } else {
            // Entering history from "no cursor": older starts at the most
            // recent entry, newer has nothing to do.
            guard direction < 0 else { return }
            newCursor = lastIndex
        }
        historyCursor = newCursor
        text = history[newCursor]
        onTextChanged()
    }

    /// Records a non-empty command that just executed: pushes it to history
    /// (capped at 100, dropping the oldest), sets `lastCommand`, and resets
    /// the history cursor so the next recall starts from the end again.
    func recordSubmitted(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        history.append(trimmed)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        lastCommand = trimmed
        historyCursor = nil
    }
}
