//
//  PDFDocument.swift
//  
//
//  Created by Adrian on 3/12/16.
//  Copyright © 2016 Adrian DeWitts. All rights reserved.
//

import UIKit
import Hydra

protocol PDFPageDelegate {
    var _index: Int { get }
    var pdfDocument: PDFDocument { get }
}

enum PDFError: Error {
    case pageNotReady
}

class PDFDocument {
    let cachedImages = NSCache<NSNumber, UIImage>()
    var pdfDocument: CGPDFDocument?
    var firstRetry: Date?

    init(url: URL) {
        pdfDocument = CGPDFDocument(url as CFURL)
        cachedImages.countLimit = 5
    }


    func pdfPageImage(at index: Int, size: CGSize = UIScreen.main.bounds.size) -> Promise<UIImage> {
        return Promise<UIImage>(in: .main) { resolve, reject in
            self.cachePages(index: index, size: size)
            if let image = self.cachedImages.object(forKey: NSNumber(value: index)) {
                resolve(image)
            }
            else {
                // Delay rejection so it can be retried periodically
                Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { timer in
                    reject(PDFError.pageNotReady)
                }
            }
        }
    }

    func cachePages(index: Int, size: CGSize = UIScreen.main.bounds.size) {
        cachePage(index: index, size: size)
        
        let queue = DispatchQueue(label: "caching")
        queue.async {
            self.cachePage(index: index + 1, size: size)
            self.cachePage(index: index - 1, size: size)
        }
    }

    func cachePage(index: Int, size: CGSize = UIScreen.main.bounds.size) {
        let n = NSNumber(value: index)
        let cachedImage = cachedImages.object(forKey: n)
        // TODO: if Sizes are different then recache
        guard index >= 0, index < pdfDocument!.numberOfPages, cachedImage == nil else {
            return
        }

        if let image = pdfDocument?.imageFromPage(number: index + 1, with: size) {
            cachedImages.setObject(image, forKey: n)
        }
    }

    func resetCache() {
        cachedImages.removeAllObjects()
    }
}
