import SwiftUI

@main
struct RideScreenIOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "bicycle")
                    .font(.system(size: 52, weight: .regular))
                    .accessibilityHidden(true)

                Text("RideScreen")
                    .font(.largeTitle.bold())

                Text("iOS project scaffold")
                    .font(.title3)

                Text("Ride recording and video telemetry overlays will be built here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Label("Initial build scaffold", systemImage: "hammer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .padding()
            .navigationTitle("RideScreen")
        }
    }
}

#Preview {
    ContentView()
}
