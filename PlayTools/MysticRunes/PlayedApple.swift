//
//  PlayWeRuinedIt.swift
//  PlayTools
//
//  Created by Venti on 16/01/2023.
//

import Foundation
import Security

// Implementation for PlayKeychain
// World's Most Advanced Keychain Replacement Solution:tm:
// This is a joke, don't take it seriously

public class PlayKeychain: NSObject {
    static let shared = PlayKeychain()
    private static let playChainDB = PlayKeychainDB.shared

    @objc public static func debugLogger(_ logContent: String) {
        if PlaySettings.shared.settingsData.playChainDebugging {
            NSLog("PC-DEBUG: \(logContent)")
        }
    }

    private static func flag(_ dictionary: NSDictionary, _ key: CFString) -> Bool {
        let value = dictionary[key as String]
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }
    // Emulates SecItemAdd, SecItemUpdate, SecItemDelete and SecItemCopyMatching
    // Store the entire dictionary as a plist
    // SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result)
    @objc static public func add(_ attributes: NSDictionary,
                                 result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        let normalizedAttributes = normalizedAccessGroupDict(attributes)
        guard let keychainDict = playChainDB.insert(normalizedAttributes) else {
            debugLogger("Failed to write keychain file")
            return errSecIO
        }
        debugLogger("Wrote keychain item to db")

        let wantsReturn =
            flag(normalizedAttributes, kSecReturnAttributes) ||
            flag(normalizedAttributes, kSecReturnData) ||
            flag(normalizedAttributes, kSecReturnRef) ||
            flag(normalizedAttributes, kSecReturnPersistentRef)

        guard wantsReturn, result != nil else {
            return errSecSuccess
        }

        return addResult(normalizedAttributes, keychainDict: keychainDict, result: result)
    }

    private static func addResult(_ attributes: NSDictionary,
                                  keychainDict: NSMutableDictionary,
                                  result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        if flag(attributes, kSecReturnAttributes) {
            let dummyDict = NSMutableDictionary(dictionary: keychainDict)
            ensureAccessGroupIfApplicable(dummyDict)
            if !flag(attributes, kSecReturnData) {
                dummyDict.removeObject(forKey: kSecValueData)
                dummyDict.removeObject(forKey: kSecValueRef)
                dummyDict.removeObject(forKey: kSecValuePersistentRef)
            }
            result?.pointee = Unmanaged.passRetained(dummyDict)
            return errSecSuccess
        }

        // Place `v_Data` in the result
        guard let vData = attributes["v_Data"] as? CFTypeRef else {
            // iOS rejects a SecItemAdd that asks for a return value the item cannot
            // provide instead of returning success with an untouched out-pointer.
            debugLogger("SecItemAdd requested a return value but carries no v_Data")
            return errSecParam
        }

        if flag(attributes, kSecReturnData) &&
            !flag(attributes, kSecReturnRef) &&
            !flag(attributes, kSecReturnPersistentRef) {
            result?.pointee = Unmanaged.passRetained(vData)
            return errSecSuccess
        }

        if attributes["class"] as? String == "keys" {
            if let keyDataValue = vData as? Data {
                // kSecAttrKeyType is stored as `type` in the dictionary
                // kSecAttrKeyClass is stored as `kcls` in the dictionary
                let keyAttributesDictionary = [
                    kSecAttrKeyType: attributes["type"] as? String
                        ?? (attributes[kSecAttrKeyType as String] as? String),
                    kSecAttrKeyClass: attributes["kcls"] as? String
                        ?? (attributes[kSecAttrKeyClass as String] as? String)
                ]
                if let key = SecKeyCreateWithData(
                    keyDataValue as CFData,
                    keyAttributesDictionary as CFDictionary,
                    nil
                ) {
                    result?.pointee = Unmanaged.passRetained(key)
                    return errSecSuccess
                }
            }
            return errSecBadReq
        }
        result?.pointee = Unmanaged.passRetained(vData)
        return errSecSuccess
    }

    // SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate)
    @objc static public func update(_ query: NSDictionary,
                                    attributesToUpdate: NSDictionary) -> OSStatus {
        let result = playChainDB.update(query: query, attributesToUpdate: attributesToUpdate)
        guard result.ok else {
            debugLogger("Failed to update keychain item to db")
            return errSecIO
        }
        guard result.changes > 0 else {
            debugLogger("Keychain item not found in db")
            return errSecItemNotFound
        }
        debugLogger("Updated keychain item in db")
        return errSecSuccess
    }

    // SecItemDelete(CFDictionaryRef query)
    @objc static public func delete(_ query: NSDictionary) -> OSStatus {
        let result = playChainDB.delete(query)
        guard result.ok else {
            debugLogger("Failed to delete keychain item")
            return errSecIO
        }
        guard result.changes > 0 else {
            debugLogger("Failed to find keychain item")
            return errSecItemNotFound
        }
        debugLogger("Deleted keychain item in db")
        return errSecSuccess
    }

    @objc static public func keyCreateRandomKey(_ parameters: NSDictionary,
                                                error: UnsafeMutablePointer<Unmanaged<CFError>?>?)
    -> Unmanaged<SecKey>? {
        // Check if kSecAttrIsPermanent is set to 1 in kSecPrivateKeyAttrs.
        // If it is, set it to 0 before fowarding the call to SecKeyCreateRandomKey,
        // and then add the key to the keychain db with the original attributes (with kSecAttrIsPermanent set to 1)
        var privateKeyAttrs = parameters[kSecPrivateKeyAttrs as String] as? [String: Any] ?? [:]
        let isPermanent = privateKeyAttrs[kSecAttrIsPermanent as String] as? Bool ?? false
        if isPermanent {
            privateKeyAttrs[kSecAttrIsPermanent as String] = false
        }
        var parametersCopy = parameters as! [String: Any] // swiftlint:disable:this force_cast
        parametersCopy[kSecPrivateKeyAttrs as String] = privateKeyAttrs
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(parametersCopy as CFDictionary, &error) else {
            debugLogger("Failed to create random key: \(error!.takeRetainedValue())")
            return nil
        }
        if isPermanent {
            // Add the key to the keychain db with the original attributes
            var keychainDict = [String: Any]()
            keychainDict[kSecClass as String] = kSecClassKey
            keychainDict[kSecAttrKeyType as String] = parameters[kSecAttrKeyType as String]
            keychainDict[kSecAttrKeyClass as String] = parameters[kSecAttrKeyClass as String]
            keychainDict["type"] = parameters[kSecAttrKeyType as String]
            keychainDict["kcls"] = parameters[kSecAttrKeyClass as String]
            keychainDict["v_Data"] = SecKeyCopyExternalRepresentation(key, nil) as? Data
            keychainDict["r_Attributes"] = 1
            guard playChainDB.insert(keychainDict as NSDictionary) != nil else {
                debugLogger("Failed to write keychain file")
                return nil
            }
        }
        return Unmanaged.passRetained(key)
    }

    // swiftlint:disable:next function_body_length
    @objc static public func keyGeneratePair(_ parameters: NSDictionary,
                                             publicKey: UnsafeMutablePointer<Unmanaged<SecKey>?>?,
                                             privateKey: UnsafeMutablePointer<Unmanaged<SecKey>?>?) -> OSStatus {
        // Same as above but we need to disable kSecAttrIsPermanent for both the public and private key.
        var isPermanent = parameters[kSecAttrIsPermanent as String] as? Bool ?? false
        var privateKeyAttrs = parameters[kSecPrivateKeyAttrs as String] as? [String: Any] ?? [:]
        let isPrivatePermanent = privateKeyAttrs[kSecAttrIsPermanent as String] as? Bool ?? false
        if isPrivatePermanent {
            privateKeyAttrs[kSecAttrIsPermanent as String] = false
            isPermanent = true
        }
        var publicKeyAttrs = parameters[kSecPublicKeyAttrs as String] as? [String: Any] ?? [:]
        let isPublicPermanent = (publicKeyAttrs[kSecAttrIsPermanent as String] as? Bool) ?? false
        if isPublicPermanent {
            publicKeyAttrs[kSecAttrIsPermanent as String] = false
            isPermanent = true
        }
        var parametersCopy = parameters as! [String: Any] // swiftlint:disable:this force_cast
        parametersCopy.removeValue(forKey: kSecAttrIsPermanent as String)
        parametersCopy[kSecPrivateKeyAttrs as String] = privateKeyAttrs
        parametersCopy[kSecPublicKeyAttrs as String] = publicKeyAttrs
        var newPublicKey: SecKey?
        var newPrivateKey: SecKey?
        guard SecKeyGeneratePair(parametersCopy as CFDictionary, &newPublicKey, &newPrivateKey) == 0 else {
            debugLogger("Failed to generate key pair.")
            return errSecMissingEntitlement
        }
        if let newPublicKey = newPublicKey {
            publicKey?.pointee = Unmanaged.passRetained(newPublicKey)
        }
        if let newPrivateKey = newPrivateKey {
            privateKey?.pointee = Unmanaged.passRetained(newPrivateKey)
        }
        if isPermanent {
            // Add the keys to the keychain db with the original attributes
            let publicKeyRef = newPublicKey
            let privateKeyRef = newPrivateKey
            var publicKeyDict = [String: Any]()
            publicKeyDict[kSecClass as String] = kSecClassKey
            publicKeyDict[kSecAttrKeyType as String] = parameters[kSecAttrKeyType as String]
            publicKeyDict[kSecAttrKeyClass as String] = kSecAttrKeyClassPublic
            publicKeyDict["type"] = parameters[kSecAttrKeyType as String]
            publicKeyDict["kcls"] = kSecAttrKeyClassPublic
            publicKeyDict["v_Data"] = SecKeyCopyExternalRepresentation(publicKeyRef!, nil) as? Data
            publicKeyDict["r_Attributes"] = 1
            guard playChainDB.insert(publicKeyDict as NSDictionary) != nil else {
                debugLogger("Failed to write public key to keychain db")
                return errSecMissingEntitlement
            }
            var privateKeyDict = [String: Any]()
            privateKeyDict[kSecClass as String] = kSecClassKey
            privateKeyDict[kSecAttrKeyType as String] = parameters[kSecAttrKeyType as String]
            privateKeyDict[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
            privateKeyDict["type"] = parameters[kSecAttrKeyType as String]
            privateKeyDict["kcls"] = kSecAttrKeyClassPrivate
            privateKeyDict["v_Data"] = SecKeyCopyExternalRepresentation(privateKeyRef!, nil) as? Data
            privateKeyDict["r_Attributes"] = 1
            guard playChainDB.insert(privateKeyDict as NSDictionary) != nil else {
                debugLogger("Failed to write private key to keychain db")
                return errSecMissingEntitlement
            }
        }
        return errSecSuccess
    }
}

extension PlayKeychain {
    // SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result)
    // swiftlint:disable:next function_body_length
    @objc static public func copyMatching(_ query: NSDictionary,
                                          result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        guard let keychainDicts = playChainDB.query(query),
              let keychainDict = keychainDicts.first else {
            debugLogger("Keychain item not found in db")
            return errSecItemNotFound
        }

        let wantsAttributes = flag(query, kSecReturnAttributes)
        let wantsData = flag(query, kSecReturnData)
        let wantsRef = flag(query, kSecReturnRef)
        let wantsPersistentRef = flag(query, kSecReturnPersistentRef)

        if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
            return copyAllMatches(keychainDicts, query: query, result: result)
        }
        // Check the `r_Attributes` key. If it is set to 1 in the query
        let classType = query[kSecClass as String] as? String ?? ""

        if wantsAttributes {
            // Callers that ask for data must not receive a dictionary silently
            // missing `v_Data`: several hardened apps re-insert the value into
            // their own dictionary and crash on the nil. Report "not found" so
            // they take the normal error path instead.
            guard let dummyDict = resultDictionary(keychainDict, query: query) else {
                debugLogger("SecItemCopyMatching asked for attributes and v_Data, but item has none")
                return errSecItemNotFound
            }
            result?.pointee = Unmanaged.passRetained(dummyDict)
            return errSecSuccess
        }

        // kSecReturnData asks for the stored bytes, even for kSecClassKey.
        if wantsData && !wantsRef && !wantsPersistentRef {
            guard let vData = keychainDict[kSecValueData] else {
                return errSecItemNotFound
            }
            result?.pointee = Unmanaged.passRetained(vData as CFTypeRef)
            return errSecSuccess
        }

        // A query without return flags is an existence check.
        if !wantsAttributes && !wantsData && !wantsRef && !wantsPersistentRef {
            return errSecSuccess
        }

        if wantsRef {
            return copyReference(keychainDict, result: result)
        }

        // Return v_Data if it exists
        if let vData = keychainDict[kSecValueData] {
            debugLogger("Read keychain file from db")
            // Check the class type, if it is a key we need to return the data
            // as SecKeyRef, otherwise we can return it as a CFTypeRef
            if classType == "keys" {
                // kSecAttrKeyType is stored as `type` in the dictionary
                // kSecAttrKeyClass is stored as `kcls` in the dictionary
                let keyAttributes = [
                    kSecAttrKeyType: keychainDict[kSecAttrKeyType] as! CFString, // swiftlint:disable:this force_cast
                    kSecAttrKeyClass: keychainDict[kSecAttrKeyClass] as! CFString // swiftlint:disable:this force_cast
                ]
                let keyData = vData as! Data // swiftlint:disable:this force_cast
                let key = SecKeyCreateWithData(keyData as CFData, keyAttributes as CFDictionary, nil)
                result?.pointee = Unmanaged.passRetained(key!)
                return errSecSuccess
            }
            result?.pointee = Unmanaged.passRetained(vData as CFTypeRef)
            return errSecSuccess
        }

        return errSecItemNotFound
    }

    private static func copyAllMatches(_ keychainDicts: [NSMutableDictionary], query: NSDictionary,
                                       result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        let wantsData = flag(query, kSecReturnData)
        let wantsAttributes = flag(query, kSecReturnAttributes)
        let wantsRef = flag(query, kSecReturnRef)
        let wantsPersistentRef = flag(query, kSecReturnPersistentRef)
        if wantsData && !wantsAttributes && !wantsRef && !wantsPersistentRef {
            let values = keychainDicts.compactMap({ $0[kSecValueData] })
            guard values.count == keychainDicts.count else {
                return errSecItemNotFound
            }
            result?.pointee = Unmanaged.passRetained(values as CFTypeRef)
            return errSecSuccess
        }

        // Same contract as the single-item path: entries that cannot satisfy the requested
        // return flags are not valid matches, and an empty result is "not found".
        let dictionaries = keychainDicts.compactMap { resultDictionary($0, query: query) }
        guard !dictionaries.isEmpty else {
            debugLogger("SecItemCopyMatching matched only items without v_Data")
            return errSecItemNotFound
        }
        result?.pointee = Unmanaged.passRetained(dictionaries as CFTypeRef)
        return errSecSuccess
    }

    /// Builds the attribute dictionary for a match. `kSecReturnData` must yield real data;
    /// otherwise the item is rejected so callers never see a silent nil.
    private static func resultDictionary(_ keychainDict: NSMutableDictionary,
                                         query: NSDictionary) -> NSMutableDictionary? {
        let wantsData = flag(query, kSecReturnData)
        if wantsData && keychainDict[kSecValueData] == nil { return nil }
        let dict = NSMutableDictionary(dictionary: keychainDict)
        ensureAccessGroupIfApplicable(dict)
        if !wantsData {
            dict.removeObject(forKey: kSecValueData)
            dict.removeObject(forKey: kSecValueRef)
            dict.removeObject(forKey: kSecValuePersistentRef)
        }
        return dict
    }

    private static func copyReference(_ keychainDict: NSMutableDictionary,
                                      result: UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> OSStatus {
        // Return the data on v_PersistentRef or v_Data if they exist
        var key: CFTypeRef?
        if let vData = keychainDict[kSecValueData] {
            NSLog("found v_Data")
            debugLogger("Read keychain item from db")
            key = vData as CFTypeRef
        }
        if let vPersistentRef = keychainDict[kSecValuePersistentRef] {
            NSLog("found persistent ref")
            debugLogger("Read keychain item from db")
            key = vPersistentRef as CFTypeRef
        }

        if key == nil {
            debugLogger("Keychain item not found in db")
            return errSecItemNotFound
        }

        guard let keyData = key as? Data else {
            return errSecItemNotFound
        }

        if (keychainDict[kSecClass] as? String) == (kSecClassCertificate as String),
           let cert = SecCertificateCreateWithData(nil, keyData as CFData) {
            result?.pointee = Unmanaged.passRetained(cert)
            return errSecSuccess
        }

        let dummyKeyAttrs = [
            kSecAttrKeyType: keychainDict[kSecAttrKeyType] ?? kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: keychainDict[kSecAttrKeyClass] ?? kSecAttrKeyClassPublic
        ] as CFDictionary

        guard let secKey = SecKeyCreateWithData(keyData as CFData, dummyKeyAttrs, nil) else {
            debugLogger("SecKeyCreateWithData failed for keychain item")
            return errSecItemNotFound
        }
        result?.pointee = Unmanaged.passRetained(secKey)
        return errSecSuccess
    }
}
