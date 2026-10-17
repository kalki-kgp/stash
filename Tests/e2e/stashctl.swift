// Sends one command to a test build of Stash (see Sources/TestHook.swift).
import Foundation
let command = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("dev.kalki.stash.test"), object: command, userInfo: nil, deliverImmediately: true)
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
