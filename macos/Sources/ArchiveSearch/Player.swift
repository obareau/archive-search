import AVKit
import ArchiveCore
import PDFKit
import SwiftUI

/// Ce que le panneau de droite sait montrer pour un item.
enum Playable: Equatable {
    case none
    case loading
    case media(URL, video: Bool)
    case pdf(URL)
    case image(URL)
    case unavailable(String)
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var state: Playable = .none
    @Published private(set) var torrent: URL?
    let player = AVPlayer()
    private var current: String?
    private var task: Task<Void, Never>?

    func load(_ item: Item?) {
        guard item?.id != current else { return }
        current = item?.id
        task?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        torrent = nil
        guard let item else { state = .none; return }

        // Freesound donne déjà le mp3 de prévisualisation : pas de second appel.
        if let p = item.preview, let u = URL(string: p), !p.isEmpty {
            play(u, video: false); return
        }
        if item.source == "wikimedia", let u = URL(string: item.thumbnail), !item.thumbnail.isEmpty {
            state = .image(u); return
        }
        guard item.source == "archive.org" else {
            state = .unavailable("Cette source renvoie une page web, pas un fichier lisible ici.")
            return
        }
        state = .loading
        task = Task {
            do {
                let r = try await Sources.resolveArchiveFile(item.identifier)
                guard !Task.isCancelled, current == item.id else { return }
                guard let url = r.url else {
                    state = .unavailable("Aucun fichier lisible (\(r.mediatype.isEmpty ? "type inconnu" : r.mediatype)) — upload incomplet ou item retiré.")
                    return
                }
                switch r.mediatype {
                case "texts": state = .pdf(url)
                case "audio": play(url, video: false)
                default: play(url, video: true)
                }
                torrent = try? await Sources.resolveArchiveTorrent(item.identifier)
            } catch {
                guard current == item.id else { return }
                state = .unavailable(error.localizedDescription)
            }
        }
    }

    private func play(_ url: URL, video: Bool) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        state = .media(url, video: video)
        player.play()
    }

    func stop() { player.pause() }
}

struct PlayerPane: View {
    let item: Item?
    @ObservedObject var player: PlayerModel
    var onSimilar: ((Item) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let item {
                    viewer
                    ItemDetail(item: item, torrent: player.torrent, direct: directURL, onSimilar: onSimilar)
                } else {
                    ContentUnavailableView("Rien de sélectionné", systemImage: "play.rectangle",
                                           description: Text("Choisir un résultat pour le lire ou le voir ici."))
                        .padding(.top, 60)
                }
            }
            .padding(16)
        }
        .onChange(of: item?.id) { player.load(item) }
        .onAppear { player.load(item) }
    }

    private var directURL: URL? {
        switch player.state {
        case .media(let u, _), .pdf(let u): u
        default: nil
        }
    }

    @ViewBuilder private var viewer: some View {
        switch player.state {
        case .none: EmptyView()
        case .loading:
            ProgressView("Recherche du fichier…").frame(maxWidth: .infinity, minHeight: 180)
        case .media(_, let video):
            AVPlayerPane(player: player.player, video: video)
                .frame(minHeight: video ? 240 : 60, maxHeight: video ? 420 : 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if !video, let t = item?.thumbnail, let u = URL(string: t), !t.isEmpty {
                AsyncImage(url: u) { $0.resizable().scaledToFit() } placeholder: { Color.clear }
                    .frame(maxHeight: 120).clipShape(RoundedRectangle(cornerRadius: 6))
            }
        case .pdf(let u):
            PDFPane(url: u).frame(minHeight: 420).clipShape(RoundedRectangle(cornerRadius: 8))
        case .image(let u):
            AsyncImage(url: u) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                .frame(maxWidth: .infinity, minHeight: 200).clipShape(RoundedRectangle(cornerRadius: 8))
        case .unavailable(let why):
            Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ItemDetail: View {
    let item: Item
    let torrent: URL?
    let direct: URL?
    var onSimilar: ((Item) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title).asHeading(.title3).fontWeight(.semibold).textSelection(.enabled)
            Text([item.creator, item.year, item.type].filter { !$0.isEmpty && $0 != "N/A" }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            LicenseBadge(license: item.license, long: true)
            if let a = item.analysisLabel {
                Text("\(a) — estimé par Freesound")
                    .asFont(.caption).foregroundStyle(.secondary)
                    .help("Calculé pour tous les sons, même sans rythme ni note : fiable sur une boucle ou un instrument, pas sur un bruitage")
            }
            if !item.description.isEmpty {
                Text(item.description).asFont(.callout).textSelection(.enabled)
            }
            if let kw = item.keywords, !kw.isEmpty {
                Text(kw.joined(separator: " · ")).asFont(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let u = URL(string: item.url), !item.url.isEmpty {
                    Link(destination: u) { Label("Ouvrir la page", systemImage: "arrow.up.right.square") }
                }
                if let direct {
                    Link(destination: direct) { Label("Fichier", systemImage: "doc") }
                }
                if let torrent {
                    Link(destination: torrent) { Label(".torrent", systemImage: "arrow.down.circle") }
                }
                if item.source == "freesound", let onSimilar {
                    Button { onSimilar(item) } label: { Label("Sons similaires", systemImage: "waveform.badge.magnifyingglass") }
                        .buttonStyle(.link)
                }
            }
            // La racine impose la couleur du texte du thème : sans ça, les
            // liens perdaient la leur et ne se distinguaient plus.
            .foregroundStyle(.tint)
            .padding(.top, 4)
        }
    }
}

/// PDFDocument(url:) charge en synchrone sur le fil principal : on rapatrie
/// les octets d'abord.
struct PDFPane: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        load(into: v)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { load(into: v) }
    }
    private func load(into v: PDFView) {
        let url = url
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let doc = PDFDocument(data: data) else { return }
            await MainActor.run { v.document = doc }
        }
    }
}

/// AVPlayerView d'AppKit plutôt que le `VideoPlayer` de SwiftUI : compilé avec
/// les seuls Command Line Tools, `_AVKit_SwiftUI` plante à l'initialisation de
/// ses métadonnées (SIGABRT dans getSuperclassMetadata, constaté le 2026-11-15).
struct AVPlayerPane: NSViewRepresentable {
    let player: AVPlayer
    let video: Bool
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = video ? .floating : .inline
        v.showsFullScreenToggleButton = true
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
        v.controlsStyle = video ? .floating : .inline
    }
}
