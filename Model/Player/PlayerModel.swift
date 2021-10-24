import AVKit
import Defaults
import Foundation
import Logging
#if !os(macOS)
    import UIKit
#endif
import Siesta
import SwiftUI
import SwiftyJSON

final class PlayerModel: ObservableObject {
    let logger = Logger(label: "net.arekf.Pearvidious.ps")

    private(set) var player = AVPlayer()
    var controller: PlayerViewController?
    #if os(tvOS)
        var avPlayerViewController: AVPlayerViewController?
    #endif

    @Published var presentingPlayer = false

    @Published var stream: Stream?
    @Published var currentRate: Float?

    @Published var availableStreams = [Stream]() { didSet { rebuildTVMenu() } }
    @Published var streamSelection: Stream? { didSet { rebuildTVMenu() } }

    @Published var queue = [PlayerQueueItem]()
    @Published var currentItem: PlayerQueueItem!

    @Published var history = [PlayerQueueItem]()
    @Published var savedTime: CMTime?

    @Published var playerNavigationLinkActive = false

    @Published var sponsorBlock = SponsorBlockAPI()
    @Published var segmentRestorationTime: CMTime?
    @Published var lastSkipped: Segment? { didSet { rebuildTVMenu() } }
    @Published var restoredSegments = [Segment]()

    var accounts: AccountsModel
    var instances: InstancesModel

    var composition = AVMutableComposition()
    var timeObserver: Any?
    private var shouldResumePlaying = true
    private var statusObservation: NSKeyValueObservation?

    #if os(macOS)
        var playerTimeControlStatusObserver: Any?
    #endif

    init(accounts: AccountsModel? = nil, instances: InstancesModel? = nil) {
        self.accounts = accounts ?? AccountsModel()
        self.instances = instances ?? InstancesModel()
        addItemDidPlayToEndTimeObserver()
        addTimeObserver()

        #if os(macOS)
            addPlayerTimeControlStatusObserver()
        #endif
    }

    func presentPlayer() {
        presentingPlayer = true
    }

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    var time: CMTime? {
        currentItem?.playbackTime
    }

    var live: Bool {
        currentItem?.video.live ?? false
    }

    var playerItemDuration: CMTime? {
        player.currentItem?.asset.duration
    }

    var videoDuration: TimeInterval? {
        currentItem?.duration ?? currentVideo?.length
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !isPlaying else {
            return
        }

        player.play()
    }

    func pause() {
        guard isPlaying else {
            return
        }

        player.pause()
    }

    func playVideo(_ video: Video, time: CMTime? = nil) {
        savedTime = time
        shouldResumePlaying = true

        loadAvailableStreams(video) { streams in
            guard let stream = streams.first else {
                return
            }

            self.streamSelection = stream
            self.playStream(stream, of: video, preservingTime: !time.isNil)
        }
    }

    func upgradeToStream(_ stream: Stream) {
        if !self.stream.isNil, self.stream != stream {
            playStream(stream, of: currentVideo!, preservingTime: true)
        }
    }

    private func playStream(
        _ stream: Stream,
        of video: Video,
        preservingTime: Bool = false
    ) {
        #if !os(macOS)
            try? AVAudioSession.sharedInstance().setActive(false)
        #endif
        resetSegments()
        sponsorBlock.loadSegments(videoID: video.videoID)

        if let url = stream.singleAssetURL {
            logger.info("playing stream with one asset\(stream.kind == .hls ? " (HLS)" : ""): \(url)")

            insertPlayerItem(stream, for: video, preservingTime: preservingTime)
        } else {
            logger.info("playing stream with many assets:")
            logger.info("composition audio asset: \(stream.audioAsset.url)")
            logger.info("composition video asset: \(stream.videoAsset.url)")

            Task {
                await self.loadComposition(stream, of: video, preservingTime: preservingTime)
            }
        }
    }

    private func insertPlayerItem(
        _ stream: Stream,
        for video: Video,
        preservingTime: Bool = false
    ) {
        let playerItem = playerItem(stream)
        guard playerItem != nil else {
            return
        }

        attachMetadata(to: playerItem!, video: video, for: stream)

        DispatchQueue.main.async {
            self.stream = stream
            self.composition = AVMutableComposition()
        }

        let replaceItemAndSeek = {
            self.player.replaceCurrentItem(with: playerItem)
            self.seekToSavedTime { finished in
                guard finished else {
                    return
                }
                self.savedTime = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.play()
                }
            }
        }

        let startPlaying = {
            #if !os(macOS)
                try? AVAudioSession.sharedInstance().setActive(true)
            #endif

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.play()
            }
        }

        if preservingTime {
            if savedTime.isNil {
                saveTime {
                    replaceItemAndSeek()
                    startPlaying()
                }
            } else {
                replaceItemAndSeek()
                startPlaying()
            }
        } else {
            player.replaceCurrentItem(with: playerItem)
            startPlaying()
        }
    }

    private func loadComposition(
        _ stream: Stream,
        of video: Video,
        preservingTime: Bool = false
    ) async {
        await loadCompositionAsset(stream.audioAsset, type: .audio, of: video)
        await loadCompositionAsset(stream.videoAsset, type: .video, of: video)

        guard streamSelection == stream else {
            logger.critical("IGNORING LOADED")
            return
        }

        insertPlayerItem(stream, for: video, preservingTime: preservingTime)
    }

    private func loadCompositionAsset(_ asset: AVURLAsset, type: AVMediaType, of video: Video) async {
        async let assetTracks = asset.loadTracks(withMediaType: type)

        logger.info("loading \(type.rawValue) track")
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: type,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            logger.critical("composition \(type.rawValue) addMutableTrack FAILED")
            return
        }

        guard let assetTrack = try? await assetTracks.first else {
            logger.critical("asset \(type.rawValue) track FAILED")
            return
        }

        try! compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTime(seconds: video.length, preferredTimescale: 1_000_000)),
            of: assetTrack,
            at: .zero
        )

        logger.critical("\(type.rawValue) LOADED")
    }

    private func playerItem(_ stream: Stream) -> AVPlayerItem? {
        if let url = stream.singleAssetURL {
            return AVPlayerItem(asset: AVURLAsset(url: url))
        } else {
            return AVPlayerItem(asset: composition)
        }
    }

    private func attachMetadata(to item: AVPlayerItem, video: Video, for _: Stream? = nil) {
        #if !os(macOS)
            var externalMetadata = [
                makeMetadataItem(.commonIdentifierTitle, value: video.title),
                makeMetadataItem(.quickTimeMetadataGenre, value: video.genre ?? ""),
                makeMetadataItem(.commonIdentifierDescription, value: video.description ?? "")
            ]
            if let thumbnailData = try? Data(contentsOf: video.thumbnailURL(quality: .medium)!),
               let image = UIImage(data: thumbnailData),
               let pngData = image.pngData()
            {
                let artworkItem = makeMetadataItem(.commonIdentifierArtwork, value: pngData)
                externalMetadata.append(artworkItem)
            }

            item.externalMetadata = externalMetadata
        #endif

        item.preferredForwardBufferDuration = 5

        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.old, .new]) { playerItem, _ in
            switch playerItem.status {
            case .readyToPlay:
                if self.isAutoplaying(playerItem), self.shouldResumePlaying {
                    self.play()
                }
            case .failed:
                print("item error: \(String(describing: item.error))")
                print((item.asset as! AVURLAsset).url)

            default:
                return
            }
        }
    }

    #if !os(macOS)
        private func makeMetadataItem(_ identifier: AVMetadataIdentifier, value: Any) -> AVMetadataItem {
            let item = AVMutableMetadataItem()

            item.identifier = identifier
            item.value = value as? NSCopying & NSObjectProtocol
            item.extendedLanguageTag = "und"

            return item.copy() as! AVMetadataItem
        }
    #endif

    private func addItemDidPlayToEndTimeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(itemDidPlayToEndTime),
            name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

    @objc func itemDidPlayToEndTime() {
        #if !os(macOS)
            try? AVAudioSession.sharedInstance().setActive(false)
        #endif

        if queue.isEmpty {
            addCurrentItemToHistory()
            resetQueue()
            #if os(tvOS)
                avPlayerViewController!.dismiss(animated: true) {
                    self.controller!.dismiss(animated: true)
                }
            #endif
            presentingPlayer = false
        } else {
            advanceToNextItem()
        }
    }

    private func saveTime(completionHandler: @escaping () -> Void = {}) {
        let currentTime = player.currentTime()

        guard currentTime.seconds > 0 else {
            return
        }

        DispatchQueue.main.async {
            self.savedTime = currentTime
            completionHandler()
        }
    }

    private func seekToSavedTime(completionHandler: @escaping (Bool) -> Void = { _ in }) {
        guard let time = savedTime else {
            return
        }

        player.seek(
            to: time,
            toleranceBefore: .init(seconds: 1, preferredTimescale: 1_000_000),
            toleranceAfter: .zero,
            completionHandler: completionHandler
        )
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 1_000_000)

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            self.currentRate = self.player.rate

            guard !self.currentItem.isNil else {
                return
            }

            let time = self.player.currentTime()

            self.currentItem!.playbackTime = time
            self.currentItem!.videoDuration = self.player.currentItem?.asset.duration.seconds

            self.handleSegments(at: time)
        }
    }

    #if os(macOS)
        private func addPlayerTimeControlStatusObserver() {
            playerTimeControlStatusObserver = player.observe(\.timeControlStatus) { player, _ in
                guard self.player == player else {
                    return
                }
                if player.timeControlStatus == .playing {
                    ScreenSaverManager.shared.disable(reason: "Yattee is playing video")
                } else {
                    ScreenSaverManager.shared.enable()
                }
            }
        }
    #endif
}
