// swiftc open-settings.swift -o open-settings && ./open-settings
// Opens Whisper's settings window, same as Settings… in the menu bar dropdown.
import Foundation
DistributedNotificationCenter.default().post(name: Notification.Name("com.maxoleary.whisper.openSettings"), object: nil)
