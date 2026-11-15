// swift-tools-version:5.10
// Archive Search — app macOS native (SwiftUI), portage du Flask app.py.
// ArchiveCore = sources, licences, propositions connexes (sans UI),
// ArchiveSearch = l'app, archive-check = auto-test en ligne de commande.
import PackageDescription

let package = Package(
    name: "ArchiveSearch",
    // macOS 26 (Tahoe) : FoundationModels, pour la fouille (étape 4).
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "ArchiveSearch", targets: ["ArchiveSearch"]),
        .executable(name: "archive-check", targets: ["archive-check"]),
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
    ],
    targets: [
        .target(name: "ArchiveCore"),
        .executableTarget(name: "ArchiveSearch", dependencies: ["ArchiveCore"]),
        .executableTarget(name: "archive-check", dependencies: ["ArchiveCore"]),
    ]
)
