import SwiftUI

// Benign source so the fixture is a plausible project on its own.
//
// The file that actually trips the CRITICAL finding —
// Sources/Configuration.swift — is written by test/run-tests.sh into a
// throwaway workspace at test time. Its credential literal is assembled at
// runtime and never committed: this repository must not contain a
// secret-shaped string, both because push protection blocks it and because
// shipping one would contradict the tool.
struct AppEntry: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("CriticalFixture")
                .font(.headline)
            Text("Test fixture")
                .font(.footnote)
        }
        .padding()
    }
}
