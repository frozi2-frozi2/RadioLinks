import AppKit
import AVFoundation
import CoreAudio
import MediaPlayer
import SwiftUI

private func isYouTubeURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
}

private func isSupportedStreamURL(_ value: String) -> Bool {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          url.host != nil, !isYouTubeURL(url) else { return false }
    return true
}

private enum PlaylistError: LocalizedError {
    case httpStatus(Int)
    case noStreamURL

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "Сервер плейлиста ответил HTTP \(code)."
        case .noStreamURL: return "В плейлисте не найден адрес радиопотока."
        }
    }
}

private struct ResolvedRadioStream {
    let url: URL
    let mimeTypeOverride: String?
}

struct StreamMetadata: Sendable {
    var stationName: String?
    var genre: String?
    var artist: String?
    var trackTitle: String?
    var album: String?
    var bitrateKbps: Int?
    var sampleRateHz: Int?
    var channelCount: Int?
    var codec: String?
    var durationSeconds: Int?
    var websiteURL: URL?
    var streamURL: URL?

    var isEmpty: Bool {
        stationName == nil && genre == nil && artist == nil && trackTitle == nil &&
            bitrateKbps == nil && sampleRateHz == nil && codec == nil && websiteURL == nil
    }

    mutating func merge(_ newer: StreamMetadata) {
        if newer.stationName != nil { stationName = newer.stationName }
        if newer.genre != nil { genre = newer.genre }
        if newer.artist != nil { artist = newer.artist }
        if newer.trackTitle != nil { trackTitle = newer.trackTitle }
        if newer.album != nil { album = newer.album }
        if newer.bitrateKbps != nil { bitrateKbps = newer.bitrateKbps }
        if newer.sampleRateHz != nil { sampleRateHz = newer.sampleRateHz }
        if newer.channelCount != nil { channelCount = newer.channelCount }
        if newer.codec != nil { codec = newer.codec }
        if newer.durationSeconds != nil { durationSeconds = newer.durationSeconds }
        if newer.websiteURL != nil { websiteURL = newer.websiteURL }
        if newer.streamURL != nil { streamURL = newer.streamURL }
    }
}

/// Reads ICY response headers and the first interleaved metadata block, then
/// cancels its short-lived request so it doesn't download the radio stream.
private final class IcyMetadataProbe: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completion: ((StreamMetadata) -> Void)?
    private var metadata = StreamMetadata()
    private var audioBytesRemaining = 0
    private var metadataBlockRemaining: Int?
    private var metadataBlock = Data()
    private var metaInterval = 0
    private var finished = false

    static func read(from url: URL) async -> StreamMetadata {
        let probe = IcyMetadataProbe()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                probe.start(url: url) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            probe.cancel()
        }
    }

    private func start(url: URL, completion: @escaping (StreamMetadata) -> Void) {
        self.completion = completion
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("close", forHTTPHeaderField: "Connection")
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    private func cancel() { finish() }

    private func finish() {
        guard !finished else { return }
        finished = true
        let callback = completion
        completion = nil
        callback?(metadata)
        session?.invalidateAndCancel()
        session = nil
        task = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish()
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            finish()
            return
        }

        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String else { return }
            result[key.lowercased()] = String(describing: pair.value)
        }
        metadata.stationName = headers["icy-name"]
        metadata.genre = headers["icy-genre"]
        metadata.websiteURL = headers["icy-url"].flatMap(URL.init(string:))
        metadata.bitrateKbps = headers["icy-br"].flatMap(Int.init)
            ?? Self.integerValue(named: "ice-bitrate", in: headers["icy-audio-info"])
        metadata.sampleRateHz = headers["icy-sr"].flatMap(Int.init)
            ?? Self.integerValue(named: "ice-samplerate", in: headers["icy-audio-info"])
        metadata.channelCount = Self.integerValue(named: "ice-channels", in: headers["icy-audio-info"])
        metadata.codec = Self.codecName(headers["content-type"])
        metadata.streamURL = response.url

        if let interval = headers["icy-metaint"].flatMap(Int.init), interval > 0 {
            metaInterval = interval
            audioBytesRemaining = interval
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
            finish()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            if audioBytesRemaining > 0 {
                let count = min(audioBytesRemaining, bytes.count - index)
                audioBytesRemaining -= count
                index += count
                continue
            }

            if metadataBlockRemaining == nil {
                let blockLength = Int(bytes[index]) * 16
                index += 1
                if blockLength == 0 {
                    audioBytesRemaining = metaInterval
                    continue
                }
                metadataBlockRemaining = blockLength
                metadataBlock.removeAll(keepingCapacity: true)
            }

            guard let remaining = metadataBlockRemaining else { continue }
            let count = min(remaining, bytes.count - index)
            metadataBlock.append(contentsOf: bytes[index..<(index + count)])
            metadataBlockRemaining = remaining - count
            index += count

            if metadataBlockRemaining == 0 {
                Self.applyMetadataBlock(metadataBlock, to: &metadata)
                if metadata.artist != nil || metadata.trackTitle != nil || metadata.websiteURL != nil {
                    finish()
                    return
                }
                audioBytesRemaining = metaInterval
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish()
    }

    private static func integerValue(named key: String, in value: String?) -> Int? {
        guard let value else { return nil }
        for component in value.split(separator: ";") {
            let pair = component.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == key {
                return Int(pair[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func codecName(_ contentType: String?) -> String? {
        guard let contentType = contentType?.lowercased() else { return nil }
        if contentType.contains("mpeg") { return "MP3" }
        if contentType.contains("aac") { return "AAC" }
        if contentType.contains("mp4") { return "AAC" }
        if contentType.contains("ogg") { return "Ogg" }
        if contentType.contains("mpegurl") || contentType.contains("m3u8") { return "HLS" }
        return nil
    }

    private static func applyMetadataBlock(_ data: Data, to metadata: inout StreamMetadata) {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\0", with: "")
        guard let regex = try? NSRegularExpression(pattern: "([A-Za-z0-9]+)='([^']*)'") else { return }
        let nsText = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) where match.numberOfRanges == 3 {
            let key = nsText.substring(with: match.range(at: 1)).lowercased()
            let value = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "streamtitle", !value.isEmpty {
                if let separator = value.range(of: " - ") {
                    metadata.artist = String(value[..<separator.lowerBound])
                    metadata.trackTitle = String(value[separator.upperBound...])
                } else {
                    metadata.trackTitle = value
                }
            } else if key == "streamurl", let url = URL(string: value) {
                metadata.websiteURL = url
            }
        }
    }
}

@MainActor
final class RadioController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var links: [String] = {
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: "radioStreamURLs") ?? defaults.stringArray(forKey: "youtubeLinks") ?? []
        return saved.filter(isSupportedStreamURL)
    }()
    @Published var currentIndex: Int? = nil
    @Published var isPlaying = false
    @Published var status = "Добавьте прямую ссылку на радиопоток"
    @Published var streamMetadata = StreamMetadata()

    private var player: AVPlayer?
    private var playerStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var generation = 0
    private var editorWindow: NSWindow?
    private var metadataTask: Task<Void, Never>?
    private var lastOutputDevice: AudioDeviceID = 0
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?

    override init() {
        super.init()
        configureRemoteCommands()
        observeDefaultOutputDevice()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPlaying else { return }
                self.toggle()
            }
            return .success
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.toggle()
            }
            return .success
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        // Some headsets report the backward gesture as skip-backward instead
        // of previous-track. For live radio, both commands mean the prior URL.
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
    }

    private func observeDefaultOutputDevice() {
        lastOutputDevice = Self.defaultOutputDeviceID()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.defaultOutputDeviceDidChange() }
        }
        defaultOutputListener = listener
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener
        )
    }

    private func defaultOutputDeviceDidChange() {
        let previousDevice = lastOutputDevice
        let currentDevice = Self.defaultOutputDeviceID()
        guard currentDevice != previousDevice else { return }
        lastOutputDevice = currentDevice

        if isPlaying && Self.isHeadphoneOutput(previousDevice) {
            player?.pause()
            isPlaying = false
            status = "Пауза: наушники отключены"
            updateNowPlayingInfo()
        }
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    private static func isHeadphoneOutput(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let transportStatus = AudioObjectGetPropertyData(
            deviceID, &transportAddress, 0, nil, &size, &transport
        )
        if transportStatus == noErr &&
            (transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE) {
            return true
        }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameStatus = AudioObjectGetPropertyData(
            deviceID, &nameAddress, 0, nil, &size, &name
        )
        guard nameStatus == noErr, let deviceName = name?.takeUnretainedValue() as String? else { return false }
        let normalized = deviceName.lowercased()
        return ["airpods", "headphone", "headset", "earbud", "buds", "наушник"].contains {
            normalized.contains($0)
        }
    }

    private func updateNowPlayingInfo() {
        guard currentIndex != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: streamMetadata.trackTitle ?? currentTitle,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artist = streamMetadata.artist { info[MPMediaItemPropertyArtist] = artist }
        if let station = streamMetadata.stationName { info[MPMediaItemPropertyAlbumTitle] = station }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    var currentTitle: String {
        guard let currentIndex, links.indices.contains(currentIndex) else { return "Radio Links" }
        return URL(string: links[currentIndex])?.host ?? "Radio Stream"
    }

    func saveLinks() {
        links = links.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return isSupportedStreamURL(trimmed) ? trimmed : nil
        }
        UserDefaults.standard.set(links, forKey: "radioStreamURLs")
        if let currentIndex, currentIndex >= links.count { stop() }
    }

    func toggle() {
        if isPlaying { player?.pause(); isPlaying = false; status = "Пауза" }
        else if let player { player.play(); isPlaying = true; status = "Воспроизведение" }
        else if !links.isEmpty { play(at: currentIndex ?? 0) }
        updateNowPlayingInfo()
    }

    func stop() {
        generation += 1
        metadataTask?.cancel(); metadataTask = nil
        streamMetadata = StreamMetadata()
        player?.pause(); player = nil
        playerStatusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        isPlaying = false; currentIndex = nil; status = "Остановлено"
        updateNowPlayingInfo()
    }

    func play(at index: Int) {
        guard links.indices.contains(index) else { return }
        generation += 1
        let request = generation
        metadataTask?.cancel(); metadataTask = nil
        streamMetadata = StreamMetadata()
        currentIndex = index; isPlaying = false; status = "Открываю ссылку…"
        updateNowPlayingInfo()
        player?.pause(); player = nil
        playerStatusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        guard let linkURL = URL(string: links[index]), isSupportedStreamURL(links[index]) else {
            status = "Введите URL радиопотока или плейлиста."
            return
        }
        Task { [weak self] in
            do {
                let stream = try await Self.resolveStreamURL(from: linkURL)
                guard let self, self.generation == request else { return }
                self.streamMetadata.streamURL = stream.url
                var assetOptions: [String: Any] = [:]
                if #available(macOS 14.0, *), let mimeType = stream.mimeTypeOverride {
                    assetOptions[AVURLAssetOverrideMIMETypeKey] = mimeType
                }
                let asset = AVURLAsset(url: stream.url, options: assetOptions)
                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                self.player = player
                self.playerStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.generation == request else { return }
                        switch item.status {
                        case .readyToPlay:
                            self.status = "Воспроизведение"
                            self.isPlaying = true
                            self.updateNowPlayingInfo()
                        case .failed:
                            let error = item.error as NSError?
                            let reason = error?.localizedDescription ?? "Поток недоступен."
                            self.status = "Ошибка потока: \(reason)"
                            self.isPlaying = false
                            self.player = nil
                            self.playerStatusObservation = nil
                            self.updateNowPlayingInfo()
                        default:
                            break
                        }
                    }
                }
                self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, let current = self.currentIndex else { return }
                        if current + 1 < self.links.count { self.play(at: current + 1) } else { self.stop() }
                    }
                }
                player.play()
                self.startMetadataUpdates(for: stream.url, generation: request)
            } catch {
                guard let self, self.generation == request else { return }
                self.status = "Ошибка ссылки: \(error.localizedDescription)"
            }
        }

    }

    private func startMetadataUpdates(for streamURL: URL, generation request: Int) {
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            while !Task.isCancelled {
                let icy = await IcyMetadataProbe.read(from: streamURL)
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.streamMetadata.merge(icy)
                self.updateNowPlayingInfo()
                if let stationSlug = Self.lautFMSlug(from: icy.websiteURL ?? streamURL),
                   let lautFM = await Self.fetchLautFMMetadata(stationSlug: stationSlug) {
                    guard !Task.isCancelled, self.generation == request else { return }
                    self.streamMetadata.merge(lautFM)
                    self.updateNowPlayingInfo()
                }
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
            }
        }
    }

    private static func lautFMSlug(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host == "laut.fm", let slug = url.pathComponents.dropFirst().last, slug != "/" { return slug }
        if host.hasSuffix(".stream.laut.fm") {
            let slug = String(host.dropLast(".stream.laut.fm".count))
            return slug.isEmpty ? nil : slug
        }
        return nil
    }

    private static func fetchLautFMMetadata(stationSlug: String) async -> StreamMetadata? {
        guard let url = URL(string: "https://api.laut.fm/station/\(stationSlug)/current_song") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result = StreamMetadata()
        result.trackTitle = root["title"] as? String
        result.album = root["album"] as? String
        result.durationSeconds = root["length"] as? Int
        if let artist = root["artist"] as? [String: Any] { result.artist = artist["name"] as? String }
        if result.websiteURL == nil { result.websiteURL = URL(string: "https://laut.fm/\(stationSlug)") }
        return result
    }

    private static func resolveStreamURL(from linkURL: URL) async throws -> ResolvedRadioStream {
        let ext = linkURL.pathExtension.lowercased()
        guard ext == "pls" || ext == "m3u" else {
            return ResolvedRadioStream(url: linkURL, mimeTypeOverride: audioMIMEOverride(for: linkURL))
        }

        var request = URLRequest(url: linkURL)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PlaylistError.httpStatus(http.statusCode)
        }

        let text = String(decoding: data, as: UTF8.self)
        let candidates: [String]
        if ext == "pls" {
            candidates = text.split(whereSeparator: \.isNewline).compactMap { line in
                let fields = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2,
                      fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        .range(of: "^file[0-9]+$", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
                return fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\\\"'"))
            }
        } else {
            candidates = text.split(whereSeparator: \.isNewline).compactMap { line in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty || value.hasPrefix("#") ? nil : value
            }
        }

        for candidate in candidates {
            guard let streamURL = URL(string: candidate, relativeTo: linkURL)?.absoluteURL,
                  isSupportedStreamURL(streamURL.absoluteString),
                  !["pls", "m3u"].contains(streamURL.pathExtension.lowercased()) else { continue }
            return ResolvedRadioStream(url: streamURL, mimeTypeOverride: audioMIMEOverride(for: streamURL))
        }
        throw PlaylistError.noStreamURL
    }

    private static func audioMIMEOverride(for url: URL) -> String? {
        let path = url.path.lowercased()
        if url.pathExtension.lowercased() == "mp3" || path.hasSuffix("_mp3") { return "audio/mpeg" }
        if url.pathExtension.lowercased() == "aac" || path.hasSuffix("_aac") { return "audio/aac" }
        if ["m4a", "mp4"].contains(url.pathExtension.lowercased()) { return "audio/mp4" }
        return nil
    }

    func showEditor() {
        if let editorWindow {
            editorWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Радиопотоки"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 620, height: 420)
        window.contentMaxSize = NSSize(width: 620, height: 420)
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: LinkEditor(radio: self, onClose: { [weak self] in self?.hideEditor() }))
        window.center()
        editorWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideEditor() {
        editorWindow?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func next() { guard !links.isEmpty else { return }; play(at: ((currentIndex ?? -1) + 1) % links.count) }
    func previous() { guard !links.isEmpty else { return }; play(at: ((currentIndex ?? 0) - 1 + links.count) % links.count) }

}

@main
struct RadioLinksApp: App {
    @StateObject private var radio = RadioController()

    var body: some Scene {
        MenuBarExtra {
            OperatorInterface(radio: radio)
        } label: {
            Image(systemName: radio.isPlaying ? "dot.radiowaves.left.and.right" : "radio")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The operator-facing menu is kept separate from the playback controller so
/// playback implementation changes don't require rebuilding this view.
private struct OperatorInterface: View {
    @ObservedObject var radio: RadioController
    @State private var controlsRowWidth: CGFloat = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(radio.currentIndex.map { radio.links.indices.contains($0) ? radio.links[$0] : "Radio Links" } ?? "Radio Links")
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 444, alignment: .leading)
            if radio.status == "Добавьте прямую ссылку на радиопоток",
               let streamURL = URL(string: "https://streamurl.link/") {
                Link("https://streamurl.link/", destination: streamURL)
                    .font(.caption).lineLimit(2).frame(maxWidth: 444, alignment: .leading)
            } else {
                Text(radio.status).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 444, alignment: .leading)
            }
            if radio.currentIndex != nil {
                StreamMetadataPanel(metadata: radio.streamMetadata)
            }
            HStack(spacing: 3) {
                Button { radio.previous() } label: { Image(systemName: "backward.end.fill") }
                    .help("Предыдущий источник")
                    .disabled(radio.links.isEmpty)
                Button { radio.toggle() } label: { Image(systemName: radio.isPlaying ? "pause.fill" : "play.fill") }
                    .help(radio.isPlaying ? "Пауза" : "Воспроизвести")
                    .disabled(radio.links.isEmpty)
                Button { radio.next() } label: { Image(systemName: "forward.end.fill") }
                    .help("Следующий источник")
                    .disabled(radio.links.isEmpty)
                Button("Выход") { NSApplication.shared.terminate(nil) }
                    .font(.system(size: 14, weight: .semibold))
                    .keyboardShortcut("q")
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ControlsRowWidthKey.self, value: geometry.size.width)
                }
            }
            Button {
                radio.showEditor()
            } label: {
                Text("Список воспроизведения")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
                .font(.system(size: 14, weight: .semibold))
                .frame(width: controlsRowWidth, height: 40, alignment: .leading)
        }
        .padding(12)
        .onPreferenceChange(ControlsRowWidthKey.self) { width in
            if width > 0 { controlsRowWidth = width }
        }
    }
}

private struct ControlsRowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct StreamMetadataPanel: View {
    let metadata: StreamMetadata

    private var composition: String {
        switch (metadata.artist, metadata.trackTitle) {
        case let (artist?, title?): return "\(artist) — \(title)"
        case let (nil, title?): return title
        case let (artist?, nil): return artist
        default: return "Информация о композиции загружается…"
        }
    }

    private var technicalDetails: [String] {
        var values: [String] = []
        if let station = metadata.stationName { values.append("Станция: \(station)") }
        if let bitrate = metadata.bitrateKbps { values.append("\(bitrate) кбит/с") }
        if let codec = metadata.codec { values.append(codec) }
        if let sampleRate = metadata.sampleRateHz { values.append("\(sampleRate / 1000) кГц") }
        if let channels = metadata.channelCount { values.append(channels == 2 ? "Стерео" : "\(channels) кан.") }
        if let genre = metadata.genre { values.append(genre) }
        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(composition)
                .font(.subheadline.weight(.medium))
                .lineLimit(1).truncationMode(.middle)
            if let album = metadata.album, !album.isEmpty {
                Text("Альбом: \(album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !technicalDetails.isEmpty {
                Text(technicalDetails.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let websiteURL = metadata.websiteURL ?? metadata.streamURL {
                let label = metadata.websiteURL == nil ? "Адрес потока" : "Сайт станции"
                Link("\(label): \(websiteURL.host ?? websiteURL.absoluteString)", destination: websiteURL)
                    .font(.caption).lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: 444, alignment: .leading)
    }
}

struct LinkEditor: View {
    @ObservedObject var radio: RadioController
    let onClose: () -> Void
    @State private var newLink = ""
    @State private var validationMessage: String?
    @State private var selectedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Радиопотоки").font(.headline)
            HStack(spacing: 8) {
                VStack(spacing: 8) {
                    Button { moveSelection(by: -1) } label: { Image(systemName: "arrow.up") }
                        .help("Переместить источник вверх")
                        .disabled(selectedIndex == nil || selectedIndex == 0)
                    Button { moveSelection(by: 1) } label: { Image(systemName: "arrow.down") }
                        .help("Переместить источник вниз")
                        .disabled(selectedIndex == nil || selectedIndex == radio.links.count - 1)
                    Spacer(minLength: 0)
                }
                .buttonStyle(.borderless)
                .frame(width: 28)

                List(selection: $selectedIndex) {
                    ForEach(Array(radio.links.enumerated()), id: \.offset) { index, link in
                        HStack {
                            Text(link).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) {
                                radio.links.remove(at: index)
                                if let current = radio.currentIndex {
                                    if current == index { radio.stop() }
                                    else if current > index { radio.currentIndex = current - 1 }
                                }
                                if let selectedIndex {
                                    self.selectedIndex = radio.links.isEmpty ? nil : min(selectedIndex, radio.links.count - 1)
                                }
                                radio.saveLinks()
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        .tag(index)
                    }
                }
            }
            .frame(minHeight: 140, maxHeight: 260)
            HStack {
                TextField("URL потока или плейлиста (.pls / .m3u)", text: $newLink)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addLink)
                    .onChange(of: newLink) { _ in validationMessage = nil }
                Button("Добавить", action: addLink).disabled(newLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text("Поддерживаются потоки и плейлисты PLS/M3U.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Готово", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 580, height: 380)
    }

    private func addLink() {
        let value = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard isSupportedStreamURL(value) else {
            validationMessage = "Введите ссылку на поток или плейлист PLS/M3U, а не страницу станции."
            return
        }
        radio.links.append(value)
        radio.saveLinks()
        selectedIndex = radio.links.indices.last
        newLink = ""
        validationMessage = nil
    }

    private func moveSelection(by offset: Int) {
        guard let selectedIndex else { return }
        let destination = selectedIndex + offset
        guard radio.links.indices.contains(selectedIndex), radio.links.indices.contains(destination) else { return }
        radio.links.swapAt(selectedIndex, destination)
        if let current = radio.currentIndex {
            if current == selectedIndex { radio.currentIndex = destination }
            else if current == destination { radio.currentIndex = selectedIndex }
        }
        self.selectedIndex = destination
        radio.saveLinks()
    }
}
