import AidokuRunner
import SwiftUI
import WebKit

struct NativeSourceWebsite: View {
    let sourceKey: String
    @EnvironmentObject private var sources: SourceStore
    @State private var url: URL?
    @State private var error: String?
    @State private var runtime: AidokuRunner.Source?
    @State private var message: String?
    var body: some View {
        Group {
            if let url {
                SourceWebView(sourceKey: sourceKey, url: url)
            } else if let error {
                ContentUnavailableView("Website Unavailable", systemImage: "globe", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Source Website / Sign In")
        .toolbar {
            Button("Complete Sign In") {
                Task {
                    guard let runtime else { return }
                    do {
                        let cookies = await SourceHTTP.cookies(for: sourceKey)
                        let values = cookies.reduce(into: [String: String]()) { $0[$1.name] = $1.value }
                        func loginItems(_ items: [AidokuRunner.Setting]) -> [AidokuRunner.Setting] {
                            items.flatMap { item in
                                switch item.value {
                                case .group(let group): return loginItems(group.items)
                                case .page(let page): return loginItems(page.items)
                                case .login: return [item]
                                default: return []
                                }
                            }
                        }
                        for setting in loginItems(try await runtime.getSettings()) {
                            if case .login(let value) = setting.value, value.method == .web {
                                guard try await runtime.handleWebLogin(key: setting.key, cookies: values) else {
                                    message = "Sign in failed."
                                    return
                                }
                                SettingsStore.shared.set(key: sourceKey + "." + setting.key, value: "logged_in")
                            }
                        }
                        message = "Cookies saved. Return to Sources or Chapters and refresh."
                    } catch { message = error.localizedDescription }
                }
            }
        }
        .alert("Source Sign In", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .task {
            do {
                let source = try await sources.source(sourceKey)
                runtime = source
                let selected: String = SettingsStore.shared.get(key: sourceKey + ".url")
                url =
                    URL(string: selected).flatMap {
                        ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil
                    } ?? source.urls.first
                if url == nil { error = "This source has no website URL." }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct SourceWebView: NSViewRepresentable {
    let sourceKey: String
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .forSource(key: sourceKey)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = SourceHTTP.userAgent
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
