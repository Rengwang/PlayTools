//
//  PlayedAppleBackend.swift
//  PlayTools
//
//  Created by Ryu-ga on 2/20/24.
//

import Foundation
import Security
import SQLite3
import UIKit

class PlayKeychainDB: NSObject {
    public static let shared = PlayKeychainDB()

    private var dbLock: DispatchSemaphore = .init(value: 1)
    private var dbVersion: Int = 1
    private var isSchemaVerified: Bool = false
    private var didEnsureDirectory: Bool = false
    private var persistentDB: OpaquePointer?
    private var terminationObserver: NSObjectProtocol?

    override init() {
        super.init()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.closePersistentConnection()
        }
    }

    deinit {
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        closePersistentConnection()
    }

    func query(_ attributes: NSDictionary) -> [NSMutableDictionary]? {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString] else {
            return nil
        }

        // Keychain matching is conjunctive over *every* attribute in the query, not
        // just the primary key. Ignoring the rest made a lookup for e.g. `gena =
        // IMEIString` return an unrelated item that merely shared the access group,
        // which hardened apps then dereference as if it were their own record.
        let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] ?? []
        let queryColumns = primaryColumns + secondaryColumns + PlayedAppleDBConstants.values
        let (whereClause, whereBindings) = buildWhereClause(columns: queryColumns, attributes: attributes)
        guard !whereClause.isEmpty else { return nil }
        let selectLimit = attributes[kSecMatchLimit] as? String == kSecMatchLimitOne as String ? 1 : Int.max

        let selectQuery = "SELECT * FROM \(tableName) WHERE \(whereClause) LIMIT \(selectLimit)"
        var stmt: OpaquePointer?

        var dictArr: [NSMutableDictionary] = []
        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, selectQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(selectQuery)")
                PlayKeychain.debugLogger("Failed to query to db table: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            for (index, value) in whereBindings.enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed to bind query parameter: \(errorMessage)")
                return false
            }

            while sqlite3_step(stmt) == SQLITE_ROW && dictArr.count < selectLimit {
                let newDict: NSMutableDictionary = [:]
                let columns = sqlite3_column_count(stmt)
                newDict[kSecClass] = tableName
                newDict[kSecAttrSynchronizable] = attributes[kSecAttrSynchronizable]
                for index in 0..<columns {
                    let name = String(cString: sqlite3_column_name(stmt, index))
                    if let value = decodeData(stmt: stmt, index: index) {
                        newDict[name] = value
                    }
                }
                dictArr.append(newDict)
            }

            return true
        }) else { return nil }

        return dictArr
    }

    func insert(_ attributes: NSDictionary) -> NSMutableDictionary? {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
              let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] else {
            return nil
        }

        var columnsQuery = primaryColumns.map({ "\($0)" })
        columnsQuery.append(contentsOf: secondaryColumns.compactMap({
            attributes[$0] != nil ? "\($0)" : nil
        }))
        columnsQuery.append(contentsOf: PlayedAppleDBConstants.values.compactMap({
            attributes[$0] != nil ? "\($0)" : nil
        }))

        let insertValues = columnsQuery.map({ attributes[$0] as CFTypeRef })

        let insertColumns = columnsQuery.joined(separator: ", ")
        let insertPlaceholders = Array(repeating: "?", count: insertValues.count).joined(separator: ", ")

        let insertQuery = "INSERT INTO \(tableName) (\(insertColumns)) VALUES (\(insertPlaceholders))"
        var stmt: OpaquePointer?

        let newDict: NSMutableDictionary = [:]
        newDict[kSecClassKey] = tableName
        for column in columnsQuery {
            newDict[column] = attributes[column]
        }

        guard usingDB({ sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, insertQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(insertQuery)")
                PlayKeychain.debugLogger("Failed to make query: \(errorMessage)")
                return false
            }

            for (index, value) in insertValues.enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                let erorrMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed to insert into db: \(erorrMessage)")
                return false
            }

            return sqlite3_step(stmt) == SQLITE_DONE
        }) else { return nil }

        return newDict
    }

    /// Applies a partial update: `query` only builds the WHERE clause, and
    /// `attributesToUpdate` only builds the SET clause. Returns the affected row count so the
    /// caller can report `errSecItemNotFound` instead of a false success.
    func update(query: NSDictionary, attributesToUpdate: NSDictionary) -> (ok: Bool, changes: Int) {
        guard let tableName = query[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
              let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] else {
            return (false, 0)
        }

        let allColumns = primaryColumns + secondaryColumns + PlayedAppleDBConstants.values
        var setClauses: [String] = []
        var setValues: [CFTypeRef] = []
        for column in allColumns where column as String != kSecClass as String {
            guard let value = attributesToUpdate[column] else { continue }
            setClauses.append("\(column) = ?")
            setValues.append(value as CFTypeRef)
        }
        guard !setClauses.isEmpty else { return (false, 0) }

        let (whereClause, whereBindings) = buildWhereClause(columns: allColumns, attributes: query)
        guard !whereClause.isEmpty else { return (false, 0) }

        let updateQuery = "UPDATE \(tableName) SET \(setClauses.joined(separator: ", ")) WHERE \(whereClause)"
        var stmt: OpaquePointer?
        var changes = 0

        let ok = usingDB { sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, updateQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(updateQuery)")
                PlayKeychain.debugLogger("Failed to make query: \(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            for (index, value) in setValues.enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                PlayKeychain.debugLogger("Failed to bind update value")
                return false
            }

            let whereOffset = setValues.count
            for (index, value) in whereBindings.enumerated()
            where !encodeData(stmt: stmt, index: Int32(whereOffset + index + 1), value: value) {
                PlayKeychain.debugLogger("Failed to bind update parameter")
                return false
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            changes = Int(sqlite3_changes(sqlite3DB))
            return true
        }

        return (ok, ok ? changes : 0)
    }

    /// Deletes every row matched by the query (all provided attributes are part of the WHERE
    /// clause) and reports how many rows were removed.
    func delete(_ attributes: NSDictionary) -> (ok: Bool, changes: Int) {
        guard let tableName = attributes[kSecClass] as? String,
              let primaryColumns = PlayedAppleDBConstants.primaries[tableName as CFString],
              let secondaryColumns = PlayedAppleDBConstants.attributes[tableName as CFString] else {
            return (false, 0)
        }

        let allColumns = primaryColumns + secondaryColumns + PlayedAppleDBConstants.values
        let (whereClause, whereBindings) = buildWhereClause(columns: allColumns, attributes: attributes)
        // `SecItemDelete` with only kSecClass is the documented "clear this class" call.
        // `tableName` comes from the constants whitelist above, so it is safe to interpolate.
        let deleteQuery = whereClause.isEmpty
            ? "DELETE FROM \(tableName)"
            : "DELETE FROM \(tableName) WHERE \(whereClause)"
        var stmt: OpaquePointer?
        var changes = 0

        let ok = usingDB { sqlite3DB in
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare(sqlite3DB, deleteQuery, -1, &stmt, nil) == SQLITE_OK,
                  let stmt = stmt else {
                PlayKeychain.debugLogger("Failed query \(deleteQuery)")
                PlayKeychain.debugLogger("Failed to delete items from db table: "
                                         + "\(String(cString: sqlite3_errmsg(sqlite3DB)))")
                return false
            }

            for (index, value) in whereBindings.enumerated()
            where !encodeData(stmt: stmt, index: Int32(index + 1), value: value) {
                PlayKeychain.debugLogger("Failed to bind delete parameter")
                return false
            }

            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            changes = Int(sqlite3_changes(sqlite3DB))
            return true
        }

        return (ok, ok ? changes : 0)
    }

    private func structDB(_ sqlite3DB: OpaquePointer) -> Bool {
        for (key, value) in PlayedAppleDBConstants.primaries {
            var columns: [CFString] = value
            columns.append(contentsOf: PlayedAppleDBConstants.attributes[key]!)
            columns.append(contentsOf: PlayedAppleDBConstants.values)
            let columnsSetting = columns.map({ return "\($0) TEXT" }).joined(separator: ", ")
            let primaryKeysSetting = "PRIMARY KEY (\(value.map({ return "\($0)" }).joined(separator: ", ")))"
            let createTableQuery = "CREATE TABLE IF NOT EXISTS \(key) (\(columnsSetting), \(primaryKeysSetting));"
            guard sqlite3_exec(sqlite3DB, createTableQuery, nil, nil, nil) == SQLITE_OK else {
                let errorMessage = String(cString: sqlite3_errmsg(sqlite3DB))
                PlayKeychain.debugLogger("Failed query \(createTableQuery)")
                PlayKeychain.debugLogger("Failed to create db table: \(errorMessage)")
                return false
            }
        }

        sqlite3_exec(sqlite3DB, "PRAGMA user_version = \(dbVersion)", nil, nil, nil)

        return true
    }

    private func usingDB(_ callback: (OpaquePointer) -> Bool) -> Bool {
        dbLock.wait()
        defer { dbLock.signal() }

        guard let sqlite3DB = openOrReuseDB() else { return false }
        let result = callback(sqlite3DB)
        if !result && shouldReconnect(afterErrorOn: sqlite3DB) {
            resetConnectionLocked()
            guard let retryDB = openOrReuseDB() else { return false }
            return callback(retryDB)
        }
        return result
    }

    private func shouldReconnect(afterErrorOn sqlite3DB: OpaquePointer) -> Bool {
        let code = sqlite3_errcode(sqlite3DB)
        switch code {
        case SQLITE_IOERR, SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_CANTOPEN,
             SQLITE_READONLY, SQLITE_NOMEM, SQLITE_PROTOCOL, SQLITE_BUSY, SQLITE_LOCKED:
            return true
        default:
            return false
        }
    }

    private func closePersistentConnection() {
        dbLock.wait()
        resetConnectionLocked()
        dbLock.signal()
    }

    private func resetConnectionLocked() {
        if let sqliteDB = persistentDB {
            _ = sqlite3_close_v2(sqliteDB)
            persistentDB = nil
        }
        isSchemaVerified = false
    }

    private func openOrReuseDB() -> OpaquePointer? {
        if let existing = persistentDB, isSchemaVerified {
            return existing
        }

        var sqlite3DB: OpaquePointer?
        let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "Shared"
        let playChainDir = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("PlayChain")
        if !didEnsureDirectory {
            do {
                try FileManager.default.createDirectory(at: playChainDir, withIntermediateDirectories: true)
                didEnsureDirectory = true
            } catch {
                PlayKeychain.debugLogger("Failed to create PlayChain directory: \(error)")
            }
        }
        let keychainDB = playChainDir.appendingPathComponent("\(bundleID).db")

        let fileAttrs = try? FileManager.default.attributesOfItem(atPath: keychainDB.path)
        let fileSize = (fileAttrs?[.size] as? NSNumber)?.int64Value ?? 0
        let needsSchemaInit = fileSize == 0 || !isSchemaVerified

        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(keychainDB.path, &sqlite3DB, openFlags, nil) == SQLITE_OK,
              let sqlite3DB = sqlite3DB else {
            if let sqliteDB = sqlite3DB {
                _ = sqlite3_close_v2(sqliteDB)
            }
            PlayKeychain.debugLogger("Failed to connect to DB")
            return nil
        }

        sqlite3_busy_timeout(sqlite3DB, 2000)
        sqlite3_exec(sqlite3DB, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)

        // Check PRAGMA user_version once per process (or on 0-byte files) so we do not
        // fsync CREATE TABLE on every hot query while still initializing empty/0-byte DBs.
        if needsSchemaInit {
            guard verifySchemaIfNeeded(sqlite3DB, fileSize: fileSize) else {
                _ = sqlite3_close_v2(sqlite3DB)
                return nil
            }
            isSchemaVerified = true
        }

        persistentDB = sqlite3DB
        return sqlite3DB
    }
}

private extension PlayKeychainDB {
    /// Builds a parameterized SQL WHERE clause and ordered binding values from primary key attributes.
    func buildWhereClause(
        columns: [CFString],
        attributes: NSDictionary
    ) -> (clause: String, bindings: [CFTypeRef]) {
        var clauses: [String] = []
        var bindings: [CFTypeRef] = []

        for col in columns {
            guard let attr = attributes[col] else { continue }
            let ref = attr as CFTypeRef
            let typeID = CFGetTypeID(ref)
            if typeID == CFDataGetTypeID() {
                let data = ref as! CFData // swiftlint:disable:this force_cast
                clauses.append("(\(col) = ? OR CAST(\(col) AS BLOB) = ?)")
                bindings.append(data)
                bindings.append(data)
            } else {
                let boundValue: CFTypeRef = (typeID == CFStringGetTypeID() || typeID == CFNullGetTypeID())
                    ? ref
                    : ("\(attr)" as CFString)
                clauses.append("(\(col) = ? OR CAST(\(col) AS TEXT) = ?)")
                bindings.append(boundValue)
                bindings.append(boundValue)
            }
        }

        return (clauses.joined(separator: " AND "), bindings)
    }

    func encodeData(stmt: OpaquePointer, index: Int32, value: CFTypeRef) -> Bool {
        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var result = SQLITE_FAIL
        switch CFGetTypeID(value) {
        case CFStringGetTypeID():
            let string = value as! String // swiftlint:disable:this force_cast
            result = sqlite3_bind_text(stmt, index, string, -1, sqliteTransient)
        case CFDataGetTypeID():
            let data = value as! CFData // swiftlint:disable:this force_cast
            let size = CFDataGetLength(data)
            if size == 0 {
                // `CFDataGetBytePtr` is NULL for empty data; binding that as a blob stores
                // SQLITE_NULL, which is indistinguishable from "no value" on read.
                result = sqlite3_bind_zeroblob(stmt, index, 0)
            } else {
                let ptr = CFDataGetBytePtr(data)
                result = sqlite3_bind_blob(stmt, index, ptr, Int32(size), sqliteTransient)
            }
        case CFNullGetTypeID():
            result = sqlite3_bind_null(stmt, index)
        default:
            PlayKeychain.debugLogger("Cannot encode this data type: \(CFGetTypeID(value))")
            result = sqlite3_bind_null(stmt, index)
        }

        return result == SQLITE_OK
    }

    func decodeData(stmt: OpaquePointer, index: Int32) -> CFTypeRef? {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
            let byteCount = sqlite3_column_bytes(stmt, index)
            if byteCount == 0 {
                return "" as CFString
            }
            return CFStringCreateWithBytes(
                nil,
                ptr,
                CFIndex(byteCount),
                CFStringBuiltInEncodings.UTF8.rawValue,
                false
            ) ?? CFStringCreateWithBytes(
                nil,
                ptr,
                CFIndex(byteCount),
                CFStringBuiltInEncodings.isoLatin1.rawValue,
                false
            )
        case SQLITE_BLOB:
            // A legal zero-length BLOB reports a NULL pointer, so the size decides emptiness.
            let size = sqlite3_column_bytes(stmt, index)
            if size == 0 { return Data() as CFData }
            guard let ptr = sqlite3_column_blob(stmt, index) else { return nil }
            return CFDataCreate(nil, ptr, CFIndex(size))
        case SQLITE_NULL:
            return nil
        default:
            PlayKeychain.debugLogger("Cannot decode this data \(sqlite3_column_type(stmt, index))")
            return nil
        }
    }

    func verifySchemaIfNeeded(_ sqlite3DB: OpaquePointer, fileSize: Int64) -> Bool {
        var currentVersion: Int32 = 0
        var verStmt: OpaquePointer?
        if sqlite3_prepare_v2(sqlite3DB, "PRAGMA user_version", -1, &verStmt, nil) == SQLITE_OK {
            if sqlite3_step(verStmt) == SQLITE_ROW {
                currentVersion = sqlite3_column_int(verStmt, 0)
            }
            sqlite3_finalize(verStmt)
        }
        if currentVersion < Int32(dbVersion) || fileSize == 0 {
            return structDB(sqlite3DB)
        }
        return true
    }
}

extension PlayKeychain {
    static var defaultAccessGroup: String {
        let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "com.playcover.app"
        return "PLAYCOVER.\(bundleID)"
    }

    static func normalizedAccessGroupDict(_ attributes: NSDictionary) -> NSDictionary {
        guard let tableName = attributes[kSecClass] as? String,
              let primaries = PlayedAppleDBConstants.primaries[tableName as CFString],
              primaries.contains(kSecAttrAccessGroup),
              attributes[kSecAttrAccessGroup] == nil else {
            return attributes
        }
        let mutable = NSMutableDictionary(dictionary: attributes)
        mutable[kSecAttrAccessGroup] = defaultAccessGroup
        return mutable
    }

    static func ensureAccessGroupIfApplicable(_ dict: NSMutableDictionary) {
        let tableName = dict[kSecClass] as? String
        if let tableName,
           let primaries = PlayedAppleDBConstants.primaries[tableName as CFString],
           !primaries.contains(kSecAttrAccessGroup) {
            return
        }
        if dict[kSecAttrAccessGroup] == nil {
            dict[kSecAttrAccessGroup] = defaultAccessGroup
        }
    }
}
