import Foundation
import MurmurCore

/// Small atomic messages in the local App Group. No audio is written here.
enum KeyboardSessionStore {
    static func read<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        guard let root = StoragePaths.shared, let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    static func write<T: Encodable>(_ value: T, to name: String) throws {
        guard let root = StoragePaths.shared else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(value)
        try data.write(to: root.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
    }
    static var state: KeyboardSessionState? { read("keyboard-session.json", as: KeyboardSessionState.self) }
    static var command: KeyboardCommand? { read("keyboard-command.json", as: KeyboardCommand.self) }
    static var heartbeat: KeyboardHeartbeat? { read("keyboard-heartbeat.json", as: KeyboardHeartbeat.self) }
    // Acknowledged results were inserted or explicitly dismissed. Keep this
    // receipt across keyboard launches so an old session cannot show them again.
    static var insertedID: UUID? { read("keyboard-inserted.json", as: UUID.self) }
    static var configuration: KeyboardConfiguration? { read("keyboard-configuration.json", as: KeyboardConfiguration.self) }
    static func saveConfiguration(_ configuration: KeyboardConfiguration) throws { try write(configuration, to: "keyboard-configuration.json") }
    static func publish(_ state: KeyboardSessionState) throws { try write(state, to: "keyboard-session.json") }
    static func send(_ command: KeyboardCommand) throws { try write(command, to: "keyboard-command.json") }
    static func keepAlive(_ session: UUID) throws { try write(KeyboardHeartbeat(sessionID: session), to: "keyboard-heartbeat.json") }
    static func acknowledge(_ utterance: UUID) throws { try write(utterance, to: "keyboard-inserted.json") }
}
