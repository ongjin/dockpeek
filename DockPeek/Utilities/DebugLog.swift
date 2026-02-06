import Foundation

#if DEBUG
let kDockPeekDebug = true
#else
let kDockPeekDebug = false
#endif

func dpLog(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    guard kDockPeekDebug else { return }
    let filename = (file as NSString).lastPathComponent
    print("[DockPeek] \(filename):\(line) \(message())")
}
