import SwiftUI

/// The Workday tab: Home's Workday preset as a page of its own, with its own agent digests.
struct WorkdayHomeView: View {
    @StateObject private var digests = AgentDigests()
    var body: some View {
        HomePage(layout: HomePreset.workday.layout)
            .environmentObject(digests)
            .background(T.surface)
            .onAppear { digests.start() }
            .onDisappear { digests.stop() }
    }
}
