//
//  DiscordIPC.swift
//  PlayTools
//
//  Created by 이승윤 on 2022/07/15.
//

import Darwin
import Foundation
import os.lock
import UIKit

/// Minimal POSIX AF_UNIX client for Discord's local IPC socket, replacing SwordRPC + SwiftNIO.
private final class POSIXDiscordIPCClient {
    private let appId: String
    private let socketPath: String
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var fd: Int32 = -1

    init(appId: String, socketPath: String) {
        self.appId = appId
        self.socketPath = socketPath
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        disconnect()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    @discardableResult
    func connect() -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if fd >= 0 {
            return true
        }
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            return false
        }

        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }

        var noSigPipe: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: sunPathCapacity) { cPtr in
                _ = socketPath.withCString { strlcpy(cPtr, $0, sunPathCapacity) }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(sock, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            Darwin.close(sock)
            return false
        }

        fd = sock
        guard sendFrameLocked(opcode: 0, object: ["v": 1, "client_id": appId]),
              readFrameLocked() else {
            closeLocked()
            return false
        }
        return true
    }

    func setActivity(_ activity: [String: Any]) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard fd >= 0 else { return }
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": Int(getpid()),
                "activity": activity
            ],
            "nonce": UUID().uuidString
        ]
        if !sendFrameLocked(opcode: 1, object: payload) {
            closeLocked()
        } else {
            _ = readFrameLocked()
        }
    }

    func disconnect() {
        os_unfair_lock_lock(lock)
        closeLocked()
        os_unfair_lock_unlock(lock)
    }

    private func closeLocked() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private func sendFrameLocked(opcode: UInt32, object: [String: Any]) -> Bool {
        guard fd >= 0,
              let jsonData = try? JSONSerialization.data(withJSONObject: object) else {
            return false
        }
        var header = [UInt8](repeating: 0, count: 8)
        let opLE = opcode.littleEndian
        let lenLE = UInt32(jsonData.count).littleEndian
        withUnsafeBytes(of: opLE) { header.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: lenLE) { header.replaceSubrange(4..<8, with: $0) }
        var frame = Data(header)
        frame.append(jsonData)

        return frame.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return false }
            var sent = 0
            while sent < frame.count {
                let n = Darwin.send(fd, base.advanced(by: sent), frame.count - sent, 0)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                sent += n
            }
            return true
        }
    }

    private func readFrameLocked() -> Bool {
        guard fd >= 0 else { return false }
        var header = [UInt8](repeating: 0, count: 8)
        guard readExactLocked(into: &header, count: 8) else { return false }
        let length = header.withUnsafeBytes { ptr -> UInt32 in
            UInt32(littleEndian: ptr.load(fromByteOffset: 4, as: UInt32.self))
        }
        guard length <= 1024 * 1024 else { return false }
        if length == 0 { return true }
        var sink = [UInt8](repeating: 0, count: Int(length))
        return readExactLocked(into: &sink, count: Int(length))
    }

    private func readExactLocked(into buffer: inout [UInt8], count: Int) -> Bool {
        var received = 0
        while received < count {
            let n = buffer.withUnsafeMutableBytes { rawBuf -> ssize_t in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.recv(fd, base.advanced(by: received), count - received, 0)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            received += n
        }
        return true
    }
}

class DiscordIPC {
    public static let shared = DiscordIPC()
    private var activeClient: POSIXDiscordIPCClient?
    private var terminationObserver: NSObjectProtocol?

    func initialize() {
        let custom = PlaySettings.shared.discordActivity
        let appID = custom.applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard custom.enable, !appID.isEmpty else {
            return
        }
        guard let socketPath = Self.findReachableDiscordIPCSocket() else {
            return
        }

        let client = POSIXDiscordIPCClient(appId: appID, socketPath: socketPath)
        activeClient = client

        if terminationObserver == nil {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.activeClient?.disconnect()
                self?.activeClient = nil
            }
        }

        Task(priority: .background) { [weak self] in
            guard let self = self else { return }
            let activity = await self.createActivity(from: custom)
            if client.connect() {
                client.setActivity(activity)
            } else {
                client.disconnect()
            }
        }
    }

    private static func findReachableDiscordIPCSocket() -> String? {
        var candidateDirs: [String] = []
        let tempDir = FileManager.default.temporaryDirectory.path
        candidateDirs.append(tempDir)
        let nsTemp = (NSTemporaryDirectory() as NSString).standardizingPath
        if !candidateDirs.contains(nsTemp) {
            candidateDirs.append(nsTemp)
        }
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"],
           !xdg.isEmpty,
           !candidateDirs.contains(xdg) {
            candidateDirs.append(xdg)
        }
        if !candidateDirs.contains("/tmp") {
            candidateDirs.append("/tmp")
        }

        for dir in candidateDirs {
            let trimmed = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
            for ipcPort in 0..<10 {
                let path = "\(trimmed)/discord-ipc-\(ipcPort)"
                if access(path, F_OK) == 0 {
                    return path
                }
            }
        }
        return nil
    }

    func createActivity(from custom: DiscordActivity) async -> [String: Any] {
        var activity: [String: Any] = [:]

        if custom.details.isEmpty {
            let name = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""
            let displayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? name
            activity["details"] = "Playing \(displayName)"
        } else {
            var details = custom.details
            if details.count == 1 { details += " " }
            activity["details"] = details
        }
        activity["details_url"] = "https://github.com/PlayCover/PlayCover/releases"

        let poweredStr = "Powered by PlayCover"
        var assets: [String: Any] = [:]
        if custom.state.isEmpty {
            activity["state"] = poweredStr
        } else {
            var state = custom.state
            if state.count == 1 { state += " " }
            activity["state"] = state
            assets["small_text"] = poweredStr
            assets["large_text"] = poweredStr
        }
        activity["state_url"] = "https://github.com/PlayCover/PlayCover/releases"

        let logo = "https://raw.githubusercontent.com/PlayCover/PlaySite/master/src/assets/square-logo.png"
        if custom.image.isEmpty {
            let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
            if let appImage = await loadImage(bundleID: bundleID) {
                assets["large_image"] = appImage
                assets.removeValue(forKey: "large_text")
                assets["small_image"] = logo
            } else {
                assets["large_image"] = logo
            }
        } else {
            assets["large_image"] = custom.image
            assets.removeValue(forKey: "large_text")
            assets["small_image"] = logo
        }
        activity["assets"] = assets
        activity["timestamps"] = ["start": Int(Date().timeIntervalSince1970)]

        return activity
    }

    func loadImage(bundleID: String) async -> String? {
        let lookup = "http://itunes.apple.com/lookup?bundleId=\(bundleID)"
        guard let url = URL(string: lookup) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            let decoder = JSONDecoder()
            let jsonResult: ITunesResponse = try decoder.decode(ITunesResponse.self, from: data)
            if jsonResult.resultCount > 0 {
                return jsonResult.results[0].artworkUrl512
            } else {
                return nil
            }
        } catch {
            return nil
        }
    }
}

struct ITunesResult: Decodable {
    var isGameCenterEnabled: Bool
    var supportedDevices: [String]
    var features: [String]
    var advisories: [String]
    var screenshotUrls: [String]
    var ipadScreenshotUrls: [String]
    var appletvScreenshotUrls: [String]
    var artworkUrl60: String
    var artworkUrl512: String
    var artworkUrl100: String
    var artistViewUrl: String
    var kind: String
    var isVppDeviceBasedLicensingEnabled: Bool
    var currentVersionReleaseDate: String
    var releaseNotes: String
    var description: String
    var trackId: Int
    var trackName: String
    var bundleId: String
    var sellerName: String
    var genreIds: [String]
    var primaryGenreName: String
    var primaryGenreId: Int
    var currency: String
    var formattedPrice: String
    var contentAdvisoryRating: String
    var averageUserRatingForCurrentVersion: Float
    var userRatingCountForCurrentVersion: Int
    var trackViewUrl: String
    var trackContentRating: String
    var averageUserRating: Float
    var minimumOsVersion: String
    var trackCensoredName: String
    var languageCodesISO2A: [String]
    var fileSizeBytes: String
    var releaseDate: String
    var artistId: Int
    var artistName: String
    var genres: [String]
    var price: Float
    var version: String
    var wrapperType: String
    var userRatingCount: Int
}

struct ITunesResponse: Decodable {
    var resultCount: Int
    var results: [ITunesResult]
}
