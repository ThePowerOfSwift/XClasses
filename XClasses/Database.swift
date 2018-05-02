//
//  RealmHelper.swift
//  Bookbot
//
//  Created by Adrian on 11/2/18.
//  Copyright © 2018 Bookbot. All rights reserved.
//

import Foundation
import Realm
import RealmSwift

// Realm functions
class Database {
    class var realm: Realm? {
        do {
            return try Realm()
        }
        catch {
            log(error: error.localizedDescription)
        }
        return nil
    }

    /// Warning: Do not use if your model is stored in a variable when calling this - it will return an empty result
    class func objects<T: ViewModel>(_ model: T.Type) -> Results<T> {
        return realm!.objects(T.self).filter("_deleted = false")
    }

    /// Return results of query
//    class func find<T: ViewModel>(_ model: T.Type, query: NSPredicate? = nil, orderBy: String? = nil, orderAscending: Bool = false) -> Results<T> {
//        // Realm one day might allow constructed empty results so we can get rid of force unwrapping
//        var results = realm!.objects(T.self).filter(NSPredicate(format: "_deleted = false"))
//        if query != nil {
//            results = results.filter(query!)
//        }
//        if orderBy != nil {
//            results = results.sorted(byKeyPath: orderBy!, ascending: orderAscending)
//        }
//        return results
//    }

    class func add(_ object: Object) {
        guard let realm = realm else {
            return
        }

        do {
            try realm.write {
                realm.add(object)
            }
        }
        catch {
            log(error: error.localizedDescription)
        }
    }

    class func add<S: Sequence>(_ objects: S) where S.Iterator.Element: Object {
        guard let realm = realm else {
            return
        }

        do {
            try realm.write {
                realm.add(objects)
            }
        }
        catch {
            log(error: error.localizedDescription)
        }
    }

    // TODO: be able to sync update objects in a collection (like List or Array)
    class func update(_ object: Any? = nil, block: ()->()) {
        guard let realm = realm else {
            return
        }

        do {
            try realm.write {
                block()

                if let object = object as? ViewModel {
                    object._sync = SyncStatus.updated.rawValue
                }
            }
        }
        catch {
            log(error: error.localizedDescription)
        }
    }

    // TODO: Set the sync for deletes
    class func delete(_ object: Object) {
        guard let realm = realm else {
            return
        }

        do {
            try realm.write {
                realm.delete(object)
            }
        }
        catch {
            log(error: error.localizedDescription)
        }
    }

    class func delete<S: Sequence>(_ objects: S) where S.Iterator.Element: Object {
        guard let realm = realm else {
            return
        }

        do {
            try realm.write {
                realm.delete(objects)
            }
        }
        catch {
            log(error: error.localizedDescription)
        }
    }
}


class RealmString: Object {
    @objc dynamic var stringValue = ""

    class func findOrCreate(_ stringValue: String) -> RealmString {
        if let previousRealmString = Database.realm?.objects(RealmString.self).filter("stringValue = %@", stringValue).first {
            return previousRealmString
        }
        let newString = RealmString(stringValue: stringValue)
        Database.add(newString)
        return newString
    }

    init(stringValue: String) {
        super.init()
        self.stringValue = stringValue
    }

    required init(realm: RLMRealm, schema: RLMObjectSchema) {
        super.init(realm: realm, schema: schema)
    }

    required init() {
        super.init()
    }

    required init(value: Any, schema: RLMSchema) {
        super.init(value: value, schema: schema)
    }
}
