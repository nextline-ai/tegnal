import SwiftUI

/// A modal is a new hosting root. Supply its required models on the content
/// itself, before SwiftUI evaluates presentation preferences. The build 16 Mac
/// crash trapped in EnvironmentValues.subscript during that evaluation; these
/// required models must not depend on automatic inheritance across a modal.
struct AppPresentationRoot<Content: View>: View {
    let environment: AppEnvironment
    let content: Content

    var body: some View {
        content.environment(environment).environment(environment.booru)
    }
}

private enum AppPresentationStyle { case sheet, fullScreen }

private struct AppBooleanPresentation<Presented: View>: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Binding var isPresented: Bool
    let style: AppPresentationStyle
    let onDismiss: (() -> Void)?
    let presented: () -> Presented

    func body(content: Content) -> some View {
        // Capture the live instance while the presenter still owns its environment;
        // do not read an @Environment wrapper later inside the modal builder.
        let environment = environment
        switch style {
        case .sheet:
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss) {
                AppPresentationRoot(environment: environment, content: presented())
            }
        case .fullScreen:
            content.fullScreenCover(isPresented: $isPresented, onDismiss: onDismiss) {
                AppPresentationRoot(environment: environment, content: presented())
            }
        }
    }
}

private struct AppItemPresentation<Item: Identifiable, Presented: View>: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @Binding var item: Item?
    let style: AppPresentationStyle
    let onDismiss: (() -> Void)?
    let presented: (Item) -> Presented

    func body(content: Content) -> some View {
        let environment = environment
        switch style {
        case .sheet:
            content.sheet(item: $item, onDismiss: onDismiss) { item in
                AppPresentationRoot(environment: environment, content: presented(item))
            }
        case .fullScreen:
            content.fullScreenCover(item: $item, onDismiss: onDismiss) { item in
                AppPresentationRoot(environment: environment, content: presented(item))
            }
        }
    }
}

extension View {
    func appSheet<Presented: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                  @ViewBuilder content: @escaping () -> Presented) -> some View {
        modifier(AppBooleanPresentation(isPresented: isPresented, style: .sheet, onDismiss: onDismiss, presented: content))
    }

    func appSheet<Item: Identifiable, Presented: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                    @ViewBuilder content: @escaping (Item) -> Presented) -> some View {
        modifier(AppItemPresentation(item: item, style: .sheet, onDismiss: onDismiss, presented: content))
    }

    func appFullScreenCover<Presented: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                            @ViewBuilder content: @escaping () -> Presented) -> some View {
        modifier(AppBooleanPresentation(isPresented: isPresented, style: .fullScreen, onDismiss: onDismiss, presented: content))
    }

    func appFullScreenCover<Item: Identifiable, Presented: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                             @ViewBuilder content: @escaping (Item) -> Presented) -> some View {
        modifier(AppItemPresentation(item: item, style: .fullScreen, onDismiss: onDismiss, presented: content))
    }
}
