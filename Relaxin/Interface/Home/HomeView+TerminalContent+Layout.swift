import Foundation

extension RelaxinTerminalContent {
    private static let deviceKeyWidth = 8
    static let dividerWidth = 25

    static func render(
        _ line: TerminalOutputLine,
        width: Int
    ) -> [String] {
        var prefix = switch line.status {
        case .info:
            "• "
        case .running:
            "● "
        case .succeeded:
            "✓ "
        case .failed:
            "× "
        }
        if let position = line.position, let count = line.count {
            prefix += String(format: "%02d/%02d ", position, count)
        }

        let header = prefixedLines(
            line.label,
            firstPrefix: prefix,
            continuationPrefix: String(repeating: " ", count: prefix.count),
            width: width
        )
        let styledHeader = header.map {
            switch line.status {
            case .info:
                TerminalStyle.dim($0)
            case .running, .succeeded:
                TerminalStyle.accent($0)
            case .failed:
                TerminalStyle.danger($0)
            }
        }
        guard line.status == .running || line.status == .failed else {
            return styledHeader
        }

        let details = line.details.map(compactDetail)
        let styledDetails = details.enumerated().flatMap { index, detail in
            let isLast = index == details.indices.last
            let lines = prefixedLines(
                detail,
                firstPrefix: isLast ? "  └─ " : "  ├─ ",
                continuationPrefix: isLast ? "     " : "  │  ",
                width: width
            )
            return lines.map(TerminalStyle.dim)
        }
        return styledHeader + styledDetails
    }

    private static func prefixedLines(
        _ text: String,
        firstPrefix: String,
        continuationPrefix: String,
        width: Int
    ) -> [String] {
        var remaining = text[...]
        var prefix = firstPrefix
        var lines: [String] = []

        repeat {
            let availableWidth = max(1, width - prefix.count)
            let proposedEnd = remaining.index(
                remaining.startIndex,
                offsetBy: min(availableWidth, remaining.count)
            )
            var lineEnd = proposedEnd
            if proposedEnd != remaining.endIndex {
                let proposedLine = remaining[..<proposedEnd]
                if let space = proposedLine.lastIndex(of: " "),
                   space != remaining.startIndex
                {
                    lineEnd = space
                }
            }

            lines.append(prefix + remaining[..<lineEnd])
            remaining = remaining[lineEnd...]
            while remaining.first == " " {
                remaining = remaining.dropFirst()
            }
            prefix = continuationPrefix
        } while !remaining.isEmpty

        return lines
    }

    private static func compactDetail(_ detail: String) -> String {
        var compact = detail
        for prefix in ["[+] ", "[-] ", "[i] "] where compact.hasPrefix(prefix) {
            compact.removeFirst(prefix.count)
        }
        return compact.replacingOccurrences(of: "kernel_base=", with: "kbase=")
    }

    static func baseLines(
        isJailbroken: Bool,
        resourceBundle: Bundle
    ) -> [String] {
        var lines = bannerLines(
            isJailbroken: isJailbroken,
            resourceBundle: resourceBundle
        )

        let report: [(String, String)] = [
            ("os", DeviceInfo.os),
            ("host", DeviceInfo.host),
            ("kernel", DeviceInfo.kernel),
            ("build", AppInfo.displayVersion(in: resourceBundle)),
            ("uptime", DeviceInfo.uptime),
            ("model", "White List"),
        ]
        for (key, value) in report {
            let paddedKey = key.padding(toLength: deviceKeyWidth, withPad: " ", startingAt: 0)
            lines.append(TerminalStyle.accent(paddedKey) + value)
        }

        lines.append(TerminalStyle.dim(String(repeating: "─", count: dividerWidth)))
        
        // 新增一个提醒, 遇到任何问题, 请使用官方版本复测, 然后再反馈问题
        lines.append(TerminalStyle.dim(String(
            localized: "If you encounter any issues, please reproduce them using the official version before reporting.",
            bundle: resourceBundle
        )))

        return lines
    }

    static func bannerLines(
        isJailbroken: Bool,
        resourceBundle: Bundle
    ) -> [String] {
        let bannerTop = "█▀█ █▀▀ █   ▄▀█ ▀▄▀ █ █▄ █"
        let bannerBottom = "█▀▄ ██▄ █▄▄ █▀█ █ █ █ █ ▀█"
        let status = isJailbroken
            ? TerminalStyle.danger("▄")
            : TerminalStyle.accent("▄")

        return [
            TerminalStyle.bold(bannerTop),
            TerminalStyle.bold(bannerBottom) + " " + status,
            "",
            TerminalStyle.dim(
                String(
                    localized: "For iOS 16.5.1-17.3.1 devices",
                    bundle: resourceBundle
                )
            ),
            TerminalStyle.dim(String(repeating: "─", count: dividerWidth)),
        ]
    }
}
