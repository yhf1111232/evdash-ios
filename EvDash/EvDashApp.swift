//
//  EvDashApp.swift
//  EvDash
//
//  应用入口
//

import SwiftUI

@main
struct EvDashApp: App {
    @StateObject private var ble = BleManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .preferredColorScheme(.dark)
        }
    }
}
