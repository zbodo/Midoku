#if targetEnvironment(macCatalyst)
import UIKit

@MainActor
final class CatalystWindowCoordinator {
    static let shared = CatalystWindowCoordinator()
    weak var mainWindow: UIWindow?
    weak var readerScene: ReaderSceneDelegate?
    private var openingMain = false
    private var pendingTab: Int?
    private var pendingURLs: [URL] = []
    private var pendingRequest: ReaderWindowRequest?
    private var openingReader = false

    func open(_ request: ReaderWindowRequest) {
        if let readerScene, let session = readerScene.window?.windowScene?.session {
            readerScene.show(request)
            UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil) { error in
                LogManager.logger.error("Unable to activate reader: \(error.localizedDescription)")
            }
            return
        }
        pendingRequest = request
        guard !openingReader else { return }
        openingReader = true
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: request.activity, options: nil) { [weak self] error in
            self?.openingReader = false
            self?.pendingRequest = nil
            UIApplication.shared.appDelegate?.presentAlert(title: NSLocalizedString("DESKTOP_WINDOW_ERROR"), message: error.localizedDescription)
        }
    }

    func connect(_ scene: ReaderSceneDelegate, activity: NSUserActivity?) {
        openingReader = false
        if let existing = readerScene, existing !== scene,
           let session = existing.window?.windowScene?.session {
            if let request = pendingRequest ?? ReaderWindowRequest(activity: activity) { existing.show(request) }
            pendingRequest = nil
            UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil)
            scene.closeReader()
            return
        }
        readerScene = scene
        if let request = pendingRequest ?? ReaderWindowRequest(activity: activity) {
            pendingRequest = nil
            scene.show(request)
        } else {
            scene.closeReader()
            showLibrary()
        }
    }

    func routeToLibrary(_ url: URL) {
        pendingURLs.append(url)
        showLibrary()
    }

    func mainWindowConnected(_ window: UIWindow) {
        mainWindow = window
        openingMain = false
        if let pendingTab { (window.rootViewController as? TabBarController)?.selectedIndex = pendingTab }
        pendingTab = nil
        let urls = pendingURLs
        pendingURLs.removeAll()
        for url in urls { UIApplication.shared.appDelegate?.handleUrl(url: url) }
    }

    func showMainTab(_ index: Int) {
        if let tab = mainWindow?.rootViewController as? TabBarController {
            tab.selectedIndex = index
        } else {
            pendingTab = index
        }
        showLibrary()
    }

    func showLibrary() {
        let session = mainWindow?.windowScene?.session
        if session == nil {
            guard !openingMain else { return }
            openingMain = true
        }
        UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil) { [weak self] error in
            self?.openingMain = false
            LogManager.logger.error("Unable to open library: \(error.localizedDescription)")
        }
    }
}

final class ReaderSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var navigation: ReaderNavigationController?
    private var pendingShow: Task<Void, Never>?
    private var closing = false
    private let privacyView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBackground
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return view
    }()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        scene.sizeRestrictions?.minimumSize = CGSize(width: 360, height: 320)
        let window = UIWindow(windowScene: scene)
        window.tintColor = .systemPink
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        CatalystWindowCoordinator.shared.connect(self, activity: options.userActivities.first ?? session.stateRestorationActivity)
    }

    func show(_ request: ReaderWindowRequest) {
        guard !closing else { return }
        let previous = pendingShow
        pendingShow = Task { [weak self] in
            await previous?.value
            guard let self, !self.closing else { return }
            if let current = self.navigation?.readerViewController,
               current.manga.identifier == request.manga.identifier,
               current.chapter.key == request.chapter.key, request.startPage == nil {
                return
            }
            await self.navigation?.readerViewController.finishDesktopSession()
            await SourceManager.shared.waitForSourcesLoad()
            guard !self.closing else { return }
            let source = SourceManager.shared.store.source(for: request.manga.sourceKey)
            let reader = ReaderViewController(source: source, manga: request.manga, chapter: request.chapter, startPage: request.startPage)
            let navigation = ReaderNavigationController(readerViewController: reader)
            self.navigation = navigation
            self.window?.rootViewController = navigation
            self.window?.windowScene?.title = request.manga.title
            self.window?.windowScene?.userActivity = request.activity
            self.updateAppearance()
        }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            if CatalystWindowCoordinator.shared.mainWindow == nil {
                CatalystWindowCoordinator.shared.routeToLibrary(context.url)
            } else {
                CatalystWindowCoordinator.shared.showLibrary()
                UIApplication.shared.appDelegate?.handleUrl(url: context.url)
            }
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if let request = ReaderWindowRequest(activity: userActivity) { show(request) }
    }

    func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
        navigation?.readerViewController.desktopWindowRequest.activity
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        privacyView.removeFromSuperview()
        updateAppearance()
    }

    func sceneWillEnterForeground(_ scene: UIScene) { privacyView.removeFromSuperview() }

    func sceneDidEnterBackground(_ scene: UIScene) {
        if AppSettings.general.incognitoMode.get(), let window {
            privacyView.frame = window.bounds
            window.addSubview(privacyView)
        }
    }

    private func updateAppearance() {
        window?.overrideUserInterfaceStyle = AppSettings.appearance.useSystemAppearance.get()
            ? .unspecified : (AppSettings.appearance.appearance.get() == 0 ? .light : .dark)
    }

    func closeReader() {
        guard !closing else { return }
        closing = true
        Task {
            await pendingShow?.value
            await navigation?.readerViewController.finishDesktopSession()
            guard let session = window?.windowScene?.session else { return }
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { [weak self] error in
                self?.closing = false
                if let self, let request = self.navigation?.readerViewController.desktopWindowRequest { self.show(request) }
                LogManager.logger.error("Unable to close reader: \(error.localizedDescription)")
            }
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        closing = true
        // Retain the controller until progress and deferred download cleanup have finished.
        let reader = navigation?.readerViewController
        Task { await reader?.finishDesktopSession() }
        if CatalystWindowCoordinator.shared.readerScene === self {
            CatalystWindowCoordinator.shared.readerScene = nil
        }
    }
}
#endif
