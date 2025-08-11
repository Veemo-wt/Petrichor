//
// DatabaseManager class extension
//
// This extension contains all the methods for querying records from the database based on
// various criteria.
//

import Foundation
import GRDB

extension DatabaseManager {
    /// Populate track album art from albums table
    func populateAlbumArtworkForTracks(_ tracks: inout [Track], db: Database) throws {
        // Get unique album IDs
        let albumIds = tracks.compactMap { $0.albumId }.removingDuplicates()
        
        guard !albumIds.isEmpty else { return }
        
        // Fetch only id and artwork_data columns
        let request = Album
            .select(Album.Columns.id, Album.Columns.artworkData)
            .filter(albumIds.contains(Album.Columns.id))
        
        let rows = try Row.fetchAll(db, request)
        
        // Build artwork map
        let albumArtworkMap: [Int64: Data] = rows.reduce(into: [:]) { dict, row in
            if let id: Int64 = row["id"],
               let artwork: Data = row["artwork_data"] {
                dict[id] = artwork
            }
        }
        
        // Populate the transient property
        for i in 0..<tracks.count {
            if let albumId = tracks[i].albumId,
               let albumArtwork = albumArtworkMap[albumId] {
                tracks[i].albumArtworkData = albumArtwork
            }
        }
    }

    func populateAlbumArtworkForTracks(_ tracks: inout [Track]) {
        do {
            try dbQueue.read { db in
                try populateAlbumArtworkForTracks(&tracks, db: db)
            }
        } catch {
            Logger.error("Failed to populate album artwork: \(error)")
        }
    }
    
    /// Populate album artwork for a single FullTrack
    func populateAlbumArtworkForFullTrack(_ track: inout FullTrack) {
        guard let albumId = track.albumId else { return }
        
        do {
            if let artworkData = try dbQueue.read({ db in
                try Album
                    .select(Album.Columns.artworkData)
                    .filter(Album.Columns.id == albumId)
                    .fetchOne(db)?[Album.Columns.artworkData] as Data?
            }) {
                track.albumArtworkData = artworkData
            }
        } catch {
            Logger.error("Failed to populate album artwork for full track: \(error)")
        }
    }
    
    /// Get tracks for the Discover feature
    func getDiscoverTracks(limit: Int = 50, excludeTrackIds: Set<Int64> = []) -> [Track] {
        do {
            return try dbQueue.read { db in
                var query = Track.all()
                    .filter(Track.Columns.isDuplicate == false)  // Always exclude duplicates
                    .filter(Track.Columns.playCount == 0)
                
                if !excludeTrackIds.isEmpty {
                    query = query.filter(!excludeTrackIds.contains(Track.Columns.trackId))
                }
                
                // Order randomly
                query = query.order(sql: "RANDOM()")
                    .limit(limit)
                
                var tracks = try query.fetchAll(db)
                
                // If we don't have enough unplayed tracks, fill with least recently played
                if tracks.count < limit {
                    let remaining = limit - tracks.count
                    let existingIds = Set(tracks.compactMap { $0.trackId })
                        .union(excludeTrackIds)
                    
                    let additionalTracks = try Track.all()
                        .filter(Track.Columns.isDuplicate == false)
                        .filter(!existingIds.contains(Track.Columns.trackId))
                        .order(
                            Track.Columns.lastPlayedDate.asc,
                            Track.Columns.playCount.asc
                        )
                        .limit(remaining)
                        .fetchAll(db)
                    
                    tracks.append(contentsOf: additionalTracks)
                }
                
                try populateAlbumArtworkForTracks(&tracks, db: db)
                
                return tracks
            }
        } catch {
            Logger.error("Failed to get discover tracks: \(error)")
            return []
        }
    }

    /// Get tracks by IDs (for loading saved discover tracks)
    func getTracks(byIds trackIds: [Int64]) -> [Track] {
        do {
            return try dbQueue.read { db in
                try Track
                    .filter(trackIds.contains(Track.Columns.trackId))
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to get tracks by IDs: \(error)")
            return []
        }
    }
    
    /// Get total track count without loading tracks
    func getTotalTrackCount() -> Int {
        do {
            return try dbQueue.read { db in
                try applyDuplicateFilter(Track.all()).fetchCount(db)
            }
        } catch {
            Logger.error("Failed to get total track count: \(error)")
            return 0
        }
    }
    
    /// Get total duration of all tracks in the library
    func getTotalDuration() -> Double {
        do {
            return try dbQueue.read { db in
                let result = try applyDuplicateFilter(Track.all())
                    .select(sum(Track.Columns.duration), as: Double.self)
                    .fetchOne(db)
                
                return result ?? 0.0
            }
        } catch {
            Logger.error("Failed to get total duration: \(error)")
            return 0.0
        }
    }

    /// Get distinct values for a filter type using normalized tables
    func getDistinctValues(for filterType: LibraryFilterType) -> [String] {
        do {
            return try dbQueue.read { db in
                switch filterType {
                case .artists, .albumArtists, .composers:
                    // Get from normalized artists table
                    let artists = try Artist
                        .select(Artist.Columns.name, as: String.self)
                        .order(Artist.Columns.sortName)
                        .fetchAll(db)

                    // Add "Unknown" placeholder if there are tracks without artists
                    var results = artists
                    if try applyDuplicateFilter(Track.all()).filter(Track.Columns.artist == filterType.unknownPlaceholder).fetchCount(db) > 0 {
                        results.append(filterType.unknownPlaceholder)
                    }
                    return results

                case .albums:
                    // Get from normalized albums table
                    let albums = try Album
                        .select(Album.Columns.title, as: String.self)
                        .order(Album.Columns.sortTitle)
                        .fetchAll(db)

                    // Add "Unknown Album" if needed
                    var results = albums
                    if try applyDuplicateFilter(Track.all()).filter(Track.Columns.album == "Unknown Album").fetchCount(db) > 0 {
                        results.append("Unknown Album")
                    }
                    return results

                case .genres:
                    // Get from normalized genres table
                    let genres = try Genre
                        .select(Genre.Columns.name, as: String.self)
                        .order(Genre.Columns.name)
                        .fetchAll(db)

                    // Add "Unknown Genre" if needed
                    var results = genres
                    if try applyDuplicateFilter(Track.all()).filter(Track.Columns.genre == "Unknown Genre").fetchCount(db) > 0 {
                        results.append("Unknown Genre")
                    }
                    return results
                    
                case .decades:
                    // Get all years and convert to decades
                    let years = try applyDuplicateFilter(Track.all())
                        .select(Track.Columns.year, as: String.self)
                        .filter(Track.Columns.year != "")
                        .filter(Track.Columns.year != "Unknown Year")
                        .distinct()
                        .fetchAll(db)
                    
                    // Convert years to decades
                    var decadesSet = Set<String>()
                    for year in years {
                        if let yearInt = Int(year.prefix(4)) {
                            let decade = (yearInt / 10) * 10
                            decadesSet.insert("\(decade)s")
                        }
                    }
                    
                    // Sort decades in descending order
                    return decadesSet.sorted { decade1, decade2 in
                        let d1 = Int(decade1.dropLast()) ?? 0
                        let d2 = Int(decade2.dropLast()) ?? 0
                        return d1 > d2
                    }

                case .years:
                    // Years don't have a normalized table, use tracks directly
                    return try applyDuplicateFilter(Track.all())
                        .select(Track.Columns.year, as: String.self)
                        .filter(Track.Columns.year != "")
                        .distinct()
                        .order(Track.Columns.year.desc)
                        .fetchAll(db)
                }
            }
        } catch {
            Logger.error("Failed to get distinct values for \(filterType): \(error)")
            return []
        }
    }

    /// Get tracks by filter type and value using normalized tables
    func getTracksByFilterType(_ filterType: LibraryFilterType, value: String) -> [Track] {
        do {
            return try dbQueue.read { db in
                var tracks: [Track] = []
                
                switch filterType {
                case .artists, .albumArtists, .composers:
                    if value == filterType.unknownPlaceholder {
                        switch filterType {
                        case .artists:
                            tracks = try Track.lightweightRequest()
                                .filter(Track.Columns.artist == value)
                                .fetchAll(db)
                        case .albumArtists:
                            tracks = try Track.lightweightRequest()
                                .filter(Track.Columns.albumArtist == value)
                                .fetchAll(db)
                        case .composers:
                            tracks = try Track.lightweightRequest()
                                .filter(Track.Columns.composer == value)
                                .fetchAll(db)
                        default:
                            return []
                        }
                    } else {
                        let normalizedSearchName = ArtistParser.normalizeArtistName(value)
                        
                        guard let artist = try Artist
                            .filter((Artist.Columns.name == value) || (Artist.Columns.normalizedName == normalizedSearchName))
                            .fetchOne(db),
                            let artistId = artist.id else {
                            return []
                        }
                        
                        let trackIds = try TrackArtist
                            .filter(TrackArtist.Columns.artistId == artistId)
                            .select(TrackArtist.Columns.trackId, as: Int64.self)
                            .fetchAll(db)
                        
                        tracks = try Track.lightweightRequest()
                            .filter(trackIds.contains(Track.Columns.trackId))
                            .fetchAll(db)
                    }
                        
                case .albums:
                    tracks = try Track.lightweightRequest()
                        .filter(Track.Columns.album == value)
                        .fetchAll(db)
                        
                case .genres:
                    tracks = try Track.lightweightRequest()
                        .filter(Track.Columns.genre == value)
                        .fetchAll(db)
                        
                case .years:
                    tracks = try Track.lightweightRequest()
                        .filter(Track.Columns.year == value)
                        .fetchAll(db)
                        
                case .decades:
                    let decade = value.replacingOccurrences(of: "s", with: "")
                    if let decadeInt = Int(decade) {
                        let startYear = String(decadeInt)
                        let endYear = String(decadeInt + 9)
                        tracks = try Track.lightweightRequest()
                            .filter(Track.Columns.year >= startYear && Track.Columns.year <= endYear)
                            .fetchAll(db)
                    }
                }
                
                // Order results
                tracks = tracks.sorted { $0.title < $1.title }
                
                // Populate album artwork
                try populateAlbumArtworkForTracks(&tracks, db: db)
                
                return tracks
            }
        } catch {
            Logger.error("Failed to get tracks by filter type: \(error)")
            return []
        }
    }

    /// Get tracks where the filter value is contained (for multi-artist parsing)
    func getTracksByFilterTypeContaining(_ filterType: LibraryFilterType, value: String) -> [Track] {
        do {
            return try dbQueue.read { db in
                // This is specifically for multi-artist fields
                guard filterType.usesMultiArtistParsing else {
                    return getTracksByFilterType(filterType, value: value)
                }

                // Find the artist (handles normalized name matching)
                let normalizedSearchName = ArtistParser.normalizeArtistName(value)

                guard let artist = try Artist
                    .filter((Artist.Columns.name == value) || (Artist.Columns.normalizedName == normalizedSearchName))
                    .fetchOne(db),
                    let artistId = artist.id else {
                    return []
                }

                let role: String = switch filterType {
                case .artists: "artist"
                case .albumArtists: "album_artist"
                case .composers: "composer"
                default: "artist"
                }

                let trackIds = try TrackArtist
                    .filter(TrackArtist.Columns.artistId == artistId)
                    .filter(TrackArtist.Columns.role == role)
                    .select(TrackArtist.Columns.trackId, as: Int64.self)
                    .fetchAll(db)

                return try applyDuplicateFilter(Track.all())
                    .filter(trackIds.contains(Track.Columns.trackId))
                    .fetchAll(db)
            }
        } catch {
            Logger.error("Failed to get tracks by filter type containing: \(error)")
            return []
        }
    }

    // MARK: - Entity Queries (for Home tab)

    /// Get tracks for an artist entity
    func getTracksForArtistEntity(_ artistName: String) -> [Track] {
        do {
            var tracks = try dbQueue.read { db in
                let normalizedName = ArtistParser.normalizeArtistName(artistName)
                
                let sql = """
                    SELECT DISTINCT t.*
                    FROM tracks t
                    INNER JOIN track_artists ta ON t.id = ta.track_id
                    INNER JOIN artists a ON ta.artist_id = a.id
                    WHERE (a.name = ? OR a.normalized_name = ?)
                        AND t.is_duplicate = 0
                    ORDER BY t.album, t.track_number
                """
                
                return try Track.fetchAll(db, sql: sql, arguments: [artistName, normalizedName])
            }
            
            populateAlbumArtworkForTracks(&tracks)
            return tracks
        } catch {
            Logger.error("Failed to get tracks for artist entity: \(error)")
            return []
        }
    }

    /// Get tracks for an album entity
    func getTracksForAlbumEntity(_ albumEntity: AlbumEntity) -> [Track] {
        do {
            var tracks = try dbQueue.read { db in
                if let albumId = albumEntity.albumId {
                    return try Track
                        .filter(Track.Columns.albumId == albumId)
                        .filter(Track.Columns.isDuplicate == false)
                        .order(Track.Columns.discNumber ?? 1, Track.Columns.trackNumber ?? 0)
                        .fetchAll(db)
                } else {
                    var query = Track
                        .filter(Track.Columns.album == albumEntity.name)
                        .filter(Track.Columns.isDuplicate == false)
                    
                    if let artistName = albumEntity.artistName {
                        query = query.filter(Track.Columns.albumArtist == artistName)
                    }
                    
                    return try query
                        .order(Track.Columns.discNumber ?? 1, Track.Columns.trackNumber ?? 0)
                        .fetchAll(db)
                }
            }
            
            populateAlbumArtworkForTracks(&tracks)
            return tracks
        } catch {
            Logger.error("Failed to get tracks for album entity: \(error)")
            return []
        }
    }

    // MARK: - Quick Count Methods

    func getArtistCount() -> Int {
        do {
            return try dbQueue.read { db in
                try Artist
                    .filter(Artist.Columns.totalTracks > 0)
                    .fetchCount(db)
            }
        } catch {
            Logger.error("Failed to get artist count: \(error)")
            return 0
        }
    }

    func getAlbumCount() -> Int {
        do {
            return try dbQueue.read { db in
                try Album
                    .filter(Album.Columns.totalTracks > 0)
                    .fetchCount(db)
            }
        } catch {
            Logger.error("Failed to get album count: \(error)")
            return 0
        }
    }

    // MARK: - Library Filter Items

    func getAllTracks() -> [Track] {
        do {
            var tracks = try dbQueue.read { db in
                try Track.lightweightRequest()
                    .order(Track.Columns.title)
                    .fetchAll(db)
            }

            populateAlbumArtworkForTracks(&tracks)
            
            return tracks
        } catch {
            Logger.error("Failed to fetch all tracks: \(error)")
            return []
        }
    }

    func getTracksForFolder(_ folderId: Int64) -> [Track] {
        do {
            var tracks = try dbQueue.read { db in
                try Track.lightweightRequest()
                    .filter(Track.Columns.folderId == folderId)
                    .order(Track.Columns.title)
                    .fetchAll(db)
            }
            
            populateAlbumArtworkForTracks(&tracks)
            
            return tracks
        } catch {
            Logger.error("Failed to fetch tracks for folder: \(error)")
            return []
        }
    }
    
    /// Get artist ID by name
    func getArtistId(for artistName: String) -> Int64? {
        do {
            return try dbQueue.read { db in
                let normalizedName = ArtistParser.normalizeArtistName(artistName)
                return try Artist
                    .filter((Artist.Columns.name == artistName) || (Artist.Columns.normalizedName == normalizedName))
                    .fetchOne(db)?
                    .id
            }
        } catch {
            Logger.error("Failed to get artist ID: \(error)")
            return nil
        }
    }
    
    /// Get album by title
    func getAlbumByTitle(_ title: String) -> Album? {
        do {
            return try dbQueue.read { db in
                try Album
                    .filter(Album.Columns.title == title)
                    .fetchOne(db)
            }
        } catch {
            Logger.error("Failed to get album by title: \(error)")
            return nil
        }
    }
    
    // MARK: - Helper Methods
    
    func trackExists(withId trackId: Int64) -> Bool {
        do {
            return try dbQueue.read { db in
                try Track.filter(Track.Columns.trackId == trackId).fetchCount(db) > 0
            }
        } catch {
            Logger.error("Failed to check track existence: \(error)")
            return false
        }
    }

    /// Apply duplicate filtering to a Track query if the user preference is enabled
    func applyDuplicateFilter(_ query: QueryInterfaceRequest<Track>) -> QueryInterfaceRequest<Track> {
        let hideDuplicates = UserDefaults.standard.bool(forKey: "hideDuplicateTracks")
        
        if hideDuplicates {
            return query.filter(Track.Columns.isDuplicate == false)
        }
        
        return query
    }
}
