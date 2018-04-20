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

func getRealm() -> Realm? {
    do {
        return try Realm()
    }
    catch {
        log(error: error.localizedDescription)
    }
    return nil
}

/// Return results of query
func find<T: ViewModel>(_ model: T.Type, query: NSPredicate? = nil, orderBy: String? = nil, orderAscending: Bool = false) -> Results<T> {
    // Realm one day might allow constructed empty results so we can get rid of force unwrapping
    let realm = getRealm()!
    var result = realm.objects(T.self).filter(NSPredicate(format: "_deleted = false"))
    if query != nil {
        result = result.filter(query!)
    }
    if orderBy != nil {
        result = result.sorted(byKeyPath: orderBy!, ascending: orderAscending)
    }
    return result
}

func add(_ object: Object) {
    guard let realm = getRealm() else {
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

func add<S: Sequence>(_ objects: S) where S.Iterator.Element: Object {
    guard let realm = getRealm() else {
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

func update(block: ()->()) {
    guard let realm = getRealm() else {
        return
    }

    do {
        try realm.write {
            block()
        }
    }
    catch {
        log(error: error.localizedDescription)
    }
}

func delete(_ object: Object) {
    guard let realm = getRealm() else {
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

func delete<S: Sequence>(_ objects: S) where S.Iterator.Element: Object {
    guard let realm = getRealm() else {
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

func resolveRealm<T: Object>(_ reference: ThreadSafeReference<T>) -> T? {
    guard let realm = getRealm() else {
        return nil
    }

    return realm.resolve(reference)
}

class RealmString: Object {
    @objc dynamic var stringValue = ""

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
