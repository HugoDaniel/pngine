import SwiftUI
import PngineKit

@main
struct PngineTestApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var status = "Initializing..."

    var body: some View {
        VStack(spacing: 20) {
            Text("PNGine iOS Test")
                .font(.title)

            Text(status)
                .font(.body)
                .foregroundColor(.secondary)

            // Simple test of PngineKit
            PngineView(bytecode: Data())
                .frame(width: 300, height: 300)
                .border(Color.gray)

            Button("Test Init") {
                testPngineInit()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear {
            testPngineInit()
        }
    }

    func testPngineInit() {
        // Test basic initialization
        if PngineKit.initialize() {
            status = "✅ PNGine initialized successfully"
        } else {
            status = "❌ PNGine initialization failed"
        }
    }
}

#Preview {
    ContentView()
}
