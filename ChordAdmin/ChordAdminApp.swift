//
//  ChordAdminApp.swift
//  ChordAdmin
//
//  Created by Frankie Benjamin on 6/5/2026.
//

import SwiftUI
import FirebaseCore

@main
struct ChordAdminApp: App {
    @NSApplicationDelegateAdaptor(ChordAdminAppDelegate.self) private var appDelegate

    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appDelegate: appDelegate)
        }
        .commands { ChordAdminCommands() }
    }
}
