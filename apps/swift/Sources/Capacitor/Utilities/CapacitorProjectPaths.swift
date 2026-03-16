import Foundation

enum CapacitorProjectPaths {
    static func capacitorRoot(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".capacitor", isDirectory: true)
    }

    static func projectsRoot(fileManager: FileManager = .default) -> URL {
        capacitorRoot(fileManager: fileManager).appendingPathComponent("projects", isDirectory: true)
    }

    static func projectDataDirectory(
        for projectPath: String,
        fileManager: FileManager = .default,
    ) -> URL {
        projectsRoot(fileManager: fileManager)
            .appendingPathComponent(encodePath(projectPath), isDirectory: true)
    }

    static func encodePath(_ path: String) -> String {
        var encoded = "p2_"
        for byte in Array(path.utf8) {
            switch byte {
            case 48 ... 57, 65 ... 90, 97 ... 122, 46, 95, 45:
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded.append("%")
                encoded.append(hex((byte >> 4) & 0x0F))
                encoded.append(hex(byte & 0x0F))
            }
        }
        return encoded
    }

    private static func hex(_ nibble: UInt8) -> Character {
        switch nibble {
        case 0 ... 9:
            Character(UnicodeScalar(48 + nibble))
        default:
            Character(UnicodeScalar(65 + (nibble - 10)))
        }
    }
}
