import CoreGraphics
import Foundation

extension PostJailbreakHomeView {
    enum Screen: Equatable {
        case home
        case advancedOptions
        case resetAndRemoval
        case credits
        case confirmation(ConfirmationAction)

        enum TerminalSurface {
            case home
            case command(String)
            case credits
        }

        var terminalHeight: CGFloat {
            self == .credits
                ? HomeContentLayout.creditsTerminalHeight
                : HomeContentLayout.terminalHeight
        }

        var terminalSurface: TerminalSurface {
            switch self {
            case .home:
                .home
            case .advancedOptions:
                .command("relaxin/advanced-options")
            case .resetAndRemoval:
                .command("relaxin/advanced-options/reset-and-remove")
            case .credits:
                .credits
            case .confirmation:
                .command("relaxin/confirm")
            }
        }

        var backDestination: Screen? {
            switch self {
            case .advancedOptions, .credits:
                .home
            case .resetAndRemoval:
                .advancedOptions
            case let .confirmation(action):
                switch action {
                case .restartSpringBoard, .restartUserspace:
                    .home
                case .removeJailbreak:
                    .resetAndRemoval
                }
            case .home:
                nil
            }
        }

        func menuEntries(
            runtimeOptions: PostJailbreakSession.RuntimeOptions,
            canReinstallSileo: Bool,
            allowsExternalNavigation: Bool,
            resourceBundle: Bundle
        ) -> [(action: MenuAction, title: String)] {
            switch self {
            case .home:
                return [
                    (
                        .confirm(.restartSpringBoard),
                        String(
                            localized: "Restart SpringBoard",
                            bundle: resourceBundle
                        )
                    ),
                    (
                        .confirm(.restartUserspace),
                        String(
                            localized: "Restart Userspace",
                            bundle: resourceBundle
                        )
                    ),
                    (
                        .advancedOptions,
                        String(localized: "Advanced Options", bundle: resourceBundle)
                    ),
                    (.credits, String(localized: "Credits", bundle: resourceBundle)),
                ]
            case .advancedOptions:
                return [
                    (
                        .toggleOption(.tweakInjection),
                        ToggleOption.tweakInjection.title(
                            in: runtimeOptions,
                            resourceBundle: resourceBundle
                        )
                    ),
                    (
                        .toggleOption(.appJIT),
                        ToggleOption.appJIT.title(
                            in: runtimeOptions,
                            resourceBundle: resourceBundle
                        )
                    ),
                    (
                        .gotoInstallWhitelistApp,
                        String(
                            localized: "Install Whitelist App",
                            bundle: resourceBundle
                        )
                    ),
                    (
                        .gotoInstallMountApp,
                        String(
                            localized: "Install Mount App",
                            bundle: resourceBundle
                        )
                    ),
                    (
                        .refreshJailbreakApps,
                        String(
                            localized: "Refresh Jailbreak Apps",
                            bundle: resourceBundle
                        )
                    ),
                    (
                        .resetAndRemoval,
                        String(localized: "Reset & Remove", bundle: resourceBundle)
                    ),
                    (.back, String(localized: "Back", bundle: resourceBundle)),
                ]
            case .resetAndRemoval:
                var entries: [(MenuAction, String)] = [
                    (
                        .resetMobilePassword,
                        String(
                            localized: "Reset Mobile Password",
                            bundle: resourceBundle
                        )
                    ),
                ]
                if canReinstallSileo {
                    entries.append(
                        (
                            .reinstallSileo,
                            String(localized: "Reinstall Sileo", bundle: resourceBundle)
                        )
                    )
                }
                entries.append(contentsOf: [
                    (
                        .confirm(.removeJailbreak),
                        String(localized: "Remove Jailbreak", bundle: resourceBundle)
                    ),
                    (.back, String(localized: "Back", bundle: resourceBundle)),
                ])
                return entries
            case .credits:
                var entries: [(MenuAction, String)] = []
                if allowsExternalNavigation {
                    entries.append(contentsOf: [
                        (
                            .openOwnGoalStudioPicks,
                            String(
                                localized: "OwnGoal Studio's Best",
                                bundle: resourceBundle
                            )
                        ),
                        (
                            .showSoftwareLicense,
                            String(
                                localized: "Software License",
                                bundle: resourceBundle
                            )
                        ),
                    ])
                }
                entries.append(
                    (.back, String(localized: "Back", bundle: resourceBundle))
                )
                return entries
            case let .confirmation(action):
                return [
                    (
                        action.menuAction,
                        "\(String(localized: "Execute", bundle: resourceBundle)): \(action.title(in: resourceBundle))"
                    ),
                    (.back, String(localized: "Back", bundle: resourceBundle)),
                ]
            }
        }
    }

    enum ToggleOption: CaseIterable, Hashable {
        case tweakInjection
        case appJIT

        func isEnabled(
            in runtimeOptions: PostJailbreakSession.RuntimeOptions
        ) -> Bool {
            switch self {
            case .tweakInjection:
                runtimeOptions.tweakInjectionEnabled
            case .appJIT:
                runtimeOptions.appJITEnabled
            }
        }

        func title(
            in runtimeOptions: PostJailbreakSession.RuntimeOptions,
            resourceBundle: Bundle
        ) -> String {
            let name = switch self {
            case .tweakInjection:
                String(localized: "Tweak Injection", bundle: resourceBundle)
            case .appJIT:
                String(localized: "Allow JIT in Apps", bundle: resourceBundle)
            }
            let state = isEnabled(in: runtimeOptions)
                ? String(localized: "ON", bundle: resourceBundle)
                : String(localized: "OFF", bundle: resourceBundle)
            return "\(name): \(state)"
        }
    }

    enum ConfirmationAction: Hashable {
        case restartSpringBoard
        case restartUserspace
        case removeJailbreak

        func title(in resourceBundle: Bundle) -> String {
            switch self {
            case .restartSpringBoard:
                String(localized: "Restart SpringBoard", bundle: resourceBundle)
            case .restartUserspace:
                String(localized: "Restart Userspace", bundle: resourceBundle)
            case .removeJailbreak:
                String(localized: "Remove Jailbreak", bundle: resourceBundle)
            }
        }

        var menuAction: MenuAction {
            switch self {
            case .restartSpringBoard:
                .restartSpringBoard
            case .restartUserspace:
                .restartUserspace
            case .removeJailbreak:
                .removeJailbreak
            }
        }
    }

    enum MenuAction: Hashable {
        case advancedOptions
        case resetAndRemoval
        case credits
        case openOwnGoalStudioPicks
        case showSoftwareLicense
        case toggleOption(ToggleOption)
        case restartSpringBoard
        case restartUserspace
        case gotoInstallWhitelistApp
        case gotoInstallMountApp
        case refreshJailbreakApps
        case resetMobilePassword
        case reinstallSileo
        case removeJailbreak
        case confirm(ConfirmationAction)
        case back
    }
}
