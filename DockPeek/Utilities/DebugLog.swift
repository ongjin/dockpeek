import Foundation

#if DEBUG
func dpLog(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    let filename = (file as NSString).lastPathComponent
    print("[DockPeek] \(filename):\(line) \(message())")
}
#else
@inlinable func dpLog(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {}
#endif
