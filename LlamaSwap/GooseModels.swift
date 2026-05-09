import Foundation

struct GooseMessage: Identifiable {
    let id = UUID()
    let role: GooseRole
    var text: String
    var toolEvents: [ToolEvent] = []
    var isStreaming: Bool = false

    enum GooseRole { case user, assistant }
    var isUser: Bool { role == .user }
}

struct ToolEvent: Identifiable {
    let id = UUID()
    let name: String
    let input: String
    var done: Bool = false
}
