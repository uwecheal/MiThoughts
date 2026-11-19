import SwiftUI

struct ContentView: View {
    /// The file this window shows (nil = untitled); kept in sync so window
    /// restoration reopens the right file.
    @Binding var fileURL: URL?

    var body: some View {
        InfiniteCanvasView(windowFileURL: $fileURL)
    }
}

#Preview {
    ContentView(fileURL: .constant(nil))
        .frame(width: 720, height: 480)
}
