//
//  ReaderDoublePageViewController.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/19/22.
//

import UIKit

class ReaderDoublePageViewController: BaseObservingViewController {

    enum Direction {
        case rtl
        case ltr
    }

    lazy var zoomView = ZoomableScrollView(frame: view.bounds)
    private let pageStack = UIStackView()
    let firstPageController: ReaderPageViewController
    let secondPageController: ReaderPageViewController

    private lazy var firstReloadButton = UIButton(type: .roundedRect)
    private lazy var secondReloadButton = UIButton(type: .roundedRect)

    var direction: Direction {
        didSet {
            if direction != oldValue {
                pageStack.addArrangedSubview(pageStack.subviews[0])
            }
        }
    }

    private var firstPageSet = false
    private var secondPageSet = false
    private var firstPage: Page?
    private var secondPage: Page?
    private var pageLayoutConstraints: [NSLayoutConstraint] = []
#if targetEnvironment(macCatalyst)
    private var laidOutPageSize = CGSize.zero
#endif

    init(firstPage: ReaderPageViewController, secondPage: ReaderPageViewController, direction: Direction) {
        self.firstPageController = firstPage
        self.secondPageController = secondPage
        self.direction = direction
        super.init()
        self.firstPageController.isInDoublePageController = true
        self.secondPageController.isInDoublePageController = true
    }

    override func configure() {
        updateDoubleTapZoomSetting()
        zoomView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoomView)

        pageStack.axis = .horizontal
        pageStack.distribution = .fillEqually
        pageStack.alignment = .center
        pageStack.translatesAutoresizingMaskIntoConstraints = false
        zoomView.addSubview(pageStack)
        zoomView.zoomView = pageStack

        firstReloadButton.isHidden = true
        firstReloadButton.setTitle(NSLocalizedString("RELOAD"), for: .normal)
        firstReloadButton.addTarget(self, action: #selector(reload(_:)), for: .touchUpInside)
        firstReloadButton.configuration = .borderless()
        firstReloadButton.configuration?.contentInsets = .init(top: 15, leading: 15, bottom: 15, trailing: 15)
        firstReloadButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(firstReloadButton)

        secondReloadButton.isHidden = true
        secondReloadButton.setTitle(NSLocalizedString("RELOAD"), for: .normal)
        secondReloadButton.addTarget(self, action: #selector(reload(_:)), for: .touchUpInside)
        secondReloadButton.configuration = .borderless()
        secondReloadButton.configuration?.contentInsets = .init(top: 15, leading: 15, bottom: 15, trailing: 15)
        secondReloadButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(secondReloadButton)
    }

    override func constrain() {
        NSLayoutConstraint.activate([
            zoomView.topAnchor.constraint(equalTo: view.topAnchor),
            zoomView.leftAnchor.constraint(equalTo: view.leftAnchor),
            zoomView.rightAnchor.constraint(equalTo: view.rightAnchor),
            zoomView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            pageStackWidthConstraint,
            pageStack.heightAnchor.constraint(equalTo: zoomView.heightAnchor),
            pageStack.centerXAnchor.constraint(equalTo: zoomView.centerXAnchor),
            pageStack.centerYAnchor.constraint(equalTo: zoomView.centerYAnchor)
        ])

        guard
            let firstPageView = firstPageController.pageView,
            let secondPageView = secondPageController.pageView
        else {
            return
        }

        pageLayoutConstraints = [
            pageWidthConstraint(for: firstPageView),
            firstPageView.heightAnchor.constraint(equalTo: pageStack.heightAnchor),
            pageWidthConstraint(for: secondPageView),
            secondPageView.heightAnchor.constraint(equalTo: pageStack.heightAnchor),

            firstReloadButton.centerXAnchor.constraint(equalTo: firstPageView.centerXAnchor),
            firstReloadButton.centerYAnchor.constraint(equalTo: firstPageView.centerYAnchor),

            secondReloadButton.centerXAnchor.constraint(equalTo: secondPageView.centerXAnchor),
            secondReloadButton.centerYAnchor.constraint(equalTo: secondPageView.centerYAnchor)
        ]
    }

    private var pageStackWidthConstraint: NSLayoutConstraint {
#if targetEnvironment(macCatalyst)
        pageStack.widthAnchor.constraint(equalTo: zoomView.widthAnchor)
#else
        pageStack.widthAnchor.constraint(lessThanOrEqualTo: zoomView.widthAnchor)
#endif
    }

    private func pageWidthConstraint(for page: ReaderPageView) -> NSLayoutConstraint {
#if targetEnvironment(macCatalyst)
        page.widthAnchor.constraint(equalTo: pageStack.widthAnchor, multiplier: 0.5)
#else
        page.widthAnchor.constraint(equalTo: page.imageView.widthAnchor)
#endif
    }

    override func observe() {
        for key in [
            "Reader.disableDoubleTap",
            AppSettings.dictionary.enable.key,
            AppSettings.dictionary.lookupGesture.key,
            AppSettings.dictionary.restrictOCRLanguages.key,
            AppSettings.dictionary.restrictedOCRLanguages.key
        ] {
            addObserver(forName: key) { [weak self] _ in
                self?.updateDoubleTapZoomSetting()
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard
            let firstPageView = firstPageController.pageView,
            let secondPageView = secondPageController.pageView
        else { return }

        firstPageController.zoomView?.setZoomScale(1, animated: false)
        secondPageController.zoomView?.setZoomScale(1, animated: false)

        if
            !firstPageView.isDescendant(of: pageStack)
                || !secondPageView.isDescendant(of: pageStack)
        {
            for view in pageStack.arrangedSubviews {
                pageStack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }

            for controller in [firstPageController, secondPageController] {
                NSLayoutConstraint.deactivate(controller.doublePageRestorationConstraints)
                controller.doublePageRestorationConstraints = []
                if let pageView = controller.pageView, pageView.superview !== pageStack {
                    pageView.removeFromSuperview()
                }
                controller.isInDoublePageController = true
            }

            let orderedViews = direction == .ltr
                ? [firstPageView, secondPageView]
                : [secondPageView, firstPageView]
            for view in orderedViews {
                pageStack.addArrangedSubview(view)
            }
        }
        NSLayoutConstraint.activate(pageLayoutConstraints)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NSLayoutConstraint.deactivate(pageLayoutConstraints)
        for controller in [firstPageController, secondPageController] {
            guard
                let pageView = controller.pageView,
                let zoomView = controller.zoomView,
                pageView.isDescendant(of: pageStack)
            else { continue }
            controller.isInDoublePageController = false
            pageStack.removeArrangedSubview(pageView)
            pageView.removeFromSuperview()
            zoomView.addSubview(pageView)
            pageView.translatesAutoresizingMaskIntoConstraints = false
            let constraints = [
                pageView.widthAnchor.constraint(equalTo: zoomView.widthAnchor),
                pageView.heightAnchor.constraint(equalTo: zoomView.heightAnchor)
            ]
            NSLayoutConstraint.activate(constraints)
            controller.doublePageRestorationConstraints = constraints
        }
    }

#if targetEnvironment(macCatalyst)
    func prepareForSlide() {
        NSLayoutConstraint.deactivate(pageLayoutConstraints)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Image processing may finish before its half-width slot has been laid out.
        guard let size = firstPageController.pageView?.bounds.size,
              size.width > 0, size != laidOutPageSize else { return }
        laidOutPageSize = size
        firstPageController.pageView?.fixImageSize()
        secondPageController.pageView?.fixImageSize()
    }
#endif

    // TODO: fix `SWIFT TASK CONTINUATION MISUSE: setPageImage(url:sourceId:) leaked its continuation!`
    func setPage(_ page: Page, sourceId: String? = nil, for pos: ReaderPagedViewController.PagePosition) {
        let pageView: ReaderPageView?
        let reloadButton: UIButton
        switch pos {
            case .first:
                firstPageSet = true
                firstPage = page
                pageView = firstPageController.pageView
                reloadButton = firstReloadButton
            case .second:
                secondPageSet = true
                secondPage = page
                pageView = secondPageController.pageView
                reloadButton = secondReloadButton
        }
        guard let pageView = pageView else {
            return
        }
        updateDoubleTapZoomSetting()
        Task {
            let result = await pageView.setPage(page, sourceId: sourceId)
            if !result {
                if pos == .first {
                    firstPageSet = false
                } else {
                    secondPageSet = false
                }
                reloadButton.isHidden = false
            } else {
                reloadButton.isHidden = true
            }
        }
    }

    @objc func reload(_ sender: UIButton) {
        if sender == firstReloadButton {
            guard let firstPageView = firstPageController.pageView else { return }
            firstReloadButton.isHidden = true
            firstPageView.progressView.setProgress(value: 0, withAnimation: false)
            firstPageView.progressView.isHidden = false
            if let firstPage = firstPage {
                setPage(firstPage, for: .first)
            }
        } else {
            guard let secondPageView = secondPageController.pageView else { return }
            secondReloadButton.isHidden = true
            secondPageView.progressView.setProgress(value: 0, withAnimation: false)
            secondPageView.progressView.isHidden = false
            if let secondPage = secondPage {
                setPage(secondPage, for: .second)
            }
        }
    }

    private func updateDoubleTapZoomSetting() {
        let disabled = AppSettings.dictionary.isReaderDoubleTapDisabled(language: firstPage?.language)
            && AppSettings.dictionary.isReaderDoubleTapDisabled(language: secondPage?.language)
        zoomView.doubleTapEnabled = !disabled
    }
}
