import Foundation

enum Sections: String, CaseIterable, Identifiable {
    case home
    case library
    case playlists
    case folders

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .playlists: return "Playlists"
        case .folders: return "Folders"
        }
    }

    var icon: String {
        switch self {
        case .home: return Icons.musicNoteHouse
        case .library: return Icons.customMusicNoteRectangleStack
        case .playlists: return Icons.musicNoteList
        case .folders: return Icons.folder
        }
    }

    var selectedIcon: String {
        switch self {
        case .home: return Icons.musicNoteHouseFill
        case .library: return Icons.customMusicNoteRectangleStackFill
        case .playlists: return Icons.musicNoteList
        case .folders: return Icons.folderFill
        }
    }
}
