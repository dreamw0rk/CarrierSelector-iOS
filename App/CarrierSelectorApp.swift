import SwiftUI

// Select the property-wrapper API explicitly; Xcode 27 also exports a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct CarrierSelectorApp: App {
    @UIApplicationDelegateAdaptor(LifecycleDelegate.self) private var lifecycle
    @StateObject private var model = AppModel.shared
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        WindowGroup {
            TabView(selection: $model.selectedTab) {
                InstallationScreen().id(model.installationNavigationID).tabItem { Label("Установка", systemImage: "simcard") }.tag(AppTab.installation)
                ProfilesScreen().id(model.profilesNavigationID).tabItem { Label("Профили", systemImage: "square.grid.2x2") }.tag(AppTab.profiles)
                GuideScreen().tabItem { Label("Помощь", systemImage: "questionmark.circle") }.tag(AppTab.help)
            }
            .tint(CarrierStyle.accent)
            .environmentObject(model)
            .environmentObject(library)
            .onReceive(model.events) { event in library.record(event) }
        }
    }
}
