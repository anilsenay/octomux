import SwiftUI

/// The Home tab (the Terminal window, or any window with tabs): your Home as a page of its own, with its own agent
/// digests, read only while the tab shows sections that need them.
struct HomeTabView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var digests = AgentDigests()
    var body: some View {
        let reads = model.homeLayout.all.contains { $0.readsDigests } || HomeCustomizeState.shared.on
        YourHome(railFilter: false)
            .environmentObject(digests)
            .background(T.surface)
            .onAppear { if reads { digests.start() } }
            .onChange(of: reads) { _, r in if r { digests.start() } else { digests.stop() } }
            .onDisappear { digests.stop() }
    }
}
