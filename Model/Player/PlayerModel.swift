import AVKit
import CoreData
#if os(iOS)
    import CoreMotion
#endif
import Defaults
import Foundation
import Logging
import MediaPlayer
import Siesta
import SwiftUI
import SwiftyJSON
#if !os(macOS)
    import UIKit
#endif

final class PlayerModel: ObservableObject {
    static let availableRates: [Float] = [0.5, 0.67, 0.8, 1, 1.25, 1.5, 2]
    static let assetKeysToLoad = ["tracks", "playable", "duration"]
    let logger = Logger(label: "stream.yattee.app")

    private(set) var player = AVPlayer()
    var playerView = Player()
    var controller: PlayerViewController?
    var playerItem: AVPlayerItem?

    @Published var presentingPlayer = false { didSet { handlePresentationChange() } }

    @Published var stream: Stream?
    @Published var currentRate: Float = 1.0 { didSet { player.rate = currentRate } }

    @Published var availableStreams = [Stream]() { didSet { handleAvailableStreamsChange() } }
    @Published var streamSelection: Stream? { didSet { rebuildTVMenu() } }

    @Published var queue = [PlayerQueueItem]() { didSet { Defaults[.queue] = queue } }
    @Published var currentItem: PlayerQueueItem! { didSet { handleCurrentItemChange() } }
    @Published var historyVideos = [Video]()

    @Published var preservedTime: CMTime?

    @Published var playerNavigationLinkActive = false { didSet { handleNavigationViewPlayerPresentationChange() } }

    @Published var sponsorBlock = SponsorBlockAPI()
    @Published var segmentRestorationTime: CMTime?
    @Published var lastSkipped: Segment? { didSet { rebuildTVMenu() } }
    @Published var restoredSegments = [Segment]()

    #if os(iOS)
        @Published var motionManager: CMMotionManager!
        @Published var lockedOrientation: UIInterfaceOrientation?
        @Published var lastOrientation: UIInterfaceOrientation?
    #endif

    var accounts: AccountsModel
    var comments: CommentsModel

    var asset: AVURLAsset?
    var composition = AVMutableComposition()
    var loadedCompositionAssets = [AVMediaType]()

    var context: NSManagedObjectContext = PersistenceController.shared.container.viewContext

    private var currentArtwork: MPMediaItemArtwork?
    private var frequentTimeObserver: Any?
    private var infrequentTimeObserver: Any?
    private var playerTimeControlStatusObserver: Any?

    private var statusObservation: NSKeyValueObservation?

    private var timeObserverThrottle = Throttle(interval: 2)

    var playingInPictureInPicture = false
    var playingFullscreen = false

    @Published var presentingErrorDetails = false
    var playerError: Error? { didSet {
        #if !os(tvOS)
            if !playerError.isNil {
                presentingErrorDetails = true
            }
        #endif
    }}

    @Default(.pauseOnHidingPlayer) private var pauseOnHidingPlayer
    @Default(.closePiPOnNavigation) var closePiPOnNavigation
    @Default(.closePiPOnOpeningPlayer) var closePiPOnOpeningPlayer

    #if !os(macOS)
        @Default(.closePiPAndOpenPlayerOnEnteringForeground) var closePiPAndOpenPlayerOnEnteringForeground
    #endif

    init(accounts: AccountsModel? = nil, comments: CommentsModel? = nil) {
        self.accounts = accounts ?? AccountsModel()
        self.comments = comments ?? CommentsModel()

        addFrequentTimeObserver()
        addInfrequentTimeObserver()
        addPlayerTimeControlStatusObserver()
    }

    func show() {
        guard !presentingPlayer else {
            #if os(macOS)
                Windows.player.focus()
            #endif
            return
        }
        #if os(macOS)
            Windows.player.open()
            Windows.player.focus()
        #endif
        presentingPlayer = true
    }

    func hide() {
        presentingPlayer = false
        playerNavigationLinkActive = false
    }

    func togglePlayer() {
        #if os(macOS)
            if !presentingPlayer {
                Windows.player.open()
            }
            Windows.player.focus()
        #else
            if presentingPlayer {
                hide()
            } else {
                show()
            }
        #endif
    }

    var isLoadingVideo: Bool {
        guard !currentVideo.isNil else {
            return false
        }

        return player.currentItem == nil || time == nil || !time!.isValid
    }

    var isPlaying: Bool {
        player.timeControlStatus == .playing
    }

    var time: CMTime? {
        currentItem?.playbackTime
    }

    var live: Bool {
        currentVideo?.live ?? false
    }

    var playerItemDuration: CMTime? {
        player.currentItem?.asset.duration
    }

    var videoDuration: TimeInterval? {
        currentItem?.duration ?? currentVideo?.length ?? player.currentItem?.asset.duration.seconds
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard player.timeControlStatus != .playing else {
            return
        }

        player.play()
    }

    func pause() {
        guard player.timeControlStatus != .paused else {
            return
        }

        player.pause()
    }

    func play(_ video: Video, at time: TimeInterval? = nil, inNavigationView: Bool = false) {
        playNow(video, at: time)

        guard !playingInPictureInPicture else {
            return
        }

        if inNavigationView {
            playerNavigationLinkActive = true
        } else {
            show()
        }
    }

    func playStream(
        _ stream: Stream,
        of video: Video,
        preservingTime: Bool = false,
        upgrading: Bool = false
    ) {
        playerError = nil
        if !upgrading {
            resetSegments()

            DispatchQueue.main.async { [weak self] in
                self?.sponsorBlock.loadSegments(
                    videoID: video.videoID,
                    categories: Defaults[.sponsorBlockCategories]
                )
            }
        }

        if let url = stream.singleAssetURL {
            logger.info("playing stream with one asset\(stream.kind == .hls ? " (HLS)" : ""): \(url)")
            loadSingleAsset(url, stream: stream, of: video, preservingTime: preservingTime)
        } else {
            logger.info("playing stream with many assets:")
            logger.info("composition audio asset: \(stream.audioAsset.url)")
            logger.info("composition video asset: \(stream.videoAsset.url)")

            loadComposition(stream, of: video, preservingTime: preservingTime)
        }

        if !upgrading {
            updateCurrentArtwork()
        }
    }

    func upgradeToStream(_ stream: Stream) {
        if !self.stream.isNil, self.stream != stream {
            playStream(stream, of: currentVideo!, preservingTime: true, upgrading: true)
        }
    }

    private func handleAvailableStreamsChange() {
        rebuildTVMenu()

        guard stream.isNil else {
            return
        }

        guard let stream = preferredStream(availableStreams) else {
            return
        }

        streamSelection = stream
        playStream(
            stream,
            of: currentVideo!,
            preservingTime: !currentItem.playbackTime.isNil
        )
    }

    private func handlePresentationChange() {
        if presentingPlayer, closePiPOnOpeningPlayer, playingInPictureInPicture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.closePiP()
            }
        }

        if !presentingPlayer, pauseOnHidingPlayer, !playingInPictureInPicture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.pause()
            }
        }

        if !presentingPlayer, !pauseOnHidingPlayer, isPlaying {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.play()
            }
        }
    }

    private func handleNavigationViewPlayerPresentationChange() {
        if pauseOnHidingPlayer, !playingInPictureInPicture, !playerNavigationLinkActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.pause()
            }
        }
    }

    private func insertPlayerItem(
        _ stream: Stream,
        for video: Video,
        preservingTime: Bool = false
    ) {
        removeItemDidPlayToEndTimeObserver()

        playerItem = playerItem(stream)
        guard playerItem != nil else {
            return
        }

        addItemDidPlayToEndTimeObserver()
        attachMetadata(to: playerItem!, video: video, for: stream)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else {
                return
            }

            self.stream = stream
            self.composition = AVMutableComposition()
            self.asset = nil
        }

        let startPlaying = {
            #if !os(macOS)
                try? AVAudioSession.sharedInstance().setActive(true)
            #endif

            if self.isAutoplaying(self.playerItem!) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self = self else {
                        return
                    }

                    if !preservingTime,
                       let segment = self.sponsorBlock.segments.first,
                       segment.start < 3,
                       self.lastSkipped.isNil
                    {
                        self.player.seek(
                            to: segment.endTime,
                            toleranceBefore: .secondsInDefaultTimescale(1),
                            toleranceAfter: .zero
                        ) { finished in
                            guard finished else {
                                return
                            }

                            self.lastSkipped = segment
                            self.play()
                        }
                    } else {
                        self.play()
                    }
                }
            }
        }

        let replaceItemAndSeek = {
            guard video == self.currentVideo else {
                return
            }
            self.player.replaceCurrentItem(with: self.playerItem)
            self.seekToPreservedTime { finished in
                guard finished else {
                    return
                }
                self.preservedTime = nil

                startPlaying()
            }
        }

        if preservingTime {
            if preservedTime.isNil {
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

    private func loadSingleAsset(
        _ url: URL,
        stream: Stream,
        of video: Video,
        preservingTime: Bool = false
    ) {
        asset?.cancelLoading()
        asset = AVURLAsset(url: url)
        asset?.loadValuesAsynchronously(forKeys: Self.assetKeysToLoad) { [weak self] in
            var error: NSError?

            switch self?.asset?.statusOfValue(forKey: "duration", error: &error) {
            case .loaded:
                DispatchQueue.main.async { [weak self] in
                    self?.insertPlayerItem(stream, for: video, preservingTime: preservingTime)
                }
            case .failed:
                DispatchQueue.main.async { [weak self] in
                    self?.playerError = error
                }
            default:
                return
            }
        }
    }

    private func loadComposition(
        _ stream: Stream,
        of video: Video,
        preservingTime: Bool = false
    ) {
        loadedCompositionAssets = []
        loadCompositionAsset(stream.audioAsset, stream: stream, type: .audio, of: video, preservingTime: preservingTime)
        loadCompositionAsset(stream.videoAsset, stream: stream, type: .video, of: video, preservingTime: preservingTime)
    }

    private func loadCompositionAsset(
        _ asset: AVURLAsset,
        stream: Stream,
        type: AVMediaType,
        of video: Video,
        preservingTime: Bool = false
    ) {
        asset.loadValuesAsynchronously(forKeys: Self.assetKeysToLoad) { [weak self] in
            guard let self = self else {
                return
            }
            self.logger.info("loading \(type.rawValue) track")

            let assetTracks = asset.tracks(withMediaType: type)

            guard let compositionTrack = self.composition.addMutableTrack(
                withMediaType: type,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                self.logger.critical("composition \(type.rawValue) addMutableTrack FAILED")
                return
            }

            guard let assetTrack = assetTracks.first else {
                self.logger.critical("asset \(type.rawValue) track FAILED")
                return
            }

            try! compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: CMTime.secondsInDefaultTimescale(video.length)),
                of: assetTrack,
                at: .zero
            )

            self.logger.critical("\(type.rawValue) LOADED")

            guard self.streamSelection == stream else {
                self.logger.critical("IGNORING LOADED")
                return
            }

            self.loadedCompositionAssets.append(type)

            if self.loadedCompositionAssets.count == 2 {
                self.insertPlayerItem(stream, for: video, preservingTime: preservingTime)
            }
        }
    }

    private func playerItem(_: Stream) -> AVPlayerItem? {
        if let asset = asset {
            return AVPlayerItem(asset: asset)
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

        observePlayerItemStatus(item)
    }

    private func observePlayerItemStatus(_ item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.old, .new]) { [weak self] playerItem, _ in
            guard let self = self else {
                return
            }

            switch playerItem.status {
            case .readyToPlay:
                if self.isAutoplaying(playerItem) {
                    self.play()
                }
            case .failed:
                self.playerError = item.error

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
            object: playerItem
        )
    }

    private func removeItemDidPlayToEndTimeObserver() {
        NotificationCenter.default.removeObserver(
            self,
            name: NSNotification.Name.AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
    }

    @objc func itemDidPlayToEndTime() {
        prepareCurrentItemForHistory(finished: true)

        if queue.isEmpty {
            #if !os(macOS)
                try? AVAudioSession.sharedInstance().setActive(false)
            #endif
            resetQueue()
            #if os(tvOS)
                controller?.playerView.dismiss(animated: false) { [weak self] in
                    self?.controller?.dismiss(animated: true)
                }
            #endif
        } else {
            advanceToNextItem()
        }
    }

    private func saveTime(completionHandler: @escaping () -> Void = {}) {
        let currentTime = player.currentTime()

        guard currentTime.seconds > 0 else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.preservedTime = currentTime
            completionHandler()
        }
    }

    private func seekToPreservedTime(completionHandler: @escaping (Bool) -> Void = { _ in }) {
        guard let time = preservedTime else {
            return
        }

        player.seek(
            to: time,
            toleranceBefore: .secondsInDefaultTimescale(1),
            toleranceAfter: .zero,
            completionHandler: completionHandler
        )
    }

    private func addFrequentTimeObserver() {
        let interval = CMTime.secondsInDefaultTimescale(0.5)

        frequentTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else {
                return
            }

            guard !self.currentItem.isNil else {
                return
            }

            #if !os(tvOS)
                self.updateNowPlayingInfo()
            #endif

            self.handleSegments(at: self.player.currentTime())
        }
    }

    private func addInfrequentTimeObserver() {
        let interval = CMTime.secondsInDefaultTimescale(5)

        infrequentTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else {
                return
            }

            guard !self.currentItem.isNil else {
                return
            }

            self.timeObserverThrottle.execute {
                self.updateWatch()
            }
        }
    }

    private func addPlayerTimeControlStatusObserver() {
        playerTimeControlStatusObserver = player.observe(\.timeControlStatus) { [weak self] player, _ in
            guard let self = self,
                  self.player == player
            else {
                return
            }

            if player.timeControlStatus != .waitingToPlayAtSpecifiedRate {
                self.objectWillChange.send()
            }

            if player.timeControlStatus == .playing, player.rate != self.currentRate {
                player.rate = self.currentRate
            }

            #if os(macOS)
                if player.timeControlStatus == .playing {
                    ScreenSaverManager.shared.disable(reason: "Yattee is playing video")
                } else {
                    ScreenSaverManager.shared.enable()
                }
            #endif

            self.timeObserverThrottle.execute {
                self.updateWatch()
            }
        }
    }

    fileprivate func updateNowPlayingInfo() {
        var nowPlayingInfo: [String: AnyObject] = [
            MPMediaItemPropertyTitle: currentItem.video.title as AnyObject,
            MPMediaItemPropertyArtist: currentItem.video.author as AnyObject,
            MPNowPlayingInfoPropertyIsLiveStream: currentItem.video.live as AnyObject,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds as AnyObject,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count as AnyObject,
            MPMediaItemPropertyMediaType: MPMediaType.anyVideo.rawValue as AnyObject
        ]

        if !currentArtwork.isNil {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = currentArtwork as AnyObject
        }

        if !currentItem.video.live {
            let itemDuration = currentItem.videoDuration ?? currentItem.duration
            let duration = itemDuration.isFinite ? Double(itemDuration) : nil

            if !duration.isNil {
                nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration as AnyObject
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    private func updateCurrentArtwork() {
        guard let thumbnailData = try? Data(contentsOf: currentItem.video.thumbnailURL(quality: .medium)!) else {
            return
        }

        #if os(macOS)
            let image = NSImage(data: thumbnailData)
        #else
            let image = UIImage(data: thumbnailData)
        #endif

        if image.isNil {
            return
        }

        currentArtwork = MPMediaItemArtwork(boundsSize: image!.size) { _ in image! }
    }

    func rateLabel(_ rate: Float) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2

        return "\(formatter.string(from: NSNumber(value: rate))!)×"
    }

    func closeCurrentItem() {
        prepareCurrentItemForHistory()
        currentItem = nil
        player.replaceCurrentItem(with: nil)
    }

    func closePiP() {
        guard playingInPictureInPicture else {
            return
        }

        let wasPlaying = isPlaying
        pause()

        #if os(tvOS)
            show()
        #endif

        doClosePiP(wasPlaying: wasPlaying)
    }

    #if os(tvOS)
        private func doClosePiP(wasPlaying: Bool) {
            let item = player.currentItem
            let time = player.currentTime()

            self.player.replaceCurrentItem(with: nil)

            guard !item.isNil else {
                return
            }

            self.player.seek(to: time)
            self.player.replaceCurrentItem(with: item)

            guard wasPlaying else {
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.play()
            }
        }
    #else
        private func doClosePiP(wasPlaying: Bool) {
            controller?.playerView.player = nil
            controller?.playerView.player = player

            guard wasPlaying else {
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.play()
            }
        }
    #endif

    func handleCurrentItemChange() {
        #if os(macOS)
            Windows.player.window?.title = windowTitle
        #endif

        Defaults[.lastPlayed] = currentItem
    }

    #if os(macOS)
        var windowTitle: String {
            currentVideo.isNil ? "Not playing" : "\(currentVideo!.title) - \(currentVideo!.author)"
        }
    #else
        func handleEnterForeground() {
            guard closePiPAndOpenPlayerOnEnteringForeground, playingInPictureInPicture else {
                return
            }

            show()
            closePiP()
        }

        func enterFullScreen() {
            guard !playingFullscreen else {
                return
            }

            logger.info("entering fullscreen")

            controller?.playerView
                .perform(NSSelectorFromString("enterFullScreenAnimated:completionHandler:"), with: false, with: nil)
        }

        func exitFullScreen() {
            guard playingFullscreen else {
                return
            }

            logger.info("exiting fullscreen")

            controller?.playerView
                .perform(NSSelectorFromString("exitFullScreenAnimated:completionHandler:"), with: false, with: nil)
        }
    #endif
}
