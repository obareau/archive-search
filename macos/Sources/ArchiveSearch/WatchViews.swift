import AppKit
import ArchiveCore
import SwiftUI
import UserNotifications

/// La veille, tant que l'app tourne. Une minuterie toutes les 6 h ; la date du
/// dernier passage est gardée, donc un Mac rouvert après une nuit éteinte
/// rattrape le passage manqué au lancement, sans attendre six heures de plus.
@MainActor
final class WatchModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var running = false
    @Published private(set) var lastPass: Date? = UserDefaults.standard.object(forKey: "watch.lastPass") as? Date
    @Published private(set) var lastReport: Watch.PassReport?
    @Published private(set) var watchedCount = History.watched().count
    /// Recherche à rouvrir après un clic sur une notification.
    @Published var pendingReplay: SearchQuery?
    /// Pour que la vue Historique se relise après un passage.
    @Published private(set) var tick = 0

    private var timer: Timer?
    private var task: Task<Void, Never>?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func start() {
        timer?.invalidate()
        // Vérifié toutes les 5 min : c'est l'échéance qui décide, pas la minuterie.
        // Un Mac en veille ne fait pas tourner de Timer ; au réveil, le passage
        // dû part au tick suivant.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runIfDue() }
        }
        // Un peu après le lancement : laisser l'app s'ouvrir avant d'aller sur le réseau.
        Task { try? await Task.sleep(for: .seconds(20)); runIfDue() }
    }

    var nextPass: Date? {
        guard watchedCount > 0 else { return nil }
        return (lastPass ?? .distantPast).addingTimeInterval(Watch.interval)
    }

    func runIfDue() {
        guard let next = nextPass, next <= Date() else { return }
        checkNow()
    }

    func refreshCount() { watchedCount = History.watched().count; tick += 1 }

    func setWatch(_ key: String, _ on: Bool) {
        History.setWatch(key, on)
        refreshCount()
        if on { requestAuthorization() }
    }

    /// « Vérifier maintenant » : pour ne pas attendre six heures quand on veut
    /// juste voir que la veille fonctionne.
    func checkNow() {
        guard !running else { return }
        running = true
        task = Task {
            let report = await Watch.pass()
            running = false
            lastReport = report
            lastPass = Date()
            UserDefaults.standard.set(lastPass, forKey: "watch.lastPass")
            tick += 1
            for f in report.findings { notify(f) }
        }
    }

    // ── Notifications ────────────────────────────────────────────────────

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Seulement s'il y a du neuf : un passage silencieux est le cas normal.
    private func notify(_ f: Watch.Finding) {
        let c = UNMutableNotificationContent()
        c.title = "Archive Search — \(f.fresh.count) nouveauté\(f.fresh.count > 1 ? "s" : "")"
        c.subtitle = "« \(f.query.text) » sur \(f.query.source)"
        c.body = f.fresh.prefix(5).map { "· \($0.title)" }.joined(separator: "\n")
        c.sound = .default
        c.userInfo = ["source": f.query.source, "text": f.query.text, "type": f.query.type.rawValue,
                      "sort": f.query.sort.rawValue, "collection": f.query.collection.rawValue]
        let req = UNNotificationRequest(identifier: "watch-\(f.key)-\(Date().timeIntervalSince1970)", content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            guard err != nil else { return }
            // Notifications refusées ou indisponibles (signature ad hoc) :
            // on passe par le Centre de notifications via AppleScript.
            let script = "display notification \(Self.quote(c.body)) with title \(Self.quote(c.title)) subtitle \(Self.quote(c.subtitle))"
            DispatchQueue.main.async { NSAppleScript(source: script)?.executeAndReturnError(nil) }
        }
    }

    nonisolated static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let u = response.notification.request.content.userInfo
        guard let source = u["source"] as? String, let text = u["text"] as? String else { return }
        let q = SearchQuery(source: source, text: text,
                            type: SearchType(rawValue: u["type"] as? String ?? "") ?? .all,
                            sort: SortOption(rawValue: u["sort"] as? String ?? "") ?? .relevance,
                            collection: Collection(rawValue: u["collection"] as? String ?? "") ?? .all)
        await MainActor.run {
            NSApp.activate()
            pendingReplay = q
        }
    }
}

struct HistoryView: View {
    @ObservedObject var model: SearchModel
    @EnvironmentObject var watch: WatchModel
    let onReplay: () -> Void
    @Local private var entries: [History.Listed] = History.list()
    @Local private var forgetting: History.Listed?
    @Local private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("Historique vide", systemImage: "clock",
                                       description: Text("Chaque recherche y est datée. La relancer met en avant ce qui est apparu depuis la dernière fois."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { e in row(e) }.listStyle(.inset)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: model.historyTick) { reload() }
        .onChange(of: watch.tick) { reload() }
        .confirmationDialog("Arrêter la veille et oublier « \(forgetting?.entry.query ?? "") » ?",
                            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            Button("Oublier", role: .destructive) { if let f = forgetting { forget(f) } }
        } message: {
            Text("Son « déjà vu » part avec elle : la relancer repartira de zéro.")
        }
        .confirmationDialog("Vider tout l'historique ?", isPresented: $confirmClear) {
            Button("Vider (\(entries.count))", role: .destructive) {
                History.clear(); watch.refreshCount(); reload()
            }
        } message: {
            Text("Les veilles s'arrêtent aussi, et tout le « déjà vu » est oublié.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye").foregroundStyle(watch.watchedCount > 0 ? Color.amber : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(watch.watchedCount == 0 ? "Aucune veille"
                     : "Veille : \(watch.watchedCount) recherche\(watch.watchedCount > 1 ? "s" : ""), toutes les \(Int(Watch.interval / 3600)) h")
                    .font(.callout.weight(.medium))
                Text(statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                watch.checkNow()
            } label: {
                if watch.running { ProgressView().controlSize(.small) } else { Text("Vérifier maintenant") }
            }
            .disabled(watch.running || watch.watchedCount == 0)
            Button("Vider l'historique", role: .destructive) { confirmClear = true }
                .disabled(entries.isEmpty)
        }
        .padding(12)
    }

    private var statusLine: String {
        var parts: [String] = []
        if watch.running { parts.append("passage en cours — \(Int(Watch.spacing)) s entre deux recherches") }
        if let r = watch.lastReport {
            let n = r.findings.reduce(0) { $0 + $1.fresh.count }
            parts.append(n == 0 ? "dernier passage : rien de neuf" : "dernier passage : \(n) nouveauté\(n > 1 ? "s" : "")")
            if !r.failures.isEmpty { parts.append("\(r.failures.count) source(s) en panne") }
        } else if let last = watch.lastPass {
            parts.append("dernier passage \(last.formatted(.relative(presentation: .named)))")
        }
        if let next = watch.nextPass, !watch.running {
            parts.append(next <= Date() ? "prochain passage imminent" : "prochain \(next.formatted(.relative(presentation: .named)))")
        }
        if watch.watchedCount > 0 { parts.append("l'app doit rester ouverte (fenêtre fermée, elle continue)") }
        return parts.joined(separator: " · ")
    }

    private func row(_ e: History.Listed) -> some View {
        let en = e.entry
        return HStack(alignment: .center, spacing: 10) {
            Button { watch.setWatch(e.key, !en.watch) } label: {
                Image(systemName: en.watch ? "eye.fill" : "eye").foregroundStyle(en.watch ? Color.amber : .secondary)
            }
            .buttonStyle(.borderless)
            .help(en.watch ? "Sous veille : arrêter" : "Mettre sous veille (un passage toutes les 6 h, notification s'il y a du neuf)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(en.query).font(.headline)
                    if en.new_count > 0 {
                        Text("✦ \(en.new_count) nouveau\(en.new_count > 1 ? "x" : "")")
                            .font(.caption2.weight(.semibold)).foregroundStyle(Color.amber)
                    }
                }
                Text(detail(en)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Relancer") { model.replay(en.searchQuery); onReplay() }
                .controlSize(.small)
            Button {
                if en.watch { forgetting = e } else { forget(e) }
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Oublier cette recherche")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.replay(en.searchQuery); onReplay() }
    }

    private func detail(_ en: History.Entry) -> String {
        var bits = [Sources.all.first { $0.id == en.source }?.label ?? en.source]
        if let t = SearchType(rawValue: en.type), t != .all { bits.append(t.label) }
        if let c = Collection(rawValue: en.collection), c != .all { bits.append(c.label) }
        if let s = SortOption(rawValue: en.sort), s != .relevance { bits.append(s.label) }
        bits.append("\(en.runs) passage\(en.runs > 1 ? "s" : "")")
        bits.append("\(en.seen.count) connus")
        bits.append(String(en.last_run.prefix(16)).replacingOccurrences(of: "T", with: " "))
        return bits.joined(separator: " · ")
    }

    private func forget(_ e: History.Listed) {
        History.forget(e.key)
        watch.refreshCount()
        forgetting = nil
        reload()
    }

    private func reload() { entries = History.list() }
}
