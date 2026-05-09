#!/usr/bin/env swift
import Cocoa
let args = CommandLine.arguments
guard args.count == 3 else { exit(1) }
let folder = args[1]
let icon = args[2]
guard let img = NSImage(contentsOfFile: icon) else { exit(1) }
NSWorkspace.shared.setIcon(img, forFile: folder, options: [])
