//
//  ContentView.swift
//  SendFile over WiFi
//
//  Created by Андрей on 28.09.2026.
//

import SwiftUI
import UniformTypeIdentifiers
import Network
import AppKit

private extension View {
    /// Applied before a button style so the visible control, not just its hit area, grows.
    func transferButtonContent() -> some View {
        font(.title3.weight(.semibold))
            .padding(.vertical, 14)
    }
}

private enum TransferState: Equatable {
    case ready, waitingForSender, choosingFiles, filesSelected(Int), searching, checkingCode, transferring, success, error(String)

    var title: String {
        switch self {
        case .ready: AppLocalization.text("ready")
        case .waitingForSender: AppLocalization.text("waitingSender")
        case .choosingFiles: AppLocalization.text("chooseFilesState")
        case .filesSelected(let count): AppLocalization.text("selectedFiles", count)
        case .searching: AppLocalization.text("searchRecipient")
        case .checkingCode: AppLocalization.text("checkingCode")
        case .transferring: AppLocalization.text("transferring")
        case .success: AppLocalization.text("success")
        case .error: AppLocalization.text("error")
        }
    }

    var detail: String {
        switch self {
        case .ready: AppLocalization.text("pressStart")
        case .waitingForSender: AppLocalization.text("wifiAvailable")
        case .choosingFiles: AppLocalization.text("openFilePicker")
        case .filesSelected: AppLocalization.text("searchAvailable")
        case .searching: AppLocalization.text("searchingDevices")
        case .checkingCode: AppLocalization.text("secureConnection")
        case .transferring: AppLocalization.text("sendingFiles")
        case .success: AppLocalization.text("filesSent")
        case .error(let message): message
        }
    }
}

private enum AppTheme: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { switch self { case .system: AppLocalization.text("systemTheme"); case .dark: AppLocalization.text("darkTheme"); case .light: AppLocalization.text("lightTheme") } }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .dark: .dark; case .light: .light } }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("displayName") private var displayName = Host.current().localizedName ?? "Mac"
    @AppStorage("theme") private var theme = AppTheme.system.rawValue
    @AppStorage("language") private var language = ""
    @AppStorage("preserveDates") private var preserveDates = false
    @AppStorage("receiveDirectoryPath") private var receiveDirectoryPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path

    @State private var receiveState: TransferState = .ready
    @State private var sendState: TransferState = .ready
    @State private var files: [URL] = []
    @State private var showingSettings = false
    @StateObject private var network = LocalNetworkService()
    @StateObject private var receiver = ReceiverSessionCoordinator()
    @State private var showingRecipients = false
    @State private var selectedRecipient: DiscoveredRecipient?
    @State private var pairingConnection: NWConnection?
    @State private var pairingCode: String?
    @State private var transferProgress = ""
    @State private var sendResult: String?
    @State private var peerFingerprint: String?
    private let outgoingClient = OutgoingTransferClient()

    private var colorScheme: ColorScheme? { AppTheme(rawValue: theme)?.colorScheme }
    private var resolvedColorScheme: ColorScheme { colorScheme ?? systemColorScheme }
    private var mainBackground: Color { resolvedColorScheme == .dark ? .black : .white }
    private var surfaceColor: Color {
        resolvedColorScheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.17)
            : Color(red: 0.92, green: 0.92, blue: 0.94)
    }

    var body: some View {
        GeometryReader { geometry in
            let vertical = geometry.size.width < geometry.size.height
            VStack(spacing: 0) {
                header
                if vertical {
                    ScrollView(.vertical) {
                        VStack(spacing: 16) { cards() }
                            .padding(20)
                    }
                    .scrollIndicators(.visible)
                } else {
                    // A regular HStack makes both cards share the available
                    // window width instead of becoming scrollable content.
                    HStack(spacing: 16) { cards() }
                        .padding(20)
                }
                footer
            }
            .background(mainBackground)
        }
        .frame(minWidth: 620, minHeight: 440)
        .preferredColorScheme(colorScheme)
        .environment(\.locale, Locale(identifier: AppLocalization.resolvedLanguage(language) == "cn" ? "zh_Hans" : AppLocalization.resolvedLanguage(language)))
        .sheet(isPresented: $showingSettings) {
            SettingsView(displayName: $displayName, theme: $theme, language: $language, preserveDates: $preserveDates, receiveDirectoryPath: $receiveDirectoryPath)
        }
        .sheet(isPresented: $showingRecipients) {
            RecipientPicker(recipients: network.recipients) { recipient in
                showingRecipients = false
                connect(to: recipient)
            } cancel: {
                showingRecipients = false
                network.stopBrowsing()
                sendState = files.isEmpty ? .ready : .filesSelected(files.count)
            }
            .frame(width: 420, height: 360)
        }
        // Clearing the code when a transfer changes state must not be treated as
        // a user cancellation. Only the explicit button below may cancel the
        // TLS connection.
        .alert(AppLocalization.text("pairingCode"), isPresented: Binding(get: { pairingCode != nil }, set: { _ in })) {
            Button(AppLocalization.text("cancelTransfer"), role: .cancel) { cancelPairing() }
        } message: {
            Text("\(pairingCode ?? "")\n\n\(AppLocalization.text("waitReceiver"))")
        }
        .overlay {
            if let offer = receiver.pendingOffer {
                IncomingOfferPrompt(offer: offer, accept: receiver.accept, decline: receiver.decline)
            }
        }
        .overlay {
            if let code = receiver.pendingPairingCode {
                PairingConfirmationPrompt(code: code, accept: receiver.acceptPairing, decline: receiver.declinePairing)
            }
        }
        .onAppear { network.onIncomingConnection = { connection, token, code, fingerprint in receiver.handle(connection, token: token, pairingCode: code, peerFingerprint: fingerprint) } }
        .onChange(of: scenePhase) { _, phase in
            // A listener must not remain published after the app is hidden or
            // inactive. Cancelling the listener does not cancel an already
            // accepted NWConnection, whose transfer continues independently.
            if phase != .active {
                network.stopReceiver()
                if receiveState == .waitingForSender { receiveState = .ready }
            }
        }
        .onChange(of: network.lastError) { _, error in
            if let error, receiveState == .waitingForSender { receiveState = .error(error) }
        }
        .onChange(of: receiver.result) { _, result in
            guard let result, result.skippedFileCount == 0 else { return }
            network.stopReceiver()
            receiveState = .success
        }
    }

    private var header: some View {
        HStack {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            Text("SendFile over WiFi").font(.headline)
            Spacer()
            Button(AppLocalization.text("settings"), systemImage: "gearshape") { showingSettings = true }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(surfaceColor)
    }

    @ViewBuilder private func cards(cardWidth: CGFloat? = nil) -> some View {
        ReceiveCard(state: receiveState, surfaceColor: surfaceColor, receiveProgress: receiver.progress, receiveResult: receiver.result, preferredWidth: cardWidth, showFiles: showReceivedFiles) {
            if receiveState == .waitingForSender { network.stopReceiver(); receiveState = .ready }
            else { receiver.clearCompletedResult(); network.startReceiver(name: displayName); receiveState = .waitingForSender }
        }
        SendCard(state: sendState, fileCount: files.count, surfaceColor: surfaceColor, preferredWidth: cardWidth, transferProgress: transferProgress, sendResult: sendResult, choose: {
            chooseFiles()
        }, clear: {
            files.removeAll(); transferProgress = ""; sendResult = nil; sendState = .ready
        }, search: { sendState = .searching; network.startBrowsing(); showingRecipients = true })
    }

    private func showReceivedFiles() {
        NSWorkspace.shared.open(URL(fileURLWithPath: receiveDirectoryPath, isDirectory: true))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(surfaceColor)
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    /// SwiftUI's fileImporter can be presented as a single-selection panel by
    /// some macOS versions. NSOpenPanel makes multi-selection explicit.
    private func chooseFiles() {
        let previousState = sendState
        sendState = .choosingFiles
        transferProgress = ""
        let panel = NSOpenPanel()
        panel.title = AppLocalization.text("chooseFiles")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.item]
        panel.begin { response in
            guard response == .OK else {
                sendState = previousState == .success ? .success : (files.isEmpty ? .ready : .filesSelected(files.count))
                return
            }
            if !panel.urls.isEmpty { clearPreviousSuccessfulSendResult(wasSuccessful: previousState == .success) }
            files = panel.urls
            sendState = files.isEmpty ? .ready : .filesSelected(files.count)
        }
    }

    private func clearPreviousSuccessfulSendResult(wasSuccessful: Bool? = nil) {
        guard wasSuccessful ?? (sendState == .success) else { return }
        sendResult = nil
        transferProgress = ""
    }

    private func connect(to recipient: DiscoveredRecipient) {
        selectedRecipient = recipient
        sendState = .checkingCode
        network.stopBrowsing()
        network.connect(to: recipient) { result in
            Task { @MainActor in
                if case .success(let connection) = result {
                    pairingConnection = connection
                    peerFingerprint = network.peerFingerprint(for: connection)
                    pairingCode = peerFingerprint.flatMap { TrustedDeviceStore.contains($0) ? nil : network.pairingCode(for: connection) }
                    startTransfer()
                } else if case .failure(let error) = result {
                    sendState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func cancelPairing() {
        pairingConnection?.cancel(); pairingConnection = nil; pairingCode = nil; peerFingerprint = nil
        sendState = files.isEmpty ? .ready : .filesSelected(files.count)
    }

    private func startTransfer() {
        guard let recipient = selectedRecipient, let connection = pairingConnection else { return }
        let offeredFiles = files
        sendState = .transferring
        transferProgress = ""
        sendResult = nil
        Task {
            do {
                let result = try await outgoingClient.transfer(files: offeredFiles, to: recipient, connection: connection, senderName: displayName) { current, count, bytes, total in
                    transferProgress = AppLocalization.text("sendingProgress", current, count, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                }
                let totalSize = offeredFiles.reduce(Int64(0)) { total, url in
                    total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                let sentCount = offeredFiles.count - result.skippedIndexes.count
                sendResult = result.skippedIndexes.isEmpty
                    ? AppLocalization.text("sendSuccess", sentCount, ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                    : AppLocalization.text("sendWarning", sentCount, result.skippedIndexes.count, ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))
                sendState = .success
                if let peerFingerprint { TrustedDeviceStore.trust(peerFingerprint, name: recipient.name) }
                files = offeredFiles.enumerated().compactMap { result.skippedIndexes.contains($0.offset) ? $0.element : nil }
                pairingConnection = nil
                pairingCode = nil
                peerFingerprint = nil
            } catch {
                sendState = .error(error.localizedDescription)
                pairingConnection = nil
                pairingCode = nil
                peerFingerprint = nil
            }
        }
    }
}

private struct IncomingOfferPrompt: View {
    let offer: PendingIncomingOffer
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 18) {
                Text(AppLocalization.text("acceptFiles")).font(.title3.weight(.semibold))
                Text(AppLocalization.text("filesSize", offer.fileCount, ByteCountFormatter.string(fromByteCount: offer.totalSize, countStyle: .file)))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button(AppLocalization.text("decline"), action: decline)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    Spacer()
                    Button(AppLocalization.text("accept"), action: accept)
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 20)
        }
    }
}

private struct PairingConfirmationPrompt: View {
    let code: String
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            VStack(spacing: 18) {
                Text(AppLocalization.text("checkingCode")).font(.title3.weight(.semibold))
                Text(code)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .tracking(5)
                Text(AppLocalization.text("compareCode"))
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Button(AppLocalization.text("no"), action: decline)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    Spacer()
                    Button(AppLocalization.text("yes"), action: accept)
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 20)
        }
    }
}

private struct RecipientPicker: View {
    let recipients: [DiscoveredRecipient]
    let select: (DiscoveredRecipient) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(AppLocalization.text("chooseRecipient")).font(.headline)
                Spacer()
                Button(AppLocalization.text("cancel"), action: cancel)
            }
            if recipients.isEmpty { Spacer(); ProgressView(AppLocalization.text("searching")); Spacer() }
            else { List(recipients) { recipient in Button(recipient.name) { select(recipient) } } }
        }.padding()
    }
}

private struct ReceiveCard: View {
    let state: TransferState
    let surfaceColor: Color
    let receiveProgress: IncomingTransferProgress?
    let receiveResult: IncomingTransferResult?
    let preferredWidth: CGFloat?
    let showFiles: () -> Void
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrow.down.to.line.compact").font(.system(size: 30, weight: .semibold))
                Spacer()
                if state == .waitingForSender { Radar() }
                Button(AppLocalization.text(state == .success ? "receiveAgain" : state == .waitingForSender ? "stop" : "receiveButton"), action: action)
                    .transferButtonContent()
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 66)
            }
            Text(AppLocalization.text("receive")).font(.title2.weight(.bold))
            Spacer()
            Text(state.title).font(.headline)
            Text(state.detail).foregroundStyle(.secondary)
            if let receiveProgress {
                let percent = receiveProgress.totalBytes == 0 ? 100 : Int(Double(receiveProgress.transferredBytes) * 100 / Double(receiveProgress.totalBytes))
                Text(AppLocalization.text("transferProgress", receiveProgress.currentFile, receiveProgress.fileCount, ByteCountFormatter.string(fromByteCount: receiveProgress.transferredBytes, countStyle: .file), ByteCountFormatter.string(fromByteCount: receiveProgress.totalBytes, countStyle: .file), percent))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let receiveResult {
                Text(receiveResult.skippedFileCount == 0
                     ? AppLocalization.text("receiveSuccess", receiveResult.receivedFileCount, ByteCountFormatter.string(fromByteCount: receiveResult.totalSize, countStyle: .file))
                     : AppLocalization.text("receiveWarning", receiveResult.receivedFileCount, receiveResult.skippedFileCount, ByteCountFormatter.string(fromByteCount: receiveResult.totalSize, countStyle: .file)))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(receiveResult.skippedFileCount == 0 ? .green : .orange)
                    .textSelection(.enabled)
            }
            if (receiveResult?.receivedFileCount ?? 0) > 0 {
                Spacer(minLength: 0)
                Button(AppLocalization.text("showFiles"), action: showFiles)
                    .transferButtonContent()
                    .buttonStyle(.bordered)
                    .frame(minHeight: 66)
            }
        }
        .frame(maxWidth: preferredWidth ?? .infinity, alignment: .leading)
        .frame(width: preferredWidth, alignment: .leading)
        .padding(20)
        .background(surfaceColor, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.22), lineWidth: 1))
    }
}

private struct SendCard: View {
    let state: TransferState
    let fileCount: Int
    let surfaceColor: Color
    let preferredWidth: CGFloat?
    let transferProgress: String
    let sendResult: String?
    let choose: () -> Void
    let clear: () -> Void
    let search: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrow.up.to.line.compact").font(.system(size: 30, weight: .semibold))
                Spacer()
                if fileCount > 0 {
                    Button(AppLocalization.text("findRecipient"), action: search)
                        .transferButtonContent()
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 66)
                } else if state == .searching || state == .checkingCode { Radar() }
            }
            Text(AppLocalization.text("send")).font(.title2.weight(.bold))
            Spacer()
            HStack {
                Text(state.title)
                    .font(.headline)
                    .foregroundStyle(state == .success ? .green : .primary)
                Spacer()
                if fileCount > 0 {
                    Button(action: clear) { Image(systemName: "trash") }
                        .transferButtonContent()
                        .frame(minWidth: 66, minHeight: 66)
                        .accessibilityLabel(AppLocalization.text("clearFileList"))
                }
            }
            Text(state.detail)
                .foregroundStyle(state == .success ? .green : .secondary)
                .textSelection(.enabled)
            if !transferProgress.isEmpty {
                Text(transferProgress)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let sendResult {
                Text(sendResult)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(state == .success ? .green : .orange)
                    .textSelection(.enabled)
            }
            if fileCount == 0 {
                Button(AppLocalization.text("chooseFiles"), action: choose)
                    .transferButtonContent()
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 66)
            }
        }
        .frame(maxWidth: preferredWidth ?? .infinity, alignment: .leading)
        .frame(width: preferredWidth, alignment: .leading)
        .padding(20)
        .background(surfaceColor, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.22), lineWidth: 1))
    }
}

private struct Radar: View {
    var body: some View {
        TimelineView(.animation) { time in
            ZStack {
                Circle().stroke(.tint.opacity(0.22), lineWidth: 2)
                Circle().trim(from: 0.02, to: 0.28).stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(time.date.timeIntervalSinceReferenceDate * 150))
                Circle().fill(.tint).frame(width: 6, height: 6)
            }
        }.frame(width: 38, height: 38)
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var displayName: String
    @Binding var theme: String
    @Binding var language: String
    @Binding var preserveDates: Bool
    @Binding var receiveDirectoryPath: String
    @State private var trustedDevices: [TrustedDevice] = []
    var body: some View {
        Form {
            TextField(AppLocalization.text("displayName"), text: $displayName)
            Picker(AppLocalization.text("theme"), selection: $theme) { ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) } }
            Picker(AppLocalization.text("language"), selection: $language) {
                ForEach(["", "en", "ru", "it", "es", "pt", "cn"], id: \.self) { code in
                    Text(code.isEmpty ? AppLocalization.text("automatic") : AppLocalization.languageName(code)).tag(code)
                }
            }
            Toggle(AppLocalization.text("saveDates"), isOn: $preserveDates)
            HStack {
                TextField(AppLocalization.text("downloadDirectory"), text: $receiveDirectoryPath)
                Button(AppLocalization.text("choose"), action: chooseReceiveDirectory)
            }
            if trustedDevices.isEmpty {
                Text(AppLocalization.text("noTrustedDevices")).foregroundStyle(.secondary)
            } else {
                ForEach(trustedDevices) { device in
                    HStack {
                        Text(device.name)
                        Spacer()
                        Button(role: .destructive) {
                            TrustedDeviceStore.remove(device.fingerprint)
                            reloadTrustedDevices()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("\(AppLocalization.text("delete")) \(device.name)")
                    }
                }
            }
            HStack { Spacer(); Button(AppLocalization.text("done")) { dismiss() } }
        }
        .padding(24).frame(width: 460)
        .onAppear(perform: reloadTrustedDevices)
    }

    private func chooseReceiveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: receiveDirectoryPath)
        if panel.runModal() == .OK, let url = panel.url {
            receiveDirectoryPath = url.path
            if let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(bookmark, forKey: "receiveDirectoryBookmark")
            }
        }
    }

    private func reloadTrustedDevices() {
        trustedDevices = TrustedDeviceStore.records()
    }
}
