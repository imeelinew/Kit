import AppKit
import Darwin
@testable import Kit

/// A repeatable synthetic workload shared by the baseline and candidate builds.
@main
@MainActor
struct ClipboardMemoryProbe {
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        return info.phys_footprint
    }

    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kit-memory-probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        if ProcessInfo.processInfo.environment["KIT_PROFILE_WORKLOAD"] == "decode-burst" {
            try await decodeBurst(in: directory)
            return
        }
        let store = ClipboardStore(directory: directory, recognizeImage: { _ in .recognized("fixture") })
        for index in 0..<30 {
            let png = autoreleasepool {
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1000, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0)!
                memset(bitmap.bitmapData!, Int32(index + 80), bitmap.bytesPerRow * bitmap.pixelsHigh)
                return bitmap.representation(using: .png, properties: [:])!
            }
            await store.addImage(png, sourceBundleID: nil)
        }
        await store.waitForImageOCR()
        let core = AppCore(clipboardStore: store)
        let controller = PaletteWindowController(core: core)
        controller.prewarm()
        let panel = NSApp.windows.compactMap { $0 as? PalettePanel }.first!
        defer { panel.close() }
        try await Task.sleep(for: .seconds(1))
        print("MEMORY prewarm bytes=\(footprint())")
        let images = store.items
        for cycle in 1...3 {
            await core.palette.prepare()
            panel.orderFront(nil)
            for item in images {
                core.palette.select(item.id)
                panel.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            print("MEMORY browsing_\(cycle) bytes=\(footprint())")
            controller.hide(restoreFocus: false)
            try await Task.sleep(for: .seconds(2))
            print("MEMORY hidden_\(cycle) bytes=\(footprint())")
        }
    }

    /// Measures transient decode pressure independently of history, OCR, and view ownership.
    private static func decodeBurst(in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for index in 0..<20 {
            let url = directory.appendingPathComponent("burst-\(index).png")
            try autoreleasepool {
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 4000, pixelsHigh: 2500, bitsPerSample: 8,
                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0)!
                memset(bitmap.bitmapData!, Int32(index + 80), bitmap.bytesPerRow * bitmap.pixelsHigh)
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            }
            urls.append(url)
        }
        for cycle in 1...3 {
            ImageThumbnail.purgePreviews()
            try await Task.sleep(for: .seconds(1))
            let before = footprint()
            let sampler = Task {
                var peak = footprint()
                while !Task.isCancelled {
                    peak = max(peak, footprint())
                    try? await Task.sleep(for: .milliseconds(2))
                }
                return peak
            }
            let started = ContinuousClock.now
            let loads = urls.map { url in
                Task {
                    let image = await ImageThumbnail.loadAsync(url, maxPixel: 1600)
                    return image != nil
                }
            }
            for load in loads {
                let succeeded = await load.value
                precondition(succeeded, "Every requested image must finish successfully")
            }
            let elapsed = started.duration(to: .now)
            sampler.cancel()
            let peak = await sampler.value
            print("MEMORY decode_burst_\(cycle) before=\(before) peak=\(peak) after=\(footprint()) elapsed=\(elapsed)")
        }
    }
}
