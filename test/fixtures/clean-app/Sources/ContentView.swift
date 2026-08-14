import SwiftUI

struct ContentView: View {
    @State private var distance: Double = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("Distance")
                .font(.headline)
            Text(String(format: "%.2f km", distance))
                .font(.largeTitle)
        }
        .padding()
    }
}
