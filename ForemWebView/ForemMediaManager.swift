import UIKit
import AVKit
import MediaPlayer

class ForemMediaManager: NSObject {

    weak var webView: ForemWebView?

    var avPlayer: AVPlayer?
    var playerItem: AVPlayerItem?
    var currentStreamURL: String?
    weak var avPlayerController: AVPlayerViewController?

    var periodicTimeObserver: Any?
    var videoPauseObserver: Any?

    var episodeName: String?
    var podcastName: String?
    var podcastRate: Float?
    var podcastVolume: Float?
    var podcastImageUrl: String?
    var podcastImageFetched: Bool = false

    lazy var bundleIcon: UIImage? = {
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
           let lastIcon = iconFiles.last {
            return UIImage(named: lastIcon)
        }
        return nil
    }()

    init(webView: ForemWebView) {
        self.webView = webView
    }

    internal func handleVideoMessage(_ message: [String: String]) {
        switch message["action"] {
        case "play":
            loadVideoPlayer(videoUrl: message["url"], seconds: message["seconds"])
        default: ()
        }
    }

    internal func handlePodcastMessage(_ message: [String: String]) {
        ensureAudioSessionIsActive()

        switch message["action"] {
        case "play":
            play(audioUrl: message["url"], at: message["seconds"])
        case "load":
            load(audioUrl: message["url"])
        case "seek":
            seek(to: message["seconds"])
        case "rate":
            podcastRate = Float(message["rate"] ?? "1")
            avPlayer?.rate = podcastRate ?? 1
        case "muted":
            avPlayer?.isMuted = (message["muted"] == "true")
        case "pause":
            avPlayer?.pause()
        case "terminate":
            avPlayer?.pause()
            clearObservers()
            UIApplication.shared.endReceivingRemoteControlEvents()
        case "volume":
            podcastVolume = Float(message["volume"] ?? "1")
            avPlayer?.rate = podcastVolume ?? 1
        case "metadata":
            loadMetadata(from: message)
        default: ()
        }
    }

    internal func clearObservers() {
        currentStreamURL = nil
        periodicTimeObserver = nil
        videoPauseObserver = nil
    }

    internal func ensureAudioSessionIsActive() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session as Active")
        }
    }

    // MARK: - Video Action Functions -

    internal func loadVideoPlayer(videoUrl: String?, seconds: String?) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            // TODO: Improve unsupported devices experience
            return
        }

        if currentStreamURL != videoUrl, let videoUrl = videoUrl, let url = NSURL(string: videoUrl) {
            clearObservers()
            self.webView?.closePodcastUI()
            currentStreamURL = videoUrl
            playerItem = AVPlayerItem.init(url: url as URL)
            avPlayer = AVPlayer.init(playerItem: playerItem)
            avPlayer?.volume = 1.0
            seek(to: seconds)
            avPlayer?.play()
            startVideoTimeObserver()

            var avPlayerControllerReference = self.avPlayerController
            if avPlayerControllerReference == nil {
                avPlayerControllerReference = AVPlayerViewController()
                avPlayerControllerReference?.allowsPictureInPicturePlayback = true
                avPlayerControllerReference?.delegate = self
                videoPauseObserver = avPlayer?.observe(\.rate, options: .new) { (player, _) in
                    if player.rate == 0 {
                        self.webView?.sendBridgeMessage(type: "video", message: [ "action": "pause" ])
                    }
                }

                // Keep weak reference
                self.avPlayerController = avPlayerControllerReference
            } else {
                self.webView?.closePodcastUI()
            }

            avPlayerController?.player = avPlayer
            self.webView?.foremWebViewDelegate?.willStartNativeVideo(playerController: avPlayerControllerReference!)
        }
    }

    // MARK: - Podcast Action Functions -

    internal func play(audioUrl: String?, at seconds: String?) {
        var seconds = Double(seconds ?? "0")
        if currentStreamURL != audioUrl && audioUrl != nil {
            avPlayer?.pause()
            seconds = 0
            currentStreamURL = nil
            load(audioUrl: audioUrl)
        }

        guard avPlayer?.timeControlStatus != .playing else { return }
        avPlayer?.seek(to: CMTime(seconds: seconds ?? 0, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
        avPlayer?.play()
        avPlayer?.rate = podcastRate ?? 1
        updateNowPlayingInfoCenter()
        setupNowPlayingInfoCenter()
    }

    internal func seek(to seconds: String?) {
        guard let secondsStr = seconds, let seconds = Double(secondsStr) else { return }
        avPlayer?.seek(to: CMTime(seconds: seconds, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
    }

    internal func seekForward(_ sender: Any) {
        guard let duration  = avPlayer?.currentItem?.duration else { return }
        let playerCurrentTime = CMTimeGetSeconds(avPlayer!.currentTime())
        let newTime = playerCurrentTime + 15

        if newTime < (CMTimeGetSeconds(duration) - 15) {
            avPlayer!.seek(to: seekableTime(newTime), toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero)
        }
    }

    internal func seekBackward(_ sender: Any) {
        let playerCurrentTime = CMTimeGetSeconds(avPlayer!.currentTime())
        var newTime = playerCurrentTime - 15
        if newTime < 0 {
            newTime = 0
        }
        avPlayer!.seek(to: seekableTime(newTime), toleranceBefore: CMTime.zero, toleranceAfter: CMTime.zero)
    }

    internal func seekableTime(_ seconds: Double) -> CMTime {
        return CMTimeMake(value: Int64(seconds * 1000 as Float64), timescale: 1000)
    }

    internal func loadMetadata(from message: [String: String]) {
        episodeName = message["episodeName"]
        podcastName = message["podcastName"]
        if let newImageUrl = message["podcastImageUrl"], newImageUrl != podcastImageUrl {
            podcastImageUrl = newImageUrl
            podcastImageFetched = false
        }
    }

    internal func updateTimeLabel(currentTime: Double, duration: Double) {
        guard currentTime > 0 && duration > 0 else {
            webView?.sendBridgeMessage(type: "podcast", message: ["action": "init"])
            return
        }

        let message = [
            "action": "tick",
            "duration": String(format: "%.4f", duration),
            "currentTime": String(format: "%.4f", currentTime)
        ]
        webView?.sendBridgeMessage(type: "podcast", message: message)
    }

    internal func videoTick(currentTime: Double) {
        let message = [
            "action": "tick",
            "currentTime": String(format: "%.4f", currentTime)
        ]
        webView?.sendBridgeMessage(type: "podcast", message: message)
    }

    internal func load(audioUrl: String?) {
        guard currentStreamURL != audioUrl && audioUrl != nil else { return }
        guard let url = NSURL(string: audioUrl!) else { return }
        clearObservers()
        currentStreamURL = audioUrl
        playerItem = AVPlayerItem.init(url: url as URL)
        avPlayer = AVPlayer.init(playerItem: playerItem)
        avPlayer?.volume = 1.0
        updateTimeLabel(currentTime: 0, duration: 0)

        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        periodicTimeObserver = avPlayer?.addPeriodicTimeObserver(forInterval: interval,
                                                                 queue: DispatchQueue.main) { [weak self] _ in
            guard let duration = self?.playerItem?.duration.seconds, !duration.isNaN else { return }
            let time: Double = self?.avPlayer?.currentTime().seconds ?? 0

            self?.updateTimeLabel(currentTime: time, duration: duration)
            self?.updateNowPlayingInfoCenter()
        }
    }

    internal func startVideoTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        periodicTimeObserver = avPlayer?.addPeriodicTimeObserver(forInterval: interval,
                                                                 queue: DispatchQueue.main) { [weak self] _ in
            guard self?.avPlayerController != nil else {
                self?.clearObservers()
                return
            }

            guard self?.avPlayer?.rate != 0 && self?.avPlayer?.error == nil else { return }
            guard let time: Double = self?.avPlayer?.currentTime().seconds else { return }
            let message = [
                "action": "tick",
                "currentTime": String(format: "%.4f", time)
            ]
            self?.webView?.sendBridgeMessage(type: "video", message: message)
        }
    }
}

// MARK: - AVPlayerViewControllerDelegate -

extension ForemMediaManager: AVPlayerViewControllerDelegate {
    func playerViewControllerWillStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        self.webView?.foremWebViewDelegate?.willStartNativeVideo(playerController: playerViewController)
    }
}
