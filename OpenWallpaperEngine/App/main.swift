//
//  main.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/6/6.
//

import Cocoa

// Before any JavaScriptCore VM exists: the SceneScript watchdog must be able to stop JIT-compiled
// loops.
SceneScriptJIT.configurePollingTraps()

MainActor.assumeIsolated {
	// Unit tests are hosted in the app; skip the delegate so a test run doesn't open wallpaper
	// windows, start playback or overwrite the user's saved state.
	if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
		NSApplication.shared.delegate = AppDelegate.shared
	}
	NSApplication.shared.run()
}
