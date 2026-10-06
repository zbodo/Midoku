//
//  SceneDelegate.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 12/29/21.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    private static let bannerHeight: CGFloat = 30

    var window: UIWindow?
    private var incognitoBannerView: UIView?

    var totalBannerHeight: CGFloat {
        incognitoBannerView?.frame.height ?? 0
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let windowScene = scene as? UIWindowScene {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = TabBarController()
            window.tintColor = .systemPink

            if AppSettings.appearance.useSystemAppearance.get() {
                window.overrideUserInterfaceStyle = .unspecified
            } else {
                if AppSettings.appearance.appearance.get() == 0 {
                    window.overrideUserInterfaceStyle = .light
                } else {
                    window.overrideUserInterfaceStyle = .dark
                }
            }

            self.window = window
#if targetEnvironment(macCatalyst)
            if let mainWindow = CatalystWindowCoordinator.shared.mainWindow,
               let mainSession = mainWindow.windowScene?.session {
                UIApplication.shared.requestSceneSessionActivation(mainSession, userActivity: nil, options: nil)
                UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
                self.window = nil
                return
            }
            CatalystWindowCoordinator.shared.mainWindow = window
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 640, height: 480)
#endif
            window.makeKeyAndVisible()
#if targetEnvironment(macCatalyst)
            CatalystWindowCoordinator.shared.mainWindowConnected(window)
#endif

            let incognitoBannerView = IncognitoBannerView()
            self.incognitoBannerView = incognitoBannerView
            incognitoBannerView.translatesAutoresizingMaskIntoConstraints = false
            window.insertSubview(incognitoBannerView, at: 0)

            NSLayoutConstraint.activate([
                incognitoBannerView.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                incognitoBannerView.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                incognitoBannerView.topAnchor.constraint(equalTo: window.topAnchor),
                incognitoBannerView.bottomAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: Self.bannerHeight)
            ])
        }

        if let url = connectionOptions.urlContexts.first?.url {
            UIApplication.shared.appDelegate?.handleUrl(url: url)
        }
    }

    let contentHideView: UIView = {
        let view = UIView(frame: UIScreen.main.bounds)
        view.backgroundColor = .systemBackground
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return view
    }()

    func sceneDidDisconnect(_ scene: UIScene) {
#if targetEnvironment(macCatalyst)
        if CatalystWindowCoordinator.shared.mainWindow === window {
            CatalystWindowCoordinator.shared.mainWindow = nil
        }
#endif
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        contentHideView.removeFromSuperview()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        contentHideView.removeFromSuperview()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        if AppSettings.general.incognitoMode.get() {
            (scene as? UIWindowScene)?.windows.first?.addSubview(contentHideView)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url {
            UIApplication.shared.appDelegate?.handleUrl(url: url)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdate previousCoordinateSpace: any UICoordinateSpace,
        interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
        traitCollection previousTraitCollection: UITraitCollection
    ) {
        let newOrientation = if #available(iOS 16.0, *) {
            windowScene.effectiveGeometry.interfaceOrientation
        } else {
            windowScene.interfaceOrientation
        }
        guard newOrientation != previousInterfaceOrientation else { return }
        NotificationCenter.default.post(name: .orientationDidChange, object: newOrientation)
    }
}
