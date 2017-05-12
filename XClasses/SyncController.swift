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

protocol SyncControllerDelegate
{
    func belatedResponse(response: [ViewModel], error: String)
}

public class SyncModel: Object
{
    dynamic var modelName = ""
    dynamic var serverSync: Date? = nil // Server timestamp of last server sync. To be used on next sync request
    dynamic var readLock = Date.distantPast
    dynamic var writeLock = Date.distantPast
}

public class SyncController
{
    static let sharedInstance = SyncController()
    var controllers = [String:String]()
    var token = ""

    func configure(models: [AnyClass])
    {
        let realm = try! Realm()

        for m in models
        {
            let model = "\(m)"

            if realm.objects(SyncModel.self).filter("modelName = '\(model)'").count == 0
            {
                try! realm.write { realm.add(SyncModel(value: ["modelName": model])) }
            }
        }
    }

    func sync(models: [AnyClass])
    {
        let user = FIRAuth.auth()?.currentUser
        if let user = user
        {
            user.getTokenWithCompletion() {
                token, error in
                if let error = error
                {
                    print(error)
                    return
                }

                self.token = token!
                self.writeSync(models: models, token: token!)
            }
        }
        else
        {
            self.readSync(models: models, token: "")
        }
    }

    func writeSync(models: [AnyClass], token: String)
    {
        let realm = try! Realm()
        let provider = MoyaProvider<WebService>()

        //let a = Homophone(value: ["homophone": "there their they're", "_sync": SyncStatus.updated.rawValue])
        //let b = Homophone(value: ["homophone": "one two"])
        //try! realm.write { realm.add(a); realm.add(b) }

//        let a = Homophone()
//        try! realm.write { a["homophone"] = "blah, blah, blah"; realm.add(a); }
//
//
//        print(realm.objects(Homophone.self))

        for m in models
        {
            let modelClass = m as! ViewModel.Type
            let model = "\(m)"
            // Mark: This section handles the writes to server DB
            // Check if class is read only, has a writelock (max 1 minute), and has something to write
            if modelClass.readOnly() == false
            {
                let minuteAgo = Date.init(timeIntervalSinceNow: -60.0)
                var predicate = NSPredicate(format: "modelName = '\(model)' AND writeLock < %@", minuteAgo as CVarArg)
                if let syncModel = realm.objects(SyncModel.self).filter(predicate).first
                {
                    try! realm.write { syncModel.writeLock = Date() }
                    predicate = NSPredicate(format: "_sync = \(SyncStatus.created.rawValue) OR _sync = \(SyncStatus.updated.rawValue)")
                    let toSave = realm.objects(modelClass).filter(predicate)

                    if toSave.count > 0
                    {
                        provider.request(.createAndUpdate(version: modelClass.tableVersion(), table: modelClass.table(), view: modelClass.tableView(), accessToken: token, records: Array(toSave)))
                        { result in
                            switch result {
                            case let .success(moyaResponse):
                                if moyaResponse.statusCode == 200
                                {
                                    do
                                    {
                                        let response = try moyaResponse.mapString()
                                        let lines = response.components(separatedBy: "\n").dropFirst()
                                        for line in lines
                                        {
                                            let components = line.components(separatedBy: "|")
                                            let id = Int(components[0])!
                                            let cid = components[1]
                                            predicate = NSPredicate(format: "id = \(id) OR clientId = '\(cid)'")
                                            let item = toSave.filter(predicate).first!
                                            try! realm.write {
                                                item.id = id
                                                item._sync = SyncStatus.current.rawValue
                                            }
                                        }
                                    }
                                    catch { self.log(error: "Response was impossibly incorrect") }
                                }
                                else
                                {
                                    // TODO: if 403 show login modal
                                    self.log(error: "Server returned status code \(moyaResponse.statusCode)")
                                    Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false, block: { timer in self.sync(models: models)})
                                }
                            case let .failure(error):
                                self.log(error: "Server connectivity error\(error)")
                                Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false, block: { timer in self.sync(models: models)})
                            }

                        }

                        // Delete records section
                        predicate = NSPredicate(format: "_sync = \(SyncStatus.deleted.rawValue)")
                        let toDelete = realm.objects(modelClass).filter(predicate)
                        if toDelete.count > 0
                        {
                            provider.request(.delete(version: modelClass.tableVersion(), table: modelClass.table(), view: modelClass.tableView(), accessToken: token, records: Array(toDelete)))
                            { result in
                                switch result {
                                case let .success(moyaResponse):
                                    if moyaResponse.statusCode == 200
                                    {
                                        // As long as the status code is a success, will delete these objects
                                        try! realm.write { realm.delete(toDelete) }
                                    }
                                    else
                                    {
                                        self.log(error: "Either user was trying to delete records they can't or something went wrong with the server")
                                    }
                                case let .failure(error):
                                    self.log(error: "Server connectivity error\(error)")
                                    Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false, block: { timer in self.sync(models: models)})
                                }
                            }
                        }

                        try! realm.write { syncModel.writeLock = Date.distantPast }
                    }
                }
            }
        }

        print(Realm.Configuration.defaultConfiguration.fileURL ?? "No DB")
    }

    func readSync(models: [AnyClass], token: String)
    {
        let realm = try! Realm()
        let provider = MoyaProvider<WebService>()

        for m in models
        {
            let modelClass = m as! ViewModel.Type
            let model = "\(m)"

            let minuteAgo = Date.init(timeIntervalSinceNow: -60.0)
            var predicate = NSPredicate(format: "modelName = '\(model)' AND readLock < %@", minuteAgo as CVarArg)
            if let syncModel = realm.objects(SyncModel.self).filter(predicate).first
            {
                var timestamp = Date.distantPast
                try! realm.write { syncModel.readLock = Date() }

                provider.request(.read(version: modelClass.tableVersion(), table: modelClass.table(), view: modelClass.tableView(), accessToken: token, lastTimestamp: syncModel.serverSync, predicate: nil))
                { result in
                    switch result {
                    case let .success(moyaResponse):
                        if moyaResponse.statusCode == 200
                        {
                            do
                            {
                                let response = try moyaResponse.mapString()
                                let l = response.components(separatedBy: "\n")
                                let meta = l[0].components(separatedBy: "|")
                                timestamp = Date.from(UTCString: meta[1])!
                                let h = l[1].components(separatedBy: "|")
                                let header = h.map { $0.camelCase() }
                                let lines = l.dropFirst(2)
                                let idIndex = header.index(of: "id")!
                                for line in lines
                                {
                                    let components = line.components(separatedBy: "|")
                                    let id = components[idIndex]
                                    predicate = NSPredicate(format: "id = \(id)")

                                    var dict = [String: String]()
                                    for (index, property) in header.enumerated()
                                    {
                                        dict[property] = components[index]
                                    }

                                    let records = realm.objects(modelClass).filter(predicate)
                                    if (dict["delete"] == nil) || (dict["delete"] != "true")
                                    {
                                        if records.count > 0
                                        {
                                            records.first!.importProperties(dictionary: dict, isNew:false)
                                        }
                                        else
                                        {
                                            let record = modelClass.init()
                                            record.importProperties(dictionary: dict, isNew: true)
                                        }
                                    }
                                    else
                                    {
                                        try! realm.write {
                                            realm.delete(records.first!)
                                        }
                                    }
                                }
                            }
                            catch { self.log(error: "Response was impossibly incorrect") }
                        }
                        else
                        {
                            // TODO: if 403 show login modal
                            self.log(error: "Server returned status code \(moyaResponse.statusCode)")
                            Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false, block: { timer in self.sync(models: models)})
                        }
                    case let .failure(error):
                        self.log(error: "Server connectivity error\(error)")
                        Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false, block: { timer in self.sync(models: models)})
                    }
                }

                try! realm.write {
                    syncModel.readLock = Date.distantPast
                    syncModel.serverSync = timestamp
                }
            }
        }
    }

    func query(model: AnyClass, query: NSPredicate, order: String, controller: SyncControllerDelegate, freshness: Int = 3600) -> ([ViewModel], String)
    {

        // Data is fresh - respond from DB (1 hour freshness max default)
        // Data is not fresh - sync with server
        // Data is empty - do not set 3 second timer
        // Data sync has not resolved in 3 seconds, check for reachability
        // if no reachability return list from DB and alert there is no reachability
        return ([ViewModel()], "")
    }

    func log(error: String)
    {
        FIRAnalytics.logEvent(withName: "iOS Error", parameters: ["name": "Sync error" as NSObject, "error": error as NSObject])
    }

    // TODO: will search on server and cache these queries in a different Realm DB
    // func directQuery(model: AnyClass, query: NSPredicate, order: String, controller: SyncControllerDelegate, freshness: Int = 3600) -> ([ViewModel], String)
    // 
}



// Sync manager request - is DB ready (updated in last 24 hours - set period)? yes respond immediately. no, if first time wait for response (also display error if no network, or there is a problem). no wait 3 second for response, then respond. if response earlier, display.
// Sync manager (sync only) - first time/on app open, immediate change (silent push or record update on client from controller)
//
// Config per model
// Removal - periodically - when a certain age, only when deleted
// File upload - immediately, triggered
// Allowed last sync (Freshness) - 1 hour (periodic), has to be fresh

// Sync tables: all, user_space.
// Search - out of the userspace scope would user a different view server side, and a different DB (same model on the client side) -- use a different method
