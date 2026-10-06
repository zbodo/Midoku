import SwiftUI

extension View {
    @ViewBuilder
    func midokuReaderPresentation<Item: Identifiable, ReaderContent: View>(
        item: Binding<Item?>,
        request: @escaping (Item) -> ReaderWindowRequest,
        @ViewBuilder content: @escaping (Item) -> ReaderContent
    ) -> some View {
#if targetEnvironment(macCatalyst)
        onChange(of: item.wrappedValue?.id) { _ in
            guard let value = item.wrappedValue else { return }
            CatalystWindowCoordinator.shared.open(request(value))
            item.wrappedValue = nil
        }
#else
        fullScreenCover(item: item, content: content)
#endif
    }

    @ViewBuilder
    func midokuReaderPresentation<ReaderContent: View>(
        isPresented: Binding<Bool>,
        request: @escaping () -> ReaderWindowRequest?,
        @ViewBuilder content: @escaping () -> ReaderContent
    ) -> some View {
#if targetEnvironment(macCatalyst)
        onChange(of: isPresented.wrappedValue) { presented in
            guard presented else { return }
            if let request = request() { CatalystWindowCoordinator.shared.open(request) }
            isPresented.wrappedValue = false
        }
#else
        fullScreenCover(isPresented: isPresented, content: content)
#endif
    }
}
