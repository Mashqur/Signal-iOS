//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import SignalMetadataKit
import SignalCoreKit

public enum OWSUDError: Error {
    case assertionError(description: String)
    case invalidData(description: String)
}

@objc public protocol OWSUDManager: class {

    @objc func setup()

    @objc func trustRoot() -> ECPublicKey

    // MARK: - Recipient state

    @objc func supportsUnidentifiedDelivery(recipientId: String) -> Bool

    @objc func setSupportsUnidentifiedDelivery(_ value: Bool, recipientId: String)

    // Returns the UD access key for a given recipient if they are
    // a UD recipient and we have a valid profile key for them.
    @objc func udAccessKeyForRecipient(_ recipientId: String) -> SMKUDAccessKey?

    // MARK: - Sender Certificate

    // We use completion handlers instead of a promise so that message sending
    // logic can access the certificate data.
    @objc func ensureSenderCertificateObjC(success:@escaping (SMKSenderCertificate) -> Void,
                                            failure:@escaping (Error) -> Void)

    // MARK: - Unrestricted Access

    @objc func shouldAllowUnrestrictedAccessLocal() -> Bool

    @objc func setShouldAllowUnrestrictedAccessLocal(_ value: Bool)

    @objc func shouldAllowUnrestrictedAccess(recipientId: String) -> Bool

    @objc func setShouldAllowUnrestrictedAccess(recipientId: String, shouldAllowUnrestrictedAccess: Bool)
}

// MARK: -

@objc
public class OWSUDManagerImpl: NSObject, OWSUDManager {

    private let dbConnection: YapDatabaseConnection

    private let kUDCollection = "kUDCollection"
    private let kUDCurrentSenderCertificateKey = "kUDCurrentSenderCertificateKey"
    private let kUDUnrestrictedAccessKey = "kUDUnrestrictedAccessKey"
    private let kUDRecipientModeCollection = "kUDRecipientModeCollection"
    private let kUDUnrestrictedAccessCollection = "kUDUnrestrictedAccessCollection"

    @objc
    public required init(primaryStorage: OWSPrimaryStorage) {
        self.dbConnection = primaryStorage.newDatabaseConnection()

        super.init()

        SwiftSingletons.register(self)
    }

    @objc public func setup() {
        AppReadiness.runNowOrWhenAppIsReady {
            guard TSAccountManager.isRegistered() else {
                return
            }
            self.ensureSenderCertificate().retainUntilComplete()
        }
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(registrationStateDidChange),
                                               name: .RegistrationStateDidChange,
                                               object: nil)
    }

    @objc
    func registrationStateDidChange() {
        AssertIsOnMainThread()

        ensureSenderCertificate().retainUntilComplete()
    }

    // MARK: - Dependencies

    private var profileManager: ProfileManagerProtocol {
        return SSKEnvironment.shared.profileManager
    }

    // MARK: - Recipient state

    @objc
    public func supportsUnidentifiedDelivery(recipientId: String) -> Bool {
        return dbConnection.bool(forKey: recipientId, inCollection: kUDRecipientModeCollection, defaultValue: false)
    }

    @objc
    public func setSupportsUnidentifiedDelivery(_ value: Bool, recipientId: String) {
        if value {
            dbConnection.setBool(true, forKey: recipientId, inCollection: kUDRecipientModeCollection)
        } else {
            dbConnection.removeObject(forKey: recipientId, inCollection: kUDRecipientModeCollection)
        }
    }

    // Returns the UD access key for a given recipient
    // if we have a valid profile key for them.
    @objc
    public func udAccessKeyForRecipient(_ recipientId: String) -> SMKUDAccessKey? {
        guard let profileKey = profileManager.profileKeyData(forRecipientId: recipientId) else {
            // Mark as "not a UD recipient".
            return nil
        }
        do {
            let udAccessKey = try SMKUDAccessKey(profileKey: profileKey)
            return udAccessKey
        } catch {
            Logger.error("Could not determine udAccessKey: \(error)")
            return nil
        }
    }

    // MARK: - Sender Certificate

    #if DEBUG
    @objc
    public func hasSenderCertificate() -> Bool {
        return senderCertificate() != nil
    }
    #endif

    private func senderCertificate() -> SMKSenderCertificate? {
        guard let certificateData = dbConnection.object(forKey: kUDCurrentSenderCertificateKey, inCollection: kUDCollection) as? Data else {
            return nil
        }

        do {
            let certificate = try SMKSenderCertificate.parse(data: certificateData)

            guard isValidCertificate(certificate) else {
                Logger.warn("Current sender certificate is not valid.")
                return nil
            }

            return certificate
        } catch {
            owsFailDebug("Certificate could not be parsed: \(error)")
            return nil
        }
    }

    private func setSenderCertificate(_ certificateData: Data) {
        dbConnection.setObject(certificateData, forKey: kUDCurrentSenderCertificateKey, inCollection: kUDCollection)
    }

    @objc
    public func ensureSenderCertificateObjC(success:@escaping (SMKSenderCertificate) -> Void,
                                            failure:@escaping (Error) -> Void) {
        ensureSenderCertificate()
            .then(execute: { certificate in
                success(certificate)
            })
            .catch(execute: { (error) in
                failure(error)
            }).retainUntilComplete()
    }

    public func ensureSenderCertificate() -> Promise<SMKSenderCertificate> {
        // If there is a valid cached sender certificate, use that.
        if let certificate = senderCertificate() {
            return Promise(value: certificate)
        }
        // Try to obtain a new sender certificate.
        return requestSenderCertificate().then { (certificateData, certificate) in

            // Cache the current sender certificate.
            self.setSenderCertificate(certificateData)

            return Promise(value: certificate)
        }
    }

    private func requestSenderCertificate() -> Promise<(Data, SMKSenderCertificate)> {
        return SignalServiceRestClient().requestUDSenderCertificate().then { (certificateData) -> Promise<(Data, SMKSenderCertificate)> in
            let certificate = try SMKSenderCertificate.parse(data: certificateData)

            guard self.isValidCertificate(certificate) else {
                throw OWSUDError.invalidData(description: "Invalid sender certificate returned by server")
            }

            return Promise(value: (certificateData, certificate) )
        }
    }

    private func isValidCertificate(_ certificate: SMKSenderCertificate) -> Bool {

        let certificateValidator = SMKCertificateDefaultValidator(trustRoot: trustRoot())

        // Ensure that the certificate will not expire in the next hour.
        // We want a threshold long enough to ensure that any outgoing message
        // sends will complete before the expiration.
        let nowMs = NSDate.ows_millisecondTimeStamp()
        let anHourFromNowMs = nowMs + kHourInMs

        do {
            try certificateValidator.validate(senderCertificate: certificate, validationTime: anHourFromNowMs)
            return true
        } catch {
            OWSLogger.error("Invalid certificate")
            return false
        }
    }

    @objc
    public func trustRoot() -> ECPublicKey {
        guard let trustRootData = NSData(fromBase64String: kUDTrustRoot) else {
            // This exits.
            owsFail("Invalid trust root data.")
        }

        do {
            return try ECPublicKey(serializedKeyData: trustRootData as Data)
        } catch {
            // This exits.
            owsFail("Invalid trust root.")
        }
    }

    // MARK: - Unrestricted Access

    @objc
    public func shouldAllowUnrestrictedAccessLocal() -> Bool {
        return dbConnection.bool(forKey: kUDUnrestrictedAccessKey, inCollection: kUDCollection, defaultValue: false)
    }

    @objc
    public func setShouldAllowUnrestrictedAccessLocal(_ value: Bool) {
        dbConnection.setBool(value, forKey: kUDUnrestrictedAccessKey, inCollection: kUDCollection)
    }

    @objc
    public func shouldAllowUnrestrictedAccess(recipientId: String) -> Bool {
        return dbConnection.bool(forKey: recipientId, inCollection: kUDUnrestrictedAccessCollection, defaultValue: false)
    }

    @objc
    public func setShouldAllowUnrestrictedAccess(recipientId: String, shouldAllowUnrestrictedAccess: Bool) {
        dbConnection.setBool(shouldAllowUnrestrictedAccess, forKey: recipientId, inCollection: kUDUnrestrictedAccessCollection)
    }
}