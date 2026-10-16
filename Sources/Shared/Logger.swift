// Copyright 2026 ICOA Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import os

public enum LogCategory: String, Sendable {
    case bluetooth = "Bluetooth"
    case hfp = "HFP"
    case audio = "Audio"
    case agent = "Agent"
    case app = "App"
}

public struct PhoneBTLogger: Sendable {
    private let logger: os.Logger
    private let category: LogCategory

    public init(category: LogCategory) {
        self.logger = os.Logger(subsystem: "com.phonebt", category: category.rawValue)
        self.category = category
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        DebugFile.shared.write("INFO", category, message)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        DebugFile.shared.write("ERROR", category, message)
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        DebugFile.shared.write("WARN", category, message)
    }
}

/// Appends log lines to ~/.phonebt/debug.log (info level isn't persisted by the unified log)
final class DebugFile: @unchecked Sendable {
    static let shared = DebugFile()

    private let queue = DispatchQueue(label: "phonebt.debugfile")
    private let handle: FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".phonebt")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("debug.log")
        // Start fresh when the file grows past 5 MB
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 5_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func write(_ level: String, _ category: LogCategory, _ message: String) {
        let line = "\(formatter.string(from: Date())) \(level) [\(category.rawValue)] \(message)\n"
        queue.async { [handle] in
            handle?.write(Data(line.utf8))
        }
    }
}