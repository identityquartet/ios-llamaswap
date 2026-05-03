import SwiftData
import Foundation

@Model
final class Conversation {
    var title: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade) var messages: [StoredMessage] = []

    init(title: String = "New Chat") {
        self.title = title
        self.createdAt = Date()
    }
}

@Model
final class StoredMessage {
    var role: String
    var content: String
    var createdAt: Date

    init(role: String, content: String) {
        self.role = role
        self.content = content
        self.createdAt = Date()
    }
}
