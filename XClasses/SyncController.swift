//
//  SyncController.swift
//  Bookbot
//
//  Created by Adrian on 29/4/17.
//  Copyright © 2017 Adrian DeWitts. All rights reserved.
//

import Foundation
import Firebase
import RealmSwift
import Moya
import FileKit
import Hydra

/// Sync model stores meta data for each table. These are when the database was last synced, and if it is currently in lock (which will only last a minute because of timeouts).
public class SyncModel: Object
{
    @objc dynamic var modelName = ""
    /// Server timestamp of last server sync. Used on next sync request.
    @objc dynamic var serverSync: Date? = nil
    /// Each lock will prevent another request being initiated while it does its sync.
    @objc dynamic var readLock = Date.distantPast
    @objc dynamic var writeLock = Date.distantPast
    @objc dynamic var deleteLock = Date.distantPast
    @objc dynamic var internalVersion = 1.0

    class func named(_ modelName: String) -> SyncModel? {
        return Database.realm?.objects(SyncModel.self).filter("modelName = %@", modelName).first
    }
}

/// The SyncController is a shared controller and manages the sync between the client and server.
public class SyncController {
    static let shared = SyncController()
    static let serverTimeout = 60.0
    static let retries = 60
    static let retrySleep: UInt32 = 1
    var uid = ""

    /// Configure sets up the SyncModels for each synced table. This is setup in the AppDelegate when app is first loaded.
    func configure(models: [ViewModel.Type]) {
        // Looking for a Realm Configuration in a separate Migrator class which is defined outside of the library
        var config = Migrator.configuration
        config.fileURL = (Path.userApplicationSupport + "default.realm").url
        config.shouldCompactOnLaunch = { totalBytes, usedBytes in
            // Compact if the file is over 100MB in size and less than 50% 'used'
            let oneHundredMB = 100 * 1024 * 1024
            print("DB Size total: \(totalBytes) used: \(usedBytes)")
            return (totalBytes > oneHundredMB) && (Double(usedBytes) / Double(totalBytes)) < 0.5
        }
        Realm.Configuration.defaultConfiguration = config

        // New Syncmodel if it does not exist
        for model in models {
            let name = String(describing: model)
            if SyncModel.named(name) == nil {
                Database.add(SyncModel(value: ["modelName": name, "internalVersion": model.internalVersion]))
            }
        }
    }

    /// Configure file will create needed folders to store synced files. This is setup in the AppDelegate when app is first loaded.
    func configureFile(models: [ViewModel.Type]) {
        for model in models {
            let paths = model.fileAttributes
            for p in paths {
                let path = Path(p.value.localURL).parent
                if !path.exists {
                    try! path.createDirectory()
                }
            }
        }
    }

    /// Token will get the user token and return this as a Promise.
    func token() -> Promise<String> {
        return Promise<String> { resolve, reject, _ in
            guard let user = Auth.auth().currentUser else {
                log(error: "User has not authenticated")
                reject(CommonError.authenticationError)
                return
            }

            self.uid = user.uid
            user.getIDToken() { token, error in
                if let error = error {
                    log(error: error.localizedDescription)
                    reject(error)
                    return
                }
                resolve(token!)
            }
        }
    }

    /// Sync will read and write sync specific models. If there is no token it will attempt to read with guest permissions. Will not attempt a retry if there are any issues.
    func sync(models: [ViewModel.Type])
    {
        //TODO: Retry a few time if there is an error
        token().then(in: .utility) { token in
            for model in models {
                // After it is written out, then do a read sequentially. This prevents it from reading the old write before the new write is written.
                let a = self.writeSync(model: model, token: token)
                let b = self.deleteSync(model: model, token: token)
                Promise<Void>.zip(in: .utility, a, b).then { _ in
                        self.readSync(model: model, token: token).then(in: .utility) { _ in }
                    }.catch({ (error) in
                        // stil read when write or delete error
                        self.readSync(model: model, token: token).then(in: .utility) { _ in }
                    })
            }
        }.catch() { error in
            for model in models {
                self.readSync(model: model, token: nil).then(in: .utility) { _ in}
                // Never has write sync because write needs to be authenticated
            }
        }
    }

    /// Instead of responding with a Promise of results, instead return the sync has changed the results in the table. The reason for this is that it is more code to move the Realm response over the thread. Also it is important to do a Realm refresh on your thread, so it can see the new record.
    func sync(model: ViewModel.Type, freshness: Double = 600.0, timeout: Double = 60.0) -> Promise<Bool> {
        return Promise<Bool> { resolve, reject, _ in
            autoreleasepool {
                // Sync Model must be configured and ready
                guard let syncModel = SyncModel.named(String(describing: model)) else {
                    reject(CommonError.unexpectedError)
                    return
                }

                // Is the sync fresh and there is records, then resolve
                let serverSync = syncModel.serverSync ?? Date.distantPast
                let interval = Date().timeIntervalSince(serverSync)
                if interval < freshness && !model.empty {
                    resolve(false)
                }

                if freshness == 0.0 {
                    print("Make sure you are calling Refresh on the Realm on your thread, so you can see the new or updated record.")
                }

                self.token().then() { token in
                    self.readSync(model: model, token: token, qos: .userInitiated).retry(SyncController.retries) { _,_ in
                        sleep(SyncController.retrySleep)
                        return true
                    }.then { newRecords in
                        resolve(newRecords)
                    }.catch { error in
                        reject(error)
                    }
                }.catch() { _ in
                    self.readSync(model: model, token: nil, qos: .userInitiated).retry(SyncController.retries) { _,_ in
                        sleep(SyncController.retrySleep)
                        return true
                    }.then { newRecords in
                        resolve(newRecords)
                    }.catch { error in
                        reject(error)
                    }
                }
            }
        }
    }

    /// Read sync make a request to the web service and stores new record to the local DB. Will also mark records for deletion.
    func readSync(model: ViewModel.Type, token: String? = nil, qos: DispatchQoS.QoSClass = .utility) -> Promise<Bool> {
        return Promise<Bool> { resolve, reject, _ in
            autoreleasepool {
                let modelName = String(describing: model)

                // Make sure model has permission
                let authenticated = (model.authenticate == true && token != nil) || model.authenticate == false
                guard authenticated, model.read == true else {
                    reject(CommonError.permissionError)
                    return
                }

                // Get syncModel
                let minuteAgo = Date(timeIntervalSinceNow: -SyncController.serverTimeout)
                guard let syncModel = SyncModel.named(modelName), syncModel.readLock < minuteAgo else {
                    reject(CommonError.syncLockError)
                    return
                }

                // Make sync locked
                Database.update {
                    syncModel.readLock = Date()
                }
                var syncTimestamp: Date? = syncModel.serverSync
                //print("Locked: \(modelName)")

                // Make request with Moya
                let provider = MoyaProvider<WebService>(callbackQueue: DispatchQueue.global(qos: qos))//, plugins: [NetworkLoggerPlugin(verbose: true)])
                provider.request(.read(version: model.tableVersion, table: model.table, view: model.tableView, accessToken: token, lastTimestamp: syncModel.serverSync, predicate: nil)) { result in
                    // Put autoreleasepool around everything to get all realms
                    autoreleasepool {
                        defer {
                            if let syncModel = SyncModel.named(modelName) {
                                Database.update {
                                    syncModel.readLock = Date.distantPast
                                    syncModel.serverSync = syncTimestamp
                                }
                                //print("Unlocked: \(modelName)")
                            }
                        }

                        switch result {
                        case let .success(moyaResponse):
                            guard moyaResponse.statusCode == 200 else {
                                if moyaResponse.statusCode == 403 {
                                    SyncConfiguration.forbidden(modelName: modelName)
                                }
                                else {
                                    log(error: "Server returned status code \(moyaResponse.statusCode) while trying to read sync for \(modelName). Response: \(String(describing: try? moyaResponse.mapString()))")
                                }
                                reject(CommonError.permissionError)
                                return
                            }

                            do {
                                let response = try moyaResponse.mapString()
                                let l = response.components(separatedBy: "\n")
                                let meta = l[0].components(separatedBy: "|")
                                syncTimestamp = Date.from(UTCString: meta[1])
                                let h = l[1].components(separatedBy: "|")
                                let header = h.map { $0.camelCased() }
                                let lines = l.dropFirst(2)
                                let idIndex = header.index(of: "id")!
                                var newRecords: [Object] = []
                                newRecords.reserveCapacity(lines.count)

                                for line in lines {
                                    let components = line.components(separatedBy: "|")
                                    let id = Int(components[idIndex])!

                                    var dict = [String: String]()
                                    for (index, property) in header.enumerated() {
                                        dict[property] = components[index]
                                    }

                                    let value = dict["delete"]?.lowercased()
                                    let notDeleted = value == nil || value != "true"

                                    if let record = Database.realm!.objects(model).filter("id = %@", id).first {
                                        Database.update {
                                            if notDeleted {
                                                record.importProperties(dictionary: dict, isNew: false)
                                            }
                                            else {
                                                record._deleted = true
                                            }
                                        }
                                    }
                                    else {
                                        if notDeleted {
                                            let record = model.init()
                                            record.importProperties(dictionary: dict, isNew: true)
                                            newRecords.append(record)
                                        }
                                    }
                                }
                                Database.add(newRecords)
                                resolve(newRecords.count > 0)
                            }
                            catch {
                                log(error: "Response was impossibly incorrect")
                                // Might be significant issues, so reset the sync
                                syncTimestamp = nil
                                reject(CommonError.miscellaneousNetworkError)
                            }
                        case let .failure(error):
                            log(error: "Server connectivity error \(error.localizedDescription)")
                            reject(CommonError.networkConnectionError)
                        }
                    }
                }
            }
        }
    }

    /// Write sync uploads new and updated records from the local DB to the server.
    func writeSync(model: ViewModel.Type, token: String? = nil, qos: DispatchQoS.QoSClass = .utility) -> Promise<Void> {
        return Promise<Void> { resolve, reject, _ in
            autoreleasepool {
                let modelClass = model
                let model = "\(model)"

                // Make sure model has permission. Writes/POST always must have authentication
                guard token != nil, modelClass.write == true else {
                    reject(CommonError.permissionError)
                    return
                }

                // Make sure there are records to save
                let syncRecords = Database.realm!.objects(modelClass).filter("_sync = %@ OR _sync = %@", SyncStatus.created.rawValue, SyncStatus.updated.rawValue)
                guard syncRecords.count > 0 else {
                    resolve(Void())
                    return
                }

                // Make sure syncModel is not sync locked
                let minuteAgo = Date(timeIntervalSinceNow: -SyncController.serverTimeout)
                guard let syncModel = SyncModel.named(model), syncModel.writeLock < minuteAgo else {
                    reject(CommonError.syncLockError)
                    return
                }

                Database.update {
                    syncModel.writeLock = Date()
                }

                // 1000 seems to get close to the 60 second limit for updates, so 500 gives it some room to breath
                let limit = 500
                var syncSlice: [ViewModel] = []
                syncSlice.reserveCapacity(limit)
                var count = 0
                for record in syncRecords {
                    count += 1
                    if count >= limit {
                        break
                    }
                    syncSlice.append(record)
                }

                let provider = MoyaProvider<WebService>(callbackQueue: DispatchQueue.global(qos: qos))//, plugins: [NetworkLoggerPlugin(verbose: true)])
                provider.request(.createAndUpdate(version: modelClass.tableVersion, table: modelClass.table, view: modelClass.tableView, accessToken: token!, records: syncSlice)) { result in
                    autoreleasepool {
                        defer {
                            if let syncModel = SyncModel.named(model) {
                                Database.update {
                                    syncModel.writeLock = Date.distantPast
                                }
                            }
                        }

                        switch result {
                        case let .success(moyaResponse):
                            if moyaResponse.statusCode == 200 {
                                do {
                                    let response = try moyaResponse.mapString()
                                    let lines = response.components(separatedBy: "\n").dropFirst()
                                    for line in lines {
                                        let components = line.components(separatedBy: "|")
                                        let id = Int(components[0])!
                                        let cid = components[1]

                                        if let item = Database.realm!.objects(modelClass).filter("id = %@ OR clientId = %@", id, cid).first {
                                            Database.update {
                                                item.id = id
                                                item._sync = SyncStatus.current.rawValue
                                            }
                                        }
                                    }

                                    resolve(Void())
                                }
                                catch {
                                    log(error: "Response was impossibly incorrect")
                                    reject(CommonError.unexpectedError)
                                }
                            }
                            else if moyaResponse.statusCode == 403 {
                                SyncConfiguration.forbidden(modelName: String(describing: model))
                                reject(CommonError.permissionError)
                            }
                            else {
                                log(error: "Server returned status code \(moyaResponse.statusCode) while trying to write sync for \(model). Response: \(String(describing: try? moyaResponse.mapString()))")
                                //print(try! moyaResponse.mapString())
                                reject(CommonError.permissionError)
                            }
                        case let .failure(error):
                            log(error: error.errorDescription!)
                            reject(CommonError.networkConnectionError)
                        }
                    }
                }
            }
        }
    }

    /// Warning deleteSync has not been used or tested.
    func deleteSync(model: ViewModel.Type, token: String? = nil, qos: DispatchQoS.QoSClass = .utility) -> Promise<Void> {
        return Promise<Void> { resolve, reject, _ in
            autoreleasepool {
                let provider = MoyaProvider<WebService>(callbackQueue: DispatchQueue.global(qos: qos))//, plugins: [NetworkLoggerPlugin(verbose: true)])

                let modelClass = model
                let model = "\(model)"

                // Make sure there are records to delete
                let syncRecords = Database.realm!.objects(modelClass).filter("_sync = %@", SyncStatus.deleted.rawValue)
                guard syncRecords.count > 0 else {
                    reject(CommonError.unexpectedError)
                    return
                }

                // Make sure model is not sync locked
                let minuteAgo = Date.init(timeIntervalSinceNow: -SyncController.serverTimeout)
                guard let syncModel = SyncModel.named(model), syncModel.deleteLock < minuteAgo else {
                    reject(CommonError.syncLockError)
                    return
                }

                // Make sure model has permission. Delete always must have authentication
                guard token != nil, modelClass.write == true else {
                    reject(CommonError.permissionError)
                    return
                }

                //var timestamp = Date.distantPast
                Database.update {
                    syncModel.deleteLock = Date()
                }

                let syncRecordsRef = ThreadSafeReference(to: syncRecords)

                provider.request(.delete(version: modelClass.tableVersion, table: modelClass.table, view: modelClass.tableView, accessToken: token!, records: Array(syncRecords))) { result in
                    autoreleasepool {
                        switch result {
                        case let .success(moyaResponse):
                            if moyaResponse.statusCode == 200 {
                                // As long as the status code is a success, we will delete these objects
                                if let syncRecords = Database.realm?.resolve(syncRecordsRef) {
                                    Database.delete(syncRecords, local: true)
                                }
                                
                                resolve(Void())
                            }
                            else if moyaResponse.statusCode == 403 {
                                SyncConfiguration.forbidden(modelName: String(describing: model))
                                reject(CommonError.permissionError)
                            }
                            else {
                                log(error: "Either user was trying to delete records they can't or something went wrong with the server")
                                reject(CommonError.permissionError)
                            }
                        case let .failure(error):
                            log(error: error.errorDescription!)
                            reject(CommonError.networkConnectionError)
                        }

                        if let syncModel = SyncModel.named(model) {
                            Database.update {
                                syncModel.deleteLock = Date.distantPast
                            }
                        }
                    }
                }
            }
        }
    }
}
