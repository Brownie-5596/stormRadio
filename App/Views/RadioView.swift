import SwiftUI
import StormRadioCore

/// Main screen: on/off, profile, what's being read, quick "read" buttons and nearby alerts.
struct RadioView: View {
    @EnvironmentObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    powerCard
                    if let cur = model.speech.current { nowPlaying(cur) }
                    buttons
                    nearbyAlerts
                    sourcesLine
                }
                .padding()
            }
            .navigationTitle("Storm Radio")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { profileMenu }
            }
            .refreshable { model.refreshNow() }
        }
    }

    // MARK: Pieces

    private var profileMenu: some View {
        Menu {
            ForEach(model.settings.profiles) { p in
                Button {
                    model.switchProfile(to: p.id)
                } label: {
                    if p.id == model.settings.activeProfileID { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
        } label: {
            Label(model.profile.name, systemImage: "person.crop.circle")
                .labelStyle(.titleAndIcon)
        }
    }

    private var powerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button {
                    model.toggleMonitoring()
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 30, weight: .bold))
                        .frame(width: 64, height: 64)
                        .background(model.monitoring ? Color.green : Color.gray.opacity(0.35), in: Circle())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(model.monitoring ? "Stop monitoring" : "Start monitoring")
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.monitoring ? "Monitoring" : "Off")
                        .font(.title2.bold())
                    Text("Profile: \(model.profile.name)").font(.subheadline)
                    if let t = model.lastAlertPoll {
                        Text("Alerts checked \(t.ago)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Text(model.locationDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.isSnoozed, let until = model.snoozedUntil {
                HStack {
                    Image(systemName: "moon.zzz")
                    Text("Snoozed until \(until.formatted(date: .omitted, time: .shortened)) (priority 9+ still speaks)")
                    Spacer()
                    Button("Resume") { model.snooze(minutes: 0) }
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if model.location.authorization == .denied {
                Text("Location access is off. Turn it on in iOS Settings > Storm Radio > Location.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func nowPlaying(_ a: Announcement) -> some View {
        HStack(alignment: .top) {
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(Theme.color(for: a))
            VStack(alignment: .leading, spacing: 4) {
                Text(a.title).font(.headline)
                Text(a.spokenText).font(.caption).lineLimit(3).foregroundStyle(.secondary)
                if !model.speech.queue.isEmpty {
                    Text("\(model.speech.queue.count) more queued").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack {
                Button { model.speech.skip() } label: { Image(systemName: "forward.end.fill") }
                Button { model.speech.stopAll() } label: { Image(systemName: "stop.fill") }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Theme.color(for: a).opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private var buttons: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            BigButton(title: "Repeat last", icon: "arrow.counterclockwise", color: .blue) { model.speech.repeatLast() }
            BigButton(title: "Stop talking", icon: "speaker.slash", color: .red) { model.speech.stopAll() }
            BigButton(title: "Nearby alerts", icon: "exclamationmark.triangle", color: .orange) { model.readNearby() }
            BigButton(title: "Storm reports", icon: "person.wave.2", color: .purple) { model.readReports() }
            BigButton(title: "Latest MD", icon: "doc.text.magnifyingglass", color: .indigo) { model.readLatestMD() }
            BigButton(title: "Nearest MD", icon: "scope", color: .indigo) { model.readLatestMD(nearest: true) }
            BigButton(title: "SPC watches", icon: "eye.trianglebadge.exclamationmark", color: .yellow) { model.readWatches() }
            BigButton(title: "Day 1 outlook", icon: "map", color: .teal) { model.readOutlook(day: 1) }
            BigButton(title: "Day 2 outlook", icon: "map", color: .teal) { model.readOutlook(day: 2) }
            BigButton(title: "Forecast discussion", icon: "text.book.closed", color: .gray) { model.readAFD() }
            Menu {
                Button("15 minutes") { model.snooze(minutes: 15) }
                Button("30 minutes") { model.snooze(minutes: 30) }
                Button("1 hour") { model.snooze(minutes: 60) }
                Button("2 hours") { model.snooze(minutes: 120) }
                if model.isSnoozed { Button("Resume now") { model.snooze(minutes: 0) } }
            } label: {
                BigButtonLabel(title: model.isSnoozed ? "Snoozed" : "Snooze", icon: "moon.zzz", color: .brown)
            }
            BigButton(title: "Refresh now", icon: "arrow.clockwise", color: .green) { model.refreshNow() }
        }
    }

    private var nearbyAlerts: some View {
        let inRange = model.activeAlerts.filter { $0.inRange }
        let others = model.activeAlerts.filter { !$0.inRange && ($0.distanceMiles ?? 9999) < 150 }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("In range").font(.headline)
                Spacer()
                Text("\(inRange.count)").foregroundStyle(.secondary)
            }
            if inRange.isEmpty {
                Text(model.monitoring ? "Nothing in range right now." : "Turn monitoring on to start.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(inRange) { info in
                NavigationLink { AlertDetailView(info: info) } label: { AlertRow(info: info) }
                    .buttonStyle(.plain)
            }
            if !others.isEmpty {
                Text("Nearby, outside your distances").font(.subheadline.bold()).padding(.top, 6)
                ForEach(others.prefix(8)) { info in
                    NavigationLink { AlertDetailView(info: info) } label: { AlertRow(info: info) }
                        .buttonStyle(.plain)
                        .opacity(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourcesLine: some View {
        let bad = model.sourceStatus.filter { !$0.value.ok && $0.value.lastAttempt != nil }
        return Group {
            if !bad.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(bad.keys.sorted(), id: \.self) { k in
                        Text("⚠️ \(k): \(bad[k]?.lastError ?? "error")").font(.caption2).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct BigButtonLabel: View {
    var title: String
    var icon: String
    var color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2)
            Text(title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 74)
        .padding(.vertical, 6)
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(color)
    }
}

struct BigButton: View {
    var title: String
    var icon: String
    var color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) { BigButtonLabel(title: title, icon: icon, color: color) }
            .buttonStyle(.plain)
    }
}

struct AlertRow: View {
    var info: ActiveAlertInfo

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.color(forEvent: info.alert.event))
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.title).font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    if info.risk > 0 { Pill(text: "Risk \(info.risk)", color: Theme.riskColor(info.risk)) }
                    if let p = info.path, let eta = p.etaMinutes { Pill(text: "In path ~\(Int(eta)) min", color: .red) }
                    if let end = info.alert.endTime { Text("until \(end.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
