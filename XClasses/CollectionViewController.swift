//
//  CollectionViewController.swift
//  Bookbot
//
//  Created by Adrian on 17/8/17.
//  Copyright © 2017 Bookbot. All rights reserved.
//

import UIKit
import IGListKit
import Nuke
import RealmSwift

//TODO: Autolayout for cells. At the moment we calculate the size

class CollectionViewController: UIViewController, ListAdapterDataSource, ListWorkingRangeDelegate, ViewModelManagerDelegate {
    @IBOutlet var emptyView: UIView?
    @IBOutlet var collectionView: UICollectionView!
    var viewModel = ViewModel() as ViewModelDelegate
    var viewModelCollection: Array<ViewModelDelegate> = []
    var notificationToken: NotificationToken? = nil
    var reuseIdentifier: String { return "Cell" }
    var workingRange: Int { return 20 }
    lazy var adapter: ListAdapter = {
        return ListAdapter(updater: ListAdapterUpdater(), viewController: self, workingRangeSize: workingRange)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        viewModel = pullViewModel(viewModel: viewModel)

        adapter.collectionView = collectionView
        adapter.dataSource = self as ListAdapterDataSource

        if let relatedRealmCollection = viewModel.relatedCollection as? Results<ViewModel> {
            notificationToken = relatedRealmCollection.observe { changes in
                switch changes {
                case .initial, .update:
                    self.viewModelCollection = Array(relatedRealmCollection)
                    self.adapter.performUpdates(animated: true)
                case .error(let error):
                    log(error: error as! String)
                }
            }
        } else if viewModel.relatedCollection is Array<ViewModelDelegate> {
            viewModelCollection = viewModel.relatedCollection as! Array<ViewModelDelegate>
        }
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?)
    {
        XUIFlowController.sharedInstance.viewModel = (sender as! CollectionViewCell).viewModel
    }

    func objects(for listAdapter: ListAdapter) -> [ListDiffable] {
        return viewModelCollection as! [ListDiffable]
    }

    func listAdapter(_ listAdapter: ListAdapter, sectionControllerFor object: Any) -> ListSectionController {
        return DefaultSectionController(viewModel: object as! ViewModel)
    }

    func emptyView(for listAdapter: ListAdapter) -> UIView? {
        return emptyView
    }

    func listAdapter(_ listAdapter: ListAdapter, sectionControllerWillEnterWorkingRange sectionController: ListSectionController) {
        // TODO: Warm up images
    }

    func listAdapter(_ listAdapter: ListAdapter, sectionControllerDidExitWorkingRange sectionController: ListSectionController) {
        // Nothing to do
    }
}

enum Axis {
    case x, y
}

class DefaultSectionController: ListSectionController {
    var viewModel: ViewModelDelegate

    // Sets which axis is a constant (the other axis will be variable)
    var lockAxis: Axis { return .x }
    // Changes the cell size to fit on the width or height of the collection view
    var fitToAxis: Bool { return true }
    var sectionInset: UIEdgeInsets { return UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0) }
    var preferredCellSize: CGSize { return CGSize(width: 150.0, height: 150.0) }

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
        super.init()

//        let collectionViewController = viewController as! CollectionViewController
//        let flowLayout = collectionViewController.collectionView.collectionViewLayout as! ListCollectionViewLayout
        self.inset = sectionInset
    }

    override func sizeForItem(at index: Int) -> CGSize {
        let collectionViewController = viewController as! CollectionViewController
        let collectionViewSize = collectionViewController.collectionView.bounds.size

        var cellSize = preferredCellSize

        if fitToAxis {
            var resizer: CGFloat = 0.0

            if lockAxis == .x {
                let spacing = sectionInset.left + sectionInset.right
                let cellAndSpacingWidth = preferredCellSize.width + spacing
                let numberOfCells = floor(collectionViewSize.width / cellAndSpacingWidth)
                let widthSansSpacing = collectionViewSize.width - (spacing * numberOfCells)
                let widthCells = preferredCellSize.width * numberOfCells
                resizer = widthSansSpacing / widthCells

            }
            else if lockAxis == .y {
                let spacing = sectionInset.top + sectionInset.bottom
                let cellAndSpacingHeight = preferredCellSize.height + spacing
                let numberOfCells = floor(collectionViewSize.height / cellAndSpacingHeight)
                let heightSansSpacing = collectionViewSize.height - (spacing * numberOfCells)
                let heightCells = preferredCellSize.height * numberOfCells
                resizer = heightSansSpacing / heightCells
            }

            cellSize.width = preferredCellSize.width * resizer
            cellSize.height = preferredCellSize.height * resizer
        }

        return cellSize
    }

    override func cellForItem(at index: Int) -> UICollectionViewCell {
        let cell = collectionContext!.dequeueReusableCellFromStoryboard(withIdentifier: "Cell", for: self, at: index) as! CollectionViewCell
        cell.assignViewModelToView(viewModel: viewModel)
        return cell
    }
}

class CollectionViewCell: UICollectionViewCell, ViewModelManagerDelegate
{
    var viewModel = ViewModel() as ViewModelDelegate
    @IBOutlet var imageView: XUIImageView!

    func assignViewModelToView(viewModel: ViewModelDelegate)
    {
        self.viewModel = viewModel
        let properties = viewModel.properties
        if let imagePath = properties["image"]
        {
            imageView.contentMode = UIViewContentMode.scaleAspectFit
            Nuke.loadImage(with: URL(string: imagePath)!, into: imageView)
        }
    }
}
