import AppKit

// 生成 MicLock App 图标。
// 直接加载 Resources/AppIcon.svg（AppKit 内建 SVG 渲染，macOS 11+），
// 输出标准 iconset 目录，随后用 iconutil -c icns 打包。
//
// 用法: genicon <iconset输出目录> [svg路径] [最大边长]
// 退出码: 0 成功；非 0 失败（SVG 无法加载或写盘失败）。

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: genicon <iconset-dir> [svg] [max-size]\n".data(using: .utf8)!)
    exit(2)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])

let svgPath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "Resources/AppIcon.svg"

let maxSize = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 1024 : 1024

guard let svg = NSImage(contentsOfFile: svgPath) else {
    FileHandle.standardError.write("error: 无法加载 SVG: \(svgPath)\n".data(using: .utf8)!)
    exit(1)
}

func writePNG(pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "genicon", code: 1)
    }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    svg.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: NSRect(x: 0, y: 0, width: svg.size.width, height: svg.size.height),
        operation: .sourceOver,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "genicon", code: 2)
    }
    try data.write(to: url)
}

try? FileManager.default.removeItem(at: outputDir)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

do {
    for entry in sizes where Double(entry.pixels) <= maxSize * 1.001 {
        try writePNG(pixels: entry.pixels, to: outputDir.appendingPathComponent(entry.name))
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}

print("iconset 写入 \(outputDir.path)（源: \(svgPath)）")
