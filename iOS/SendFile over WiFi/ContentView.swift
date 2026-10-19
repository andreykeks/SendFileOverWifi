import SwiftUI
import UniformTypeIdentifiers
import Network
import UIKit
import Photos
import PhotosUI
import StoreKit
import AVFoundation
import AVKit
import ImageIO
import QuickLook

private extension View {
    /// Applied before a button style so the visible control, not just its hit area, grows.
    func transferButtonContent() -> some View {
        font(.title3.weight(.semibold))
            .padding(.vertical, 14)
    }
}

private enum TransferStatus: Equatable {
    case ready
    case selectingFiles
    case waitingForSender
    case filesSelected(Int)
    case searchingRecipients
    case checkingPairingCode
    case transferring
    case success
    case error(String)

    var title: String {
        switch self {
        case .ready: AppLocalization.text("ready")
        case .selectingFiles: AppLocalization.text("selectContent")
        case .waitingForSender: AppLocalization.text("waitingSender")
        case .filesSelected(let count): AppLocalization.text("selectedFiles", count)
        case .searchingRecipients: AppLocalization.text("searchRecipient")
        case .checkingPairingCode: AppLocalization.text("checkingCode")
        case .transferring: AppLocalization.text("transferring")
        case .success: AppLocalization.text("success")
        case .error: AppLocalization.text("error")
        }
    }

    var detail: String {
        switch self {
        case .ready: AppLocalization.text("pressStart")
        case .selectingFiles: AppLocalization.text("usePhotoFiles")
        case .waitingForSender: AppLocalization.text("wifiAvailable")
        case .filesSelected: AppLocalization.text("pressSearch")
        case .searchingRecipients: AppLocalization.text("searchingDevices")
        case .checkingPairingCode: AppLocalization.text("secureConnection")
        case .transferring: AppLocalization.text("sendingFiles")
        case .success: AppLocalization.text("filesSent")
        case .error(let message): message
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("displayName") private var displayName = UIDevice.current.name
    @AppStorage("theme") private var theme = AppTheme.system.rawValue
    @AppStorage("language") private var language = ""
    @AppStorage("preserveDates") private var preserveDates = false

    @State private var receiveStatus: TransferStatus = .ready
    @State private var sendStatus: TransferStatus = .ready
    @State private var selectedFiles: [URL] = []
    @State private var isImporting = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isShowingSettings = false
    @State private var isShowingReceivedFiles = false
    @State private var isShowingMultiFilePaywall = false
    @StateObject private var network = LocalNetworkService()
    @StateObject private var receiver = ReceiverSessionCoordinator()
    @StateObject private var multiFilePurchase = MultiFileTransferPurchase()
    // Deliberately enabled for pre-release protocol debugging. Set to false
    // before an App Store release to restore the StoreKit entitlement gate.
    private let debugAllowsMultipleFileSending = true
    @State private var selectedRecipient: DiscoveredRecipient?
    @State private var pairingCode: String?
    @State private var pairingConnection: NWConnection?
    @State private var transferProgress = ""
    @State private var sendResult: String?
    @State private var peerFingerprint: String?
    private let outgoingClient = OutgoingTransferClient()

    private var preferredColorScheme: ColorScheme? {
        AppTheme(rawValue: theme)?.colorScheme
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let isVertical = geometry.size.width < geometry.size.height

                VStack(spacing: 0) {
                    header

                    if isVertical {
                        ScrollView(.vertical) {
                            VStack(spacing: 16) { transferCards() }
                                .padding(20)
                        }
                        .scrollIndicators(.visible)
                    } else {
                        // Landscape presents both cards next to each other;
                        // horizontal scrolling is only a fallback for overflow.
                        let cardWidth = max(280, (geometry.size.width - 56) / 2)
                        ScrollView(.horizontal) {
                            HStack(spacing: 16) { transferCards(cardWidth: cardWidth) }
                                .padding(20)
                        }
                        .scrollIndicators(.visible)
                    }

                    footer
                }
                .background(Color(uiColor: .systemBackground))
            }
            .navigationDestination(isPresented: $isShowingReceivedFiles) {
                ReceivedFilesView()
            }
        }
        .preferredColorScheme(preferredColorScheme)
        .environment(\.locale, Locale(identifier: AppLocalization.resolvedLanguage(language) == "cn" ? "zh_Hans" : AppLocalization.resolvedLanguage(language)))
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            handleFileSelection($0)
        }
        .onChange(of: selectedPhotoItems) { _, items in
            Task { await importPhotos(items) }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(
                displayName: $displayName,
                theme: $theme,
                language: $language,
                preserveDates: $preserveDates
            )
        }
        .sheet(isPresented: $isShowingMultiFilePaywall) {
            MultiFilePaywall(purchase: multiFilePurchase)
                .presentationDetents([.medium])
        }
        .onAppear {
            network.onIncomingConnection = { connection, token, code, fingerprint in receiver.handle(connection, token: token, pairingCode: code, peerFingerprint: fingerprint) }
            UserDefaults(suiteName: SharedImportInbox.appGroup)?.set(language, forKey: "language")
            importSharedFiles()
        }
        .onChange(of: language) { _, value in
            UserDefaults(suiteName: SharedImportInbox.appGroup)?.set(value, forKey: "language")
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
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                importSharedFiles()
            }
            if newPhase != .active {
                stopReceiver()
            }
        }
        .onChange(of: network.lastError) { _, error in
            if let error, receiveStatus == .waitingForSender {
                receiveStatus = .error(error)
            }
        }
        .onChange(of: receiver.result) { _, result in
            guard let result, result.skippedFileCount == 0 else { return }
            network.stopReceiver()
            receiveStatus = .success
        }
    }

    private var header: some View {
        HStack {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            Text("SendFile over WiFi").font(.headline)
            Spacer()
            Button("Pro") { isShowingMultiFilePaywall = true }
                .font(.headline.weight(.semibold))
                .frame(minWidth: 52, minHeight: 52)
                .accessibilityLabel("Pro: \(AppLocalization.text("proTitle"))")
            Button(AppLocalization.text("yourFiles"), systemImage: "folder") { isShowingReceivedFiles = true }
                .labelStyle(.iconOnly)
                .accessibilityLabel(AppLocalization.text("yourFiles"))
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 52, height: 52)
            Button(AppLocalization.text("settings"), systemImage: "gearshape") { isShowingSettings = true }
                .labelStyle(.iconOnly)
                .accessibilityLabel(AppLocalization.text("settings"))
                .font(.system(size: 30, weight: .semibold))
                .frame(width: 52, height: 52)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    @ViewBuilder
    private func transferCards(cardWidth: CGFloat? = nil) -> some View {
        TransferCard(
            title: AppLocalization.text("receive"),
            systemImage: "arrow.down.to.line.compact",
            status: receiveStatus,
            showsRadar: receiveStatus == .waitingForSender,
            receiveProgress: receiver.progress,
            receiveResult: receiver.result,
            preferredWidth: cardWidth,
            openReceivedFiles: { isShowingReceivedFiles = true },
            copyError: { UIPasteboard.general.string = network.lastError ?? "" }
        ) {
            if receiveStatus == .waitingForSender {
                stopReceiver()
            } else {
                receiver.clearCompletedResult()
                receiveStatus = .waitingForSender
                network.startReceiver(name: displayName)
            }
        }

        SendTransferCard(
            status: sendStatus,
            selectedFileCount: selectedFiles.count,
            discoveredRecipients: network.recipients,
            selectedRecipient: selectedRecipient,
            pairingCode: pairingCode,
            transferProgress: transferProgress,
            sendResult: sendResult,
            preferredWidth: cardWidth,
            photoItems: $selectedPhotoItems,
            chooseFiles: chooseFiles,
            clearFiles: clearSelectedFiles,
            findRecipient: findRecipient,
            selectRecipient: selectRecipient,
            cancelSearch: cancelRecipientSearch
        )
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("v\(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if !urls.isEmpty { clearPreviousSuccessfulSendResult() }
            selectedFiles = urls
            sendStatus = urls.isEmpty ? .ready : .filesSelected(urls.count)
        case .failure:
            if sendStatus != .success { sendStatus = .ready }
        }
    }

    private func importSharedFiles() {
        let sharedFiles = SharedImportInbox.consumeIntoTemporaryDirectory()
        guard !sharedFiles.isEmpty else { return }
        clearPreviousSuccessfulSendResult()
        selectedFiles.append(contentsOf: sharedFiles)
        sendStatus = .filesSelected(selectedFiles.count)
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        if sendStatus != .success { sendStatus = .selectingFiles }
        var imported: [URL] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let fileExtension = type?.preferredFilenameExtension ?? "jpg"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("photo-\(UUID().uuidString).\(fileExtension)")
            do {
                try data.write(to: url, options: .atomic)
                imported.append(url)
            } catch {}
        }
        if !imported.isEmpty { clearPreviousSuccessfulSendResult() }
        selectedFiles.append(contentsOf: imported)
        selectedPhotoItems = []
        sendStatus = selectedFiles.isEmpty ? .ready : .filesSelected(selectedFiles.count)
    }

    private func chooseFiles() {
        if sendStatus != .success { sendStatus = .selectingFiles }
        isImporting = true
    }

    private func clearSelectedFiles() {
        selectedFiles.removeAll()
        transferProgress = ""
        sendResult = nil
        sendStatus = .ready
        cancelRecipientSearch()
    }

    private func clearPreviousSuccessfulSendResult() {
        guard sendStatus == .success else { return }
        sendResult = nil
        transferProgress = ""
    }

    private func findRecipient() {
        guard !selectedFiles.isEmpty else { return }
        guard debugAllowsMultipleFileSending || selectedFiles.count == 1 || multiFilePurchase.isUnlocked else {
            isShowingMultiFilePaywall = true
            return
        }
        selectedRecipient = nil
        pairingCode = nil
        transferProgress = ""
        sendResult = nil
        sendStatus = .searchingRecipients
        network.startBrowsing()
    }

    private func selectRecipient(_ recipient: DiscoveredRecipient) {
        selectedRecipient = recipient
        pairingCode = nil
        sendStatus = .checkingPairingCode
        network.stopBrowsing()
        network.connect(to: recipient) { result in
            Task { @MainActor in
                switch result {
                case .success(let connection):
                    pairingConnection = connection
                    peerFingerprint = network.peerFingerprint(for: connection)
                    pairingCode = peerFingerprint.flatMap { TrustedDeviceStore.contains($0) ? nil : network.pairingCode(for: connection) }
                    confirmPairing()
                case .failure:
                    sendStatus = .ready
                }
            }
        }
    }

    private func cancelRecipientSearch() {
        network.stopBrowsing()
        pairingConnection?.cancel()
        pairingConnection = nil
        peerFingerprint = nil
        selectedRecipient = nil
        pairingCode = nil
        if sendStatus == .searchingRecipients || sendStatus == .checkingPairingCode || sendStatus == .transferring {
            sendStatus = selectedFiles.isEmpty ? .ready : .filesSelected(selectedFiles.count)
        }
    }

    private func confirmPairing() {
        guard let recipient = selectedRecipient, let connection = pairingConnection else { return }
        guard debugAllowsMultipleFileSending || selectedFiles.count == 1 || multiFilePurchase.isUnlocked else {
            cancelRecipientSearch()
            sendStatus = .error(AppLocalization.text("proRequired"))
            return
        }
        sendStatus = .transferring
        transferProgress = ""
        sendResult = nil
        let offeredFiles = selectedFiles
        let backgroundLease = IOSBackgroundTransferLease()
        backgroundLease.begin()
        Task {
            defer { backgroundLease.end() }
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
                sendStatus = .success
                if let peerFingerprint { TrustedDeviceStore.trust(peerFingerprint, name: recipient.name) }
                selectedFiles = offeredFiles.enumerated().compactMap { result.skippedIndexes.contains($0.offset) ? $0.element : nil }
                pairingConnection = nil
                pairingCode = nil
                peerFingerprint = nil
            } catch {
                sendStatus = .error(error.localizedDescription)
                pairingConnection = nil
                pairingCode = nil
                peerFingerprint = nil
            }
        }
    }

    private func stopReceiver() {
        guard receiveStatus == .waitingForSender else { return }
        network.stopReceiver()
        receiveStatus = .ready
    }
}

private struct ReceivedFile: Identifiable {
    let url: URL
    let creationDate: Date

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.isEmpty ? "—" : url.pathExtension.uppercased() }

    var type: UTType? {
        UTType(filenameExtension: url.pathExtension)
    }

    var isImage: Bool { type?.conforms(to: .image) == true }
    var isVideo: Bool { type?.conforms(to: .movie) == true }
    var isText: Bool { type?.conforms(to: .text) == true }

    var systemIcon: String {
        if isImage { return "photo" }
        if isVideo { return "video" }
        if type?.conforms(to: .audio) == true { return "music.note" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if isText { return "doc.text" }
        if ["zip", "rar", "7z", "tar", "gz"].contains(url.pathExtension.lowercased()) { return "archivebox" }
        return "doc"
    }
}

private struct ReceivedFilesView: View {
    @State private var files: [ReceivedFile] = []
    @State private var selection = Set<URL>()
    @State private var confirmClear = false
    @State private var isShowingShareSheet = false
    @State private var photoSaveError: String?
    @State private var previewFile: ReceivedFile?

    var body: some View {
        List(files, selection: $selection) { file in
            HStack(spacing: 12) {
                ReceivedFileThumbnail(file: file)
                Button { previewFile = file } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name).lineLimit(1)
                        Text("\(file.fileExtension) · \(file.creationDate.formatted(date: .numeric, time: .shortened))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if files.isEmpty {
                ContentUnavailableView(AppLocalization.text("noReceivedFiles"), systemImage: "folder", description: Text(AppLocalization.text("receivedFilesHint")))
            }
        }
        .navigationTitle(AppLocalization.text("yourFiles"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItemGroup(placement: .bottomBar) {
                if !selection.isEmpty {
                    Button(action: { isShowingShareSheet = true }) {
                        Label(AppLocalization.text("share"), systemImage: "square.and.arrow.up")
                    }
                    if !selectedMedia.isEmpty {
                        Button(AppLocalization.text("saveToPhotos"), action: saveMediaToPhotos)
                    }
                    Button(role: .destructive, action: deleteSelection) {
                        Label(AppLocalization.text("delete"), systemImage: "trash")
                    }
                }
                Spacer()
                Button(AppLocalization.text("clearAll"), role: .destructive) { confirmClear = true }
                    .disabled(files.isEmpty)
            }
        }
        .alert(AppLocalization.text("deleteAllReceived"), isPresented: $confirmClear) {
            Button(AppLocalization.text("cancel"), role: .cancel) {}
            Button(AppLocalization.text("deleteAll"), role: .destructive, action: clearAll)
        } message: {
            Text(AppLocalization.text("deleteReceivedHint"))
        }
        .alert(AppLocalization.text("savePhotosFailed"), isPresented: Binding(get: { photoSaveError != nil }, set: { if !$0 { photoSaveError = nil } })) {
            Button("OK") { photoSaveError = nil }
        } message: {
            Text(photoSaveError ?? "")
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityShareSheet(items: Array(selection))
        }
        .sheet(item: $previewFile) { file in
            ReceivedFilePreview(file: file)
        }
        .onAppear(perform: reload)
    }

    private var selectedMedia: [URL] {
        selection.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .movie)
        }
    }

    private func receivedDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Received Files", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func reload() {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .creationDateKey]
        let urls = (FileManager.default.enumerator(
            at: receivedDirectory(),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )?.allObjects as? [URL]) ?? []
        files = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { return nil }
            return ReceivedFile(url: url, creationDate: values?.creationDate ?? .distantPast)
        }
        .sorted { $0.creationDate > $1.creationDate }
        selection.formIntersection(Set(files.map(\.url)))
    }

    private func deleteSelection() {
        selection.forEach { try? FileManager.default.removeItem(at: $0) }
        selection.removeAll()
        reload()
    }

    private func clearAll() {
        let directory = receivedDirectory()
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.forEach {
            try? FileManager.default.removeItem(at: $0)
        }
        selection.removeAll()
        reload()
    }

    private func saveMediaToPhotos() {
        let media = selectedMedia
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { photoSaveError = AppLocalization.text("photosPermission") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                for url in media {
                    guard let type = UTType(filenameExtension: url.pathExtension) else { continue }
                    if type.conforms(to: .image) {
                        PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                    } else if type.conforms(to: .movie) {
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }
                }
            } completionHandler: { success, error in
                guard !success else { return }
                DispatchQueue.main.async { photoSaveError = error?.localizedDescription ?? AppLocalization.text("systemSaveFailed") }
            }
        }
    }
}

private struct ReceivedFileThumbnail: View {
    let file: ReceivedFile

    var body: some View {
        Group {
            if let image = thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: file.systemIcon)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 44, height: 44)
        .background(Color(uiColor: .tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var thumbnail: UIImage? {
        if file.isImage { return imageThumbnail(at: file.url) }
        if file.isVideo { return videoThumbnail(at: file.url) }
        return nil
    }

    private func imageThumbnail(at url: URL) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private func videoThumbnail(at url: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct ReceivedFilePreview: View {
    let file: ReceivedFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if file.isImage, let image = UIImage(contentsOfFile: file.url.path) {
                    ZoomableImagePreview(image: image)
                    .background(Color.black)
                } else if file.isVideo {
                    VideoPreview(url: file.url)
                } else if file.isText, let text = try? String(contentsOf: file.url, encoding: .utf8) {
                    ScrollView {
                        Text(text)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else {
                    QuickLookPreview(url: file.url)
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.text("done")) { dismiss() }
                }
            }
        }
    }
}

/// Keeps the complete image visible initially and lets the user zoom and pan it
/// with the native UIScrollView pinch gesture.
private struct ZoomableImagePreview: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        ZoomingImageScrollView(image: image)
    }

    func updateUIView(_ scrollView: ZoomingImageScrollView, context: Context) {
        scrollView.setImage(image)
    }
}

private final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var imageSize: CGSize = .zero
    private var needsInitialScale = true

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        bouncesZoom = true
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .black
        imageView.contentMode = .scaleToFill
        addSubview(imageView)
        setImage(image)
    }

    required init?(coder: NSCoder) { nil }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        imageSize = image.size
        needsInitialScale = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }

        if needsInitialScale {
            imageView.frame = CGRect(origin: .zero, size: imageSize)
            contentSize = imageSize
            let fitScale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            minimumZoomScale = fitScale
            maximumZoomScale = fitScale * 8
            zoomScale = fitScale
            needsInitialScale = false
        }
        centerImageIfNeeded()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageIfNeeded()
    }

    private func centerImageIfNeeded() {
        var frame = imageView.frame
        frame.origin.x = frame.width < bounds.width ? (bounds.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < bounds.height ? (bounds.height - frame.height) / 2 : 0
        imageView.frame = frame
    }
}

private struct VideoPreview: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct IncomingOfferPrompt: View {
    let offer: PendingIncomingOffer
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
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
            Color.black.opacity(0.35).ignoresSafeArea()
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

private struct TransferCard: View {
    let title: String
    let systemImage: String
    let status: TransferStatus
    let showsRadar: Bool
    let receiveProgress: IncomingTransferProgress?
    let receiveResult: IncomingTransferResult?
    let preferredWidth: CGFloat?
    let openReceivedFiles: () -> Void
    let copyError: () -> Void
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Image(systemName: systemImage).font(.system(size: 30, weight: .semibold))
                Spacer()
                if showsRadar {
                    RadarActivityIndicator()
                        .accessibilityLabel(AppLocalization.text("wifiAvailable"))
                }
                Button(AppLocalization.text(status == .success ? "receiveAgain" : showsRadar ? "stop" : "receiveButton"), action: action)
                    .transferButtonContent()
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 66)
            }
            Text(title).font(.title2.weight(.bold))
            Spacer(minLength: 10)
            Text(status.title).font(.headline)
            Text(status.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            if let receiveProgress {
                let percent = receiveProgress.totalBytes == 0 ? 100 : Int(Double(receiveProgress.transferredBytes) * 100 / Double(receiveProgress.totalBytes))
                Text(AppLocalization.text("transferProgress", receiveProgress.currentFile, receiveProgress.fileCount, ByteCountFormatter.string(fromByteCount: receiveProgress.transferredBytes, countStyle: .file), ByteCountFormatter.string(fromByteCount: receiveProgress.totalBytes, countStyle: .file), percent))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let receiveResult {
                Text(receiveResult.skippedFileCount == 0
                     ? AppLocalization.text("receiveSuccess", receiveResult.receivedFileCount, ByteCountFormatter.string(fromByteCount: receiveResult.totalSize, countStyle: .file))
                     : AppLocalization.text("receiveWarning", receiveResult.receivedFileCount, receiveResult.skippedFileCount, ByteCountFormatter.string(fromByteCount: receiveResult.totalSize, countStyle: .file)))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(receiveResult.skippedFileCount == 0 ? .green : .orange)
            }
            if case .error = status {
                Button(AppLocalization.text("copyError"), action: copyError)
                    .transferButtonContent()
                    .buttonStyle(.bordered)
                    .frame(minHeight: 66)
            }
            HStack(spacing: 12) {
                if receiveResult != nil {
                    Button(AppLocalization.text("view"), action: openReceivedFiles)
                        .transferButtonContent()
                        .buttonStyle(.bordered)
                        .frame(minHeight: 66)
                }
            }
        }
        .frame(maxWidth: preferredWidth ?? .infinity, alignment: .leading)
        .frame(width: preferredWidth, alignment: .leading)
        .padding(20)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityHint(status.detail)
    }
}

private struct RadarActivityIndicator: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate

            ZStack {
                Circle().stroke(.tint.opacity(0.22), lineWidth: 2)
                Circle()
                    .trim(from: 0.02, to: 0.28)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(phase * 150))
                Circle().fill(.tint).frame(width: 6, height: 6)
            }
        }
        .frame(width: 38, height: 38)
    }
}

private struct MultiFilePaywall: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var purchase: MultiFileTransferPurchase

    var body: some View {
        VStack(spacing: 18) {
            Text(AppLocalization.text("proTitle"))
                .font(.title2.weight(.bold))
            Text(AppLocalization.text("proDescription"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(AppLocalization.text("oneTime", purchase.product?.displayPrice ?? "…"))
                .font(.headline)
            Button(AppLocalization.text(purchase.isLoading ? "loading" : "upgradePro")) {
                Task {
                    await purchase.purchase()
                    if purchase.isUnlocked { dismiss() }
                }
            }
            .transferButtonContent()
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 66)
            .disabled(purchase.isLoading)
            Button(AppLocalization.text("restorePurchases")) {
                Task {
                    await purchase.restore()
                    if purchase.isUnlocked { dismiss() }
                }
            }
            .buttonStyle(.bordered)
            .disabled(purchase.isLoading)
            if let message = purchase.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .onChange(of: purchase.isUnlocked) { _, isUnlocked in
            if isUnlocked { dismiss() }
        }
    }
}

private struct SendTransferCard: View {
    let status: TransferStatus
    let selectedFileCount: Int
    let discoveredRecipients: [DiscoveredRecipient]
    let selectedRecipient: DiscoveredRecipient?
    let pairingCode: String?
    let transferProgress: String
    let sendResult: String?
    let preferredWidth: CGFloat?
    @Binding var photoItems: [PhotosPickerItem]
    let chooseFiles: () -> Void
    let clearFiles: () -> Void
    let findRecipient: () -> Void
    let selectRecipient: (DiscoveredRecipient) -> Void
    let cancelSearch: () -> Void

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "arrow.up.to.line.compact")
                        .font(.system(size: 30, weight: .semibold))
                    Spacer()
                    if selectedFileCount > 0 {
                        Button(AppLocalization.text("findRecipient"), action: findRecipient)
                            .transferButtonContent()
                            .buttonStyle(.borderedProminent)
                            .frame(minHeight: 66)
                    }
                }
                Text(AppLocalization.text("send")).font(.title2.weight(.bold))
                Spacer(minLength: 10)
                HStack {
                    Text(status.title)
                        .font(.headline)
                        .foregroundStyle(status == .success ? .green : .primary)
                    Spacer()
                    if selectedFileCount > 0 {
                        Button(action: clearFiles) {
                            Image(systemName: "trash")
                        }
                        .transferButtonContent()
                        .buttonStyle(.bordered)
                        .frame(minWidth: 66, minHeight: 66)
                        .accessibilityLabel(AppLocalization.text("clearFileList"))
                    }
                }
                Text(status.detail)
                    .font(.subheadline)
                    .foregroundStyle(status == .success ? .green : .secondary)
                    .multilineTextAlignment(.leading)
                if !transferProgress.isEmpty {
                    Text(transferProgress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                if let sendResult {
                    Text(sendResult)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(status == .success ? .green : .orange)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: 12) {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: nil, matching: .any(of: [.images, .videos])) {
                        Label(AppLocalization.text("photos"), systemImage: "photo.on.rectangle")
                    }
                    .transferButtonContent()
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 66)
                    Button(action: chooseFiles) {
                        Label(AppLocalization.text("files"), systemImage: "doc")
                    }
                    .transferButtonContent()
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 66)
                }

            }
            .padding(20)

            if status == .searchingRecipients || status == .checkingPairingCode || pairingCode != nil || !discoveredRecipients.isEmpty {
                recipientOverlay
            }
        }
        .frame(maxWidth: preferredWidth ?? .infinity, alignment: .leading)
        .frame(width: preferredWidth, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var recipientOverlay: some View {
        VStack(spacing: 16) {
            if let recipient = selectedRecipient {
                Text(recipient.name).font(.headline)
                if let pairingCode {
                    Text(pairingCode)
                        .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                        .tracking(5)
                    Text(AppLocalization.text("compareCode"))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                } else {
                    RadarActivityIndicator()
                    Text(AppLocalization.text("secureConnection"))
                        .multilineTextAlignment(.center)
                }
            } else if discoveredRecipients.isEmpty {
                RadarActivityIndicator()
                Text(AppLocalization.text("searchRecipient"))
                    .font(.headline)
                Text(AppLocalization.text("searchingDevices"))
                    .foregroundStyle(.secondary)
            } else {
                Text(AppLocalization.text("chooseRecipient")).font(.headline)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(discoveredRecipients) { recipient in
                            Button {
                                selectRecipient(recipient)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(recipient.name).foregroundStyle(.primary)
                                        Text(AppLocalization.text("searchingDevices"))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                                .padding(12)
                                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Button(AppLocalization.text("cancel"), action: cancelSearch)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private enum AppTheme: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: AppLocalization.text("systemTheme")
        case .dark: AppLocalization.text("darkTheme")
        case .light: AppLocalization.text("lightTheme")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

private struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var displayName: String
    @Binding var theme: String
    @Binding var language: String
    @Binding var preserveDates: Bool
    @State private var trustedDevices: [TrustedDevice] = []
    private let languages = ["", "en", "ru", "it", "es", "pt", "cn"]

    var body: some View {
        NavigationStack {
            Form {
                Section(AppLocalization.text("displayName")) {
                    TextField(AppLocalization.text("displayName"), text: $displayName)
                        .textInputAutocapitalization(.words)
                }
                Section(AppLocalization.text("appearance")) {
                    Picker(AppLocalization.text("theme"), selection: $theme) {
                        ForEach(AppTheme.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker(AppLocalization.text("language"), selection: $language) {
                        ForEach(languages, id: \.self) { Text($0.isEmpty ? AppLocalization.text("automatic") : AppLocalization.languageName($0)).tag($0) }
                    }
                }
                Section(AppLocalization.text("files")) {
                    Toggle(AppLocalization.text("saveDates"), isOn: $preserveDates)
                }
                Section(AppLocalization.text("trustedDevices")) {
                    if trustedDevices.isEmpty {
                        Text(AppLocalization.text("noTrustedDevices"))
                            .foregroundStyle(.secondary)
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
                }
            }
            .navigationTitle(AppLocalization.text("settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(AppLocalization.text("done")) { dismiss() } }
            }
        }
        .onAppear(perform: reloadTrustedDevices)
    }

    private func reloadTrustedDevices() {
        trustedDevices = TrustedDeviceStore.records()
    }
}
