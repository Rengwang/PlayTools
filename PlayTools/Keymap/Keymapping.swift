//
//  Keymapping.swift
//  PlayTools
//
//  Created by 이승윤 on 2022/08/29.
//

import Darwin
import Foundation

let keymap = Keymapping.shared

class Keymapping {
    static let shared = Keymapping()

    let bundleIdentifier = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""

    private var keymapIdx: Int
    public var currentKeymap: KeymappingData {
        get {
            getKeymap(path: currentKeymapURL)
        }
        set {
            setKeymap(path: currentKeymapURL, map: newValue)
        }
    }

    private let baseKeymapURL: URL
    private let configURL: URL
    private var keymapOrder: [URL: KeymappingData] = [:]
    private var cachedConfig: (config: KeymapConfig, mtime: timespec)?
    private var cachedKeymaps: [URL: (data: KeymappingData, mtime: timespec)] = [:]

    private func fileMtime(at url: URL) -> timespec? {
        var fileStat = stat()
        guard stat(url.path, &fileStat) == 0 else { return nil }
        return fileStat.st_mtimespec
    }

    private func sameMtime(_ lhs: timespec?, _ rhs: timespec?) -> Bool {
        guard let lhs = lhs, let rhs = rhs else { return false }
        return lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
    }

    public var keymapConfig: KeymapConfig {
        get {
            if let cached = cachedConfig,
               sameMtime(cached.mtime, fileMtime(at: configURL)) {
                return cached.config
            }
            do {
                let data = try Data(contentsOf: configURL)
                let decoded = try PropertyListDecoder().decode(KeymapConfig.self, from: data)
                if let mtime = fileMtime(at: configURL) {
                    cachedConfig = (decoded, mtime)
                }
                return decoded
            } catch {
                print("[PlayTools] Failed to decode config url.\n%@")
                return resetConfig()
            }
        }
        set {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml

            do {
                let data = try encoder.encode(newValue)
                try data.write(to: configURL)
                if let mtime = fileMtime(at: configURL) {
                    cachedConfig = (newValue, mtime)
                } else {
                    cachedConfig = nil
                }
            } catch {
                print("[PlayTools] Keymapping encode failed.\n%@")
            }
        }
    }

    public var currentKeymapURL: URL {
        keymapConfig.keymapOrder[keymapIdx]
    }

    public var currentKeymapName: String {
        currentKeymapURL.deletingPathExtension().lastPathComponent
    }

    init() {
        baseKeymapURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("Keymapping")
            .appendingPathComponent(bundleIdentifier)

        configURL = baseKeymapURL.appendingPathComponent(".config").appendingPathExtension("plist")

        keymapIdx = 0

        loadKeymapData()
    }

    private func constructKeymapPath(name: String) -> URL {
        baseKeymapURL.appendingPathComponent(name).appendingPathExtension("plist")
    }

    private func loadKeymapData() {
        if !FileManager.default.fileExists(atPath: baseKeymapURL.path) {
            do {
                try FileManager.default.createDirectory(
                    atPath: baseKeymapURL.path,
                    withIntermediateDirectories: true,
                    attributes: [:])
            } catch {
                print("[PlayTools] Failed to create Keymapping directory.\n%@")
            }
        }

        keymapOrder.removeAll()

        for keymap in keymapConfig.keymapOrder {
            keymapOrder[keymap] = getKeymap(path: keymap)
        }

        if let defaultKmIdx = keymapOrder.keys.firstIndex(of: keymapConfig.defaultKm) {
            keymapIdx = keymapOrder.distance(from: keymapOrder.startIndex, to: defaultKmIdx)
        } else {
            setKeymap(path: keymapConfig.defaultKm, map: KeymappingData(bundleIdentifier: bundleIdentifier))
            loadKeymapData()
        }
    }

    private func getKeymap(path: URL) -> KeymappingData {
        if let cached = cachedKeymaps[path],
           sameMtime(cached.mtime, fileMtime(at: path)) {
            return cached.data
        }
        do {
            let data = try Data(contentsOf: path)
            let map = try PropertyListDecoder().decode(KeymappingData.self, from: data)
            if let mtime = fileMtime(at: path) {
                cachedKeymaps[path] = (map, mtime)
            }
            return map
        } catch {
            print("[PlayTools] Keymapping decode failed.\n%@")
        }

        return resetKeymap(path: path)
    }

    private func setKeymap(path: URL, map: KeymappingData) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        do {
            let data = try encoder.encode(map)
            try data.write(to: path)
            if let mtime = fileMtime(at: path) {
                cachedKeymaps[path] = (map, mtime)
            } else {
                cachedKeymaps.removeValue(forKey: path)
            }

            if !keymapOrder.keys.contains(path) {
                keymapConfig.keymapOrder.append(path)
                keymapOrder[path] = map
            }
        } catch {
            print("[PlayTools] Keymapping encode failed.\n%@")
        }
    }

    public func nextKeymap() {
        keymapIdx = (keymapIdx + 1) % keymapOrder.count
    }

    public func previousKeymap() {
        keymapIdx = (keymapIdx - 1 + keymapOrder.count) % keymapOrder.count
    }

    @discardableResult
    public func resetKeymap(path: URL) -> KeymappingData {
        setKeymap(path: path, map: KeymappingData(bundleIdentifier: bundleIdentifier))
        return getKeymap(path: path)
    }

    @discardableResult
    private func resetConfig() -> KeymapConfig {
        let defaultURL = constructKeymapPath(name: "default")

        keymapConfig = KeymapConfig(defaultKm: defaultURL, keymapOrder: [defaultURL])

        return keymapConfig
    }

}

struct KeymappingData: Codable {
    var buttonModels: [Button] = []
    var draggableButtonModels: [Button] = []
    var joystickModel: [Joystick] = []
    var mouseAreaModel: [MouseArea] = []
    var bundleIdentifier: String
    var version = "2.0.0"
}

struct KeymapConfig: Codable {
    var defaultKm: URL
    var keymapOrder: [URL]
}
