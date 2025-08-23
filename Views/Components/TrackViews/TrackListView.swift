import SwiftUI

struct TrackListView: View {
    let tracks: [Track]
    let onPlayTrack: (Track) -> Void
    let contextMenuItems: (Track) -> [ContextMenuItem]

    @EnvironmentObject var playbackManager: PlaybackManager
    @State private var hoveredTrackID: UUID?
    @State private var hoverWorkItem: DispatchWorkItem?

    var body: some View {
        Group {
            if tracks.count < ViewDefaults.listBufferSize {
                List {
                    ForEach(tracks, id: \.id) { track in
                        TrackListRow(
                            track: track,
                            isHovered: hoveredTrackID == track.id,
                            onPlay: {
                                let isCurrentTrack = playbackManager.currentTrack?.url.path == track.url.path
                                if !isCurrentTrack {
                                    onPlayTrack(track)
                                }
                            },
                            onHover: { isHovered in
                                handleHover(for: track, isHovered: isHovered)
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: -2, bottom: 0, trailing: -2))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            TrackContextMenuContent(items: contextMenuItems(track))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .padding(.top, 5)
                .padding(.horizontal, 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(tracks, id: \.id) { track in
                            TrackListRow(
                                track: track,
                                isHovered: hoveredTrackID == track.id,
                                onPlay: {
                                    let isCurrentTrack = playbackManager.currentTrack?.url.path == track.url.path
                                    if !isCurrentTrack {
                                        onPlayTrack(track)
                                    }
                                },
                                onHover: { isHovered in
                                    hoveredTrackID = isHovered ? track.id : nil
                                }
                            )
                            .contextMenu {
                                TrackContextMenuContent(items: contextMenuItems(track))
                            }
                            .id(track.id)
                        }
                    }
                    .padding(5)
                }
            }
        }
    }
    
    private func handleHover(for track: Track, isHovered: Bool) {
        hoverWorkItem?.cancel()
        
        if isHovered {
            hoveredTrackID = track.id
        } else {
            let trackID = track.id
            hoverWorkItem = DispatchWorkItem {
                if hoveredTrackID == trackID {
                    hoveredTrackID = nil
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: hoverWorkItem!)
        }
    }
}

// MARK: - Track List Row
private struct TrackListRow: View {
    let track: Track
    let isHovered: Bool
    let onPlay: () -> Void
    let onHover: (Bool) -> Void

    @EnvironmentObject var playbackManager: PlaybackManager
    @State private var artworkImage: NSImage?

    var body: some View {
        HStack(spacing: 0) {
            playButtonSection
            trackContent
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onPlay)
        }
        .frame(height: 60)
        .background(backgroundView)
        .onHover(perform: onHover)
    }

    // MARK: - Computed Properties

    private var isCurrentTrack: Bool {
        guard let currentTrack = playbackManager.currentTrack else { return false }
        return currentTrack.url.path == track.url.path
    }

    private var isPlaying: Bool {
        isCurrentTrack && playbackManager.isPlaying
    }

    // MARK: - View Components

    private var playButtonSection: some View {
        ZStack {
            if shouldShowPlayButton {
                Button(action: handlePlayButtonTap) {
                    Image(systemName: playButtonIcon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            } else if isPlaying && !isHovered {
                PlayingIndicator()
                    .frame(width: 16)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 40, height: 40)
        .animation(.easeInOut(duration: AnimationDuration.standardDuration), value: isHovered)
    }

    private var trackContent: some View {
        HStack(spacing: 12) {
            albumArtwork
            trackInfo
            Spacer()
            durationLabel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var albumArtwork: some View {
        Group {
            if let artworkImage = artworkImage {
                Image(nsImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if track.isMetadataLoaded {
                placeholderArtwork
            } else {
                loadingArtwork
            }
        }
        .task(id: track.id) {
            await loadTrackArtworkAsync(
                from: track.albumArtworkMedium,
                into: $artworkImage,
                delay: TimeConstants.oneHundredMilliseconds
            )
        }
        .onDisappear { artworkImage = nil }
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.2))
            .frame(width: 40, height: 40)
            .overlay(
                Image(systemName: Icons.musicNote)
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            )
    }

    private var loadingArtwork: some View {
        ProgressView()
            .scaleEffect(0.5)
            .frame(width: 40, height: 40)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(4)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            titleLabel
            detailsLabel
        }
    }

    private var titleLabel: some View {
        Text(track.title)
            .font(.system(size: 14, weight: isCurrentTrack ? .medium : .regular))
            .foregroundColor(isCurrentTrack ? .accentColor : .primary)
            .lineLimit(1)
            .redacted(reason: track.isMetadataLoaded ? [] : .placeholder)
    }

    private var detailsLabel: some View {
        let components = buildDetailComponents()
        
        return Text(components)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .redacted(reason: track.isMetadataLoaded ? [] : .placeholder)
    }

    private func buildDetailComponents() -> String {
        var parts: [String] = []
        
        parts.append(track.artist)
        
        if shouldShowAlbum {
            parts.append(track.album)
        }
        
        if shouldShowYear {
            parts.append(track.year)
        }
        
        return parts.joined(separator: " • ")
    }

    private var durationLabel: some View {
        Text(formatDuration(track.duration))
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .monospacedDigit()
            .redacted(reason: track.isMetadataLoaded ? [] : .placeholder)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(backgroundColor)
    }

    // MARK: - Helper Properties

    private var shouldShowPlayButton: Bool {
        // Show button if:
        // 1. Hovered (play or pause depending on state)
        // 2. Current track but paused (persistent play button)
        isHovered || (isCurrentTrack && !playbackManager.isPlaying)
    }

    private var playButtonIcon: String {
        if isCurrentTrack {
            return isPlaying ? Icons.pauseFill : Icons.playFill
        }
        return Icons.playFill
    }

    private var playButtonColor: Color {
        isCurrentTrack ? .accentColor : .primary
    }

    private var backgroundColor: Color {
        if isPlaying {
            return isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.08) : Color.clear
        } else if isHovered {
            return Color(NSColor.selectedContentBackgroundColor).opacity(0.15)
        } else {
            return Color.clear
        }
    }

    private var shouldShowAlbum: Bool {
        !track.album.isEmpty && track.album != "Unknown Album"
    }

    private var shouldShowYear: Bool {
        track.isMetadataLoaded && !track.year.isEmpty && track.year != "Unknown Year"
    }

    // MARK: - Methods

    private func handlePlayButtonTap() {
        if isCurrentTrack {
            playbackManager.togglePlayPause()
        } else {
            onPlay()
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = Int(max(0, seconds))
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: StringFormat.mmss, minutes, remainingSeconds)
    }
}
