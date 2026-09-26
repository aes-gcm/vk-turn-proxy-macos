import Foundation

func run(_ command: String, _ arguments: [String]) throws -> (Int32, String) {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: command)
    p.arguments = arguments
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

// Path metacharacters must stay data through shell and AppleScript parsing.
let cases = ["normal", "/Users/O'Brien/VK Turn Proxy.app", "quotes \" and \\ slash",
             "$(printf INJECTED); `printf INJECTED`", "строка\nновая строка"]
for value in cases {
    let script = "printf '%s' " + InstallerCommands.shellQuote(value)
    let result = try run("/bin/sh", ["-c", script])
    precondition(result.0 == 0 && result.1 == value, "Shell quoting corrupted a path")
    let apple = InstallerCommands.appleScript(script)
        .replacingOccurrences(of: " with administrator privileges", with: "")
    let echoed = try run("/usr/bin/osascript", ["-e", apple])
    // AppleScript normalizes embedded newlines to CR by default.
    let actual = echoed.1.replacingOccurrences(of: "\r", with: "\n")
    precondition(echoed.0 == 0 && actual == value + "\n", "AppleScript quoting corrupted a path")
}

let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temp) }
let rule = temp.appendingPathComponent("sudoers")
try "#501 ALL=(root) NOPASSWD: \(InstallerCommands.helperPath)\n".write(to: rule, atomically: true, encoding: .utf8)
let ruleCheck = try run("/usr/sbin/visudo", ["-cf", rule.path])
precondition(ruleCheck.0 == 0)
let script = temp.appendingPathComponent("install.sh")
try InstallerCommands.installScript(bundled: cases[1], userID: 501).write(to: script, atomically: true, encoding: .utf8)
let shellCheck = try run("/bin/sh", ["-n", script.path])
precondition(shellCheck.0 == 0)
let compiled = temp.appendingPathComponent("install.scpt")
let apple = InstallerCommands.appleScript(InstallerCommands.installScript(bundled: cases[1], userID: 501))
let appleCheck = try run("/usr/bin/osacompile", ["-o", compiled.path, "-e", apple])
precondition(appleCheck.0 == 0)
print("PASS: path quoting, AppleScript compilation and sudoers validation")
