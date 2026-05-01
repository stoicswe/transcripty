import Foundation
import SwiftData

@Model
final class ProjectLabel {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    var createdAt: Date

    @Relationship(inverse: \TranscriptionProject.labels)
    var projects: [TranscriptionProject] = []

    init(name: String, colorHex: String) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.createdAt = .now
    }
}
