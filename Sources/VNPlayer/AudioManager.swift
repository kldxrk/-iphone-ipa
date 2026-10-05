import AVFoundation

enum AudioOutcome {
    case playing
    case alreadyPlaying
    /// 格式本身 iOS 放不了（最典型的是 KiriKiri 游戏的 .ogg BGM）
    case unsupported(String)
    case failed(String)
}

final class AudioManager {
    /// AVFoundation 不支持的容器/编码。KiriKiri 游戏的 BGM 绝大多数是 Ogg Vorbis，
    /// 所以这里要给出明确原因，而不是丢一句"无法播放"。
    static let unsupportedExtensions: Set<String> = ["ogg", "oga", "opus", "wma", "spx"]

    private var bgmPlayer: AVAudioPlayer?
    private var sePlayers: [AVAudioPlayer] = []
    private(set) var currentBGM: String?

    var bgmVolume: Float = 0.7 {
        didSet { bgmPlayer?.volume = max(0, min(1, bgmVolume)) }
    }

    init() {
        configureSession()
    }

    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    /// 返回 nil 表示扩展名可以交给 AVFoundation 试；返回字符串表示已知放不了。
    static func unsupportedReason(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return unsupportedExtensions.contains(ext) ? ext : nil
    }

    @discardableResult
    func playBGM(url: URL, name: String) -> AudioOutcome {
        if currentBGM == name, bgmPlayer?.isPlaying == true { return .alreadyPlaying }
        if let ext = AudioManager.unsupportedReason(for: url) { return .unsupported(ext) }
        stopBGM()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = max(0, min(1, bgmVolume))
            player.prepareToPlay()
            player.play()
            bgmPlayer = player
            currentBGM = name
            return .playing
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func stopBGM() {
        bgmPlayer?.stop()
        bgmPlayer = nil
        currentBGM = nil
    }

    @discardableResult
    func playSE(url: URL) -> AudioOutcome {
        if let ext = AudioManager.unsupportedReason(for: url) { return .unsupported(ext) }
        sePlayers.removeAll { !$0.isPlaying }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 1.0
            player.play()
            sePlayers.append(player)
            return .playing
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
