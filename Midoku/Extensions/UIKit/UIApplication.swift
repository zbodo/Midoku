//
//  UIApplication.swift
//  Aidoku
//
//  Created by Skitty on 8/18/23.
//

import UIKit

extension UIApplication {
    var firstKeyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .compactMap(\.keyWindow)
            .first
    }

    var mainWindow: UIWindow? {
#if targetEnvironment(macCatalyst)
        CatalystWindowCoordinator.shared.mainWindow
#else
        firstKeyWindow
#endif
    }

    func updateWindowAppearance() {
        let style: UIUserInterfaceStyle = AppSettings.appearance.useSystemAppearance.get()
            ? .unspecified : (AppSettings.appearance.appearance.get() == 0 ? .light : .dark)
        for scene in connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }

    var appDelegate: AppDelegate? {
        delegate as? AppDelegate
    }
}
