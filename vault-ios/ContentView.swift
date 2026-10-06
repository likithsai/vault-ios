import SwiftUI
import QuickLook
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var manager = VaultManager()

    // Navigation & Folder Hierarchy State
    @State private var currentFolderId: UUID? = nil
    @State private var navigationStackPath: [(id: UUID?, name: String)] = [(nil, "Vault")]

    // Search and Sort
    @State private var searchFilter = ""
    @State private var sortOption: VaultSortOption = .name
    @State private var sortAscending = true

    // Importer / Exporter Modals
    @State private var isVaultPickerOpen = false
    @State private var isVaultSaverOpen = false
    @State private var isDocumentPickerOpen = false
    @State private var pendingTargetURL: URL? = nil

    // Authentication & Rekey Sheets
    @State private var isPresentingUnlockSheet = false
    @State private var isCreatingVault = false
    @State private var passwordBuffer = ""
    @State private var rememberBiometrics = false
    @State private var isShowingVaultInfo = false
    @State private var isShowingRekeySheet = false
    @State private var newRekeyPasswordBuffer = ""

    // Folder & File Management Modals
    @State private var isCreatingFolder = false
    @State private var newFolderNameBuffer = ""
    @State private var renamingItem: (id: UUID, name: String, isFolder: Bool)? = nil
    @State private var updatedNameBuffer = ""
    @State private var movingItem: (id: UUID, name: String, isFolder: Bool)? = nil
    @State private var detailedFileItem: EncryptedFileHeader? = nil

    // Export & QuickLook Preview State
    @State private var previewFileLocation: URL? = nil
    @State private var shareSheetItem: ShareItem? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                if manager.isUnlocked {
                    VStack(spacing: 0) {
                        customPathHeader
                        activeIndexedList
                    }
                } else {
                    emptyStateLanding
                }
            }
            .navigationBarHidden(true)
            .fileImporter(
                isPresented: $isVaultPickerOpen,
                allowedContentTypes: [UTType.item],
                allowsMultipleSelection: false
            ) { result in
                handleVaultSelection(result)
            }
            .fileExporter(
                isPresented: $isVaultSaverOpen,
                document: BlankVaultDocument(),
                contentType: .data,
                defaultFilename: "IronVault.ivault"
            ) { result in
                if case .success(let url) = result {
                    pendingTargetURL = url
                    isCreatingVault = true
                    isPresentingUnlockSheet = true
                }
            }
            .fileImporter(
                isPresented: $isDocumentPickerOpen,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                handleFileImports(result)
            }
            .sheet(isPresented: $isPresentingUnlockSheet) {
                passwordModalSheet.presentationDetents([.fraction(0.42)])
            }
            .sheet(isPresented: $isShowingRekeySheet) {
                rekeyModalSheet.presentationDetents([.fraction(0.35)])
            }
            .sheet(isPresented: $isShowingVaultInfo) {
                vaultInfoSheet.presentationDetents([.fraction(0.48)])
            }
            .sheet(item: $detailedFileItem) { file in
                fileDetailsModal(file: file).presentationDetents([.fraction(0.40)])
            }
            .sheet(item: Binding(
                get: { movingItem != nil ? MoveItemWrapper(item: movingItem!) : nil },
                set: { movingItem = $0?.item }
            )) { wrapper in
                moveItemSheet(item: wrapper.item).presentationDetents([.medium])
            }
            .sheet(item: $shareSheetItem) { item in
                ShareActivityView(activityItems: [item.url])
            }
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Folder Name", text: $newFolderNameBuffer)
                Button("Create") {
                    let name = newFolderNameBuffer.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        Task {
                            await manager.createFolder(name: name, parentId: currentFolderId)
                            newFolderNameBuffer = ""
                        }
                    }
                }
                Button("Cancel", role: .cancel) { newFolderNameBuffer = "" }
            }
            .alert("Rename", isPresented: Binding(
                get: { renamingItem != nil },
                set: { if !$0 { renamingItem = nil } }
            )) {
                TextField("New Name", text: $updatedNameBuffer)
                Button("Save") {
                    if let item = renamingItem, !updatedNameBuffer.trimmingCharacters(in: .whitespaces).isEmpty {
                        let newName = updatedNameBuffer.trimmingCharacters(in: .whitespaces)
                        Task {
                            if item.isFolder {
                                await manager.renameFolder(id: item.id, newName: newName)
                            } else {
                                await manager.renameFile(id: item.id, newName: newName)
                            }
                            renamingItem = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) { renamingItem = nil }
            }
            .quickLookPreview($previewFileLocation)
            .overlay { loadingShieldOverlay }
            .alert("IronVault Notification", isPresented: Binding(
                get: { manager.activeError != nil },
                set: { if !$0 { manager.activeError = nil } }
            )) {
                Button("Dismiss", role: .cancel) { manager.activeError = nil }
            } message: {
                Text(manager.activeError ?? "An unexpected exception occurred.")
            }
        }
    }

    // MARK: - Breadcrumb Header with Extension Notification Badge

    private var customPathHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    currentFolderId = nil
                    navigationStackPath = [(nil, "Vault")]
                    manager.lockVault()
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Circle())
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(navigationStackPath.enumerated()), id: \.offset) { index, segment in
                            let isCurrent = index == navigationStackPath.count - 1
                            Button {
                                jumpToPathIndex(index)
                            } label: {
                                HStack(spacing: 4) {
                                    if index == 0 {
                                        Image(systemName: "lock.shield.fill").font(.caption2)
                                    }
                                    Text(segment.name)
                                        .font(.system(size: 14, weight: isCurrent ? .bold : .medium))
                                }
                                .foregroundStyle(isCurrent ? Color.primary : Color.accentColor)
                            }
                            .disabled(isCurrent)

                            if index < navigationStackPath.count - 1 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Spacer()

                // Shared Extension Spool Action (if pending items arrived)
                if manager.pendingSharedImportsCount > 0 {
                    Button {
                        Task { await manager.drainSharedExtensionSpool() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down.fill")
                            Text("\(manager.pendingSharedImportsCount)")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.blue)
                        .clipShape(Capsule())
                    }
                }

                Menu {
                    Picker("Sort By", selection: $sortOption) {
                        ForEach(VaultSortOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    Toggle(isOn: $sortAscending) {
                        Label("Ascending", systemImage: sortAscending ? "arrow.up" : "arrow.down")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(Circle())
                }

                Menu {
                    Section("Actions") {
                        Button { isCreatingFolder = true } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        Button { isDocumentPickerOpen = true } label: {
                            Label("Import Files", systemImage: "doc.badge.plus")
                        }
                    }
                    Section("Maintenance & Optimization") {
                        Button {
                            Task { await manager.vacuumAndCompactContainer() }
                        } label: {
                            Label("Vacuum & Compact Vault", systemImage: "arrow.3.trianglepath")
                        }
                    }
                    Section("Container") {
                        Button { isShowingVaultInfo = true } label: {
                            Label("Container Details", systemImage: "info.circle")
                        }
                        Button { isShowingRekeySheet = true } label: {
                            Label("Change Password", systemImage: "key.fill")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(8)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: - Scalable Indexed List View

    private var activeIndexedList: some View {
        let isSearching = !searchFilter.trimmingCharacters(in: .whitespaces).isEmpty

        var displayedFolders: [VaultFolder] = {
            if isSearching {
                return manager.metadata.folders.filter { $0.name.localizedCaseInsensitiveContains(searchFilter) }
            } else {
                return manager.subfoldersByParent[currentFolderId] ?? []
            }
        }()

        var displayedFiles: [EncryptedFileHeader] = {
            if isSearching {
                return manager.metadata.fileHeaders.filter { $0.file_name.localizedCaseInsensitiveContains(searchFilter) }
            } else {
                return manager.filesByFolder[currentFolderId] ?? []
            }
        }()

        displayedFolders.sort {
            switch sortOption {
            case .name: return sortAscending ? $0.name < $1.name : $0.name > $1.name
            case .size: return true
            case .date: return sortAscending ? $0.created_at < $1.created_at : $0.created_at > $1.created_at
            }
        }

        displayedFiles.sort {
            switch sortOption {
            case .name: return sortAscending ? $0.file_name < $1.file_name : $0.file_name > $1.file_name
            case .size: return sortAscending ? $0.file_size_bytes < $1.file_size_bytes : $0.file_size_bytes > $1.file_size_bytes
            case .date: return sortAscending ? $0.created_at < $1.created_at : $0.created_at > $1.created_at
            }
        }

        return List {
            if !displayedFolders.isEmpty {
                Section(header: Text("Folders (\(displayedFolders.count))").font(.caption.weight(.semibold))) {
                    ForEach(displayedFolders) { folder in
                        HStack(spacing: 12) {
                            Image(systemName: "folder.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name).font(.body.weight(.medium))
                                Text(folder.created_at.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            currentFolderId = folder.id
                            navigationStackPath.append((folder.id, folder.name))
                            searchFilter = ""
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await manager.deleteFolder(id: folder.id) }
                            } label: { Label("Delete", systemImage: "trash") }

                            Button {
                                movingItem = (folder.id, folder.name, true)
                            } label: { Label("Move", systemImage: "folder.badge.gearshape") }.tint(.indigo)

                            Button {
                                updatedNameBuffer = folder.name
                                renamingItem = (folder.id, folder.name, true)
                            } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
                        }
                    }
                }
            }

            Section(header: Text("Files (\(displayedFiles.count))").font(.caption.weight(.semibold))) {
                if displayedFiles.isEmpty && displayedFolders.isEmpty {
                    ContentUnavailableView(
                        isSearching ? "No Matches" : "Empty Directory",
                        systemImage: isSearching ? "magnifyingglass" : "tray",
                        description: Text(isSearching ? "No items matching '\(searchFilter)'" : "Add files or folders using the '+' menu.")
                    )
                } else {
                    ForEach(displayedFiles) { file in
                        fileRow(file)
                            .contentShape(Rectangle())
                            .onTapGesture { exportAndPreview(file: file) }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await manager.deleteFile(id: file.id) }
                                } label: { Label("Delete", systemImage: "trash") }

                                Button { exportAndShare(file: file) } label: {
                                    Label("Export", systemImage: "square.and.arrow.up")
                                }.tint(.blue)

                                Button {
                                    detailedFileItem = file
                                } label: { Label("SHA-256", systemImage: "checkmark.shield") }.tint(.gray)

                                Button {
                                    movingItem = (file.id, file.file_name, false)
                                } label: { Label("Move", systemImage: "arrow.right.doc.on.clipboard") }.tint(.indigo)

                                Button {
                                    updatedNameBuffer = file.file_name
                                    renamingItem = (file.id, file.file_name, false)
                                } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchFilter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter items")
    }

    private func fileRow(_ file: EncryptedFileHeader) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemGlyph(for: file.file_name))
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(file.file_name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.file_size_bytes), countStyle: .file))
                    Text("•")
                    Text(file.created_at.formatted(date: .abbreviated, time: .shortened))
                    if !file.sha256_checksum.isEmpty {
                        Text("•")
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - SHA-256 Inspector Modal

    private func fileDetailsModal(file: EncryptedFileHeader) -> some View {
        NavigationStack {
            List {
                Section("File Info") {
                    LabeledContent("Name", value: file.file_name)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(file.file_size_bytes), countStyle: .file))
                    LabeledContent("Created", value: file.created_at.formatted(date: .abbreviated, time: .shortened))
                }

                Section("Cryptographic Integrity Checksum") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SHA-256 HASH")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(file.sha256_checksum.isEmpty ? "None" : file.sha256_checksum)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("File Integrity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { detailedFileItem = nil }
                }
            }
        }
    }

    // MARK: - Modals & Helpers

    private func moveItemSheet(item: (id: UUID, name: String, isFolder: Bool)) -> some View {
        NavigationStack {
            List {
                Section("Destination Directory") {
                    Button {
                        Task {
                            if item.isFolder {
                                await manager.moveFolder(id: item.id, toFolderId: nil)
                            } else {
                                await manager.moveFile(id: item.id, toFolderId: nil)
                            }
                            movingItem = nil
                        }
                    } label: {
                        HStack {
                            Image(systemName: "lock.shield.fill").foregroundStyle(Color.accentColor)
                            Text("Root Directory").fontWeight(.medium)
                            Spacer()
                        }
                    }

                    ForEach(manager.metadata.folders.filter { $0.id != item.id }) { folder in
                        Button {
                            Task {
                                if item.isFolder {
                                    await manager.moveFolder(id: item.id, toFolderId: folder.id)
                                } else {
                                    await manager.moveFile(id: item.id, toFolderId: folder.id)
                                }
                                movingItem = nil
                            }
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.blue)
                                Text(folder.name)
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move '\(item.name)'")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { movingItem = nil }
                }
            }
        }
    }

    private var vaultInfoSheet: some View {
        NavigationStack {
            List {
                Section("Container Summary") {
                    LabeledContent("Files Indexed", value: "\(manager.metadata.fileHeaders.count)")
                    LabeledContent("Folders", value: "\(manager.metadata.folders.count)")
                    let totalBytes = manager.metadata.fileHeaders.reduce(0) { $0 + $1.file_size_bytes }
                    LabeledContent("Uncompressed Volume", value: ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))
                    if let url = manager.activeVaultURL {
                        LabeledContent("Archive File", value: url.lastPathComponent)
                    }
                }

                Section("Cryptographic Parameters") {
                    LabeledContent("Encryption Algorithm", value: "AES-256-GCM")
                    LabeledContent("Integrity Verification", value: "Per-File SHA-256")
                    LabeledContent("Key Derivation", value: "Argon2id v1.3 (64MB)")
                    LabeledContent("Format", value: "Virtual Chunk Container")
                }
            }
            .navigationTitle("Vault Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isShowingVaultInfo = false }
                }
            }
        }
    }

    private var rekeyModalSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("Change Master Password").font(.headline)
                    Text("The container index and stored file blocks will be re-encrypted using a new random salt and key.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.top, 12)

                SecureField("New Password", text: $newRekeyPasswordBuffer)
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    guard !newRekeyPasswordBuffer.isEmpty else { return }
                    let pwd = newRekeyPasswordBuffer
                    isShowingRekeySheet = false
                    newRekeyPasswordBuffer = ""
                    Task { await manager.changeMasterPassword(newPassword: pwd) }
                } label: {
                    Text("Rekey Container")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(newRekeyPasswordBuffer.isEmpty)

                Spacer()
            }
            .padding(.horizontal, 24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isShowingRekeySheet = false
                        newRekeyPasswordBuffer = ""
                    }
                }
            }
        }
    }

    private var passwordModalSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 6) {
                    Text(isCreatingVault ? "Set Master Password" : "Enter Master Password").font(.headline)
                    Text("Argon2id derivation uses 64 MB RAM.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 8)

                SecureField("Master Password", text: $passwordBuffer)
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if manager.isBiometricsAvailable {
                    Toggle("Enable Face ID / Touch ID", isOn: $rememberBiometrics)
                        .font(.footnote)
                        .padding(.horizontal, 4)
                }

                Button("Authenticate") {
                    guard !passwordBuffer.isEmpty, let target = pendingTargetURL else { return }
                    let pwd = passwordBuffer
                    let creating = isCreatingVault
                    let bio = rememberBiometrics
                    isPresentingUnlockSheet = false
                    passwordBuffer = ""
                    rememberBiometrics = false
                    Task {
                        if creating {
                            await manager.createNewVault(at: target, password: pwd, saveToBiometrics: bio)
                        } else {
                            await manager.unlockVault(at: target, password: pwd, saveToBiometrics: bio)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .disabled(passwordBuffer.isEmpty)

                Spacer()
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresentingUnlockSheet = false
                        passwordBuffer = ""
                        pendingTargetURL = nil
                    }
                }
            }
        }
    }

    private var emptyStateLanding: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 100, height: 100)
                Image(systemName: "lock.shield.fill").font(.system(size: 48)).foregroundStyle(Color.accentColor)
            }

            VStack(spacing: 6) {
                Text("Enterprise Vault").font(.title2.weight(.bold))
                Text("Hardware-accelerated AES-256-GCM container.").font(.subheadline).foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Button {
                    isVaultPickerOpen = true
                } label: {
                    Label("Open Vault File", systemImage: "folder.fill")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    isVaultSaverOpen = true
                } label: {
                    Label("Create New Vault", systemImage: "plus.square.fill")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 28)
            Spacer()
        }
    }

    private var loadingShieldOverlay: some View {
        Group {
            if manager.isBusy {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(manager.statusDescription).font(.subheadline.weight(.medium))
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    // MARK: - Handlers & Navigation

    private func exportAndPreview(file: EncryptedFileHeader) {
        Task {
            do {
                let decrypted = try manager.readAndDecryptPayload(for: file)
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.file_name)
                try decrypted.write(to: tempURL, options: .atomic)
                self.previewFileLocation = tempURL
            } catch {
                manager.activeError = "Decryption error: \(error.localizedDescription)"
            }
        }
    }

    private func exportAndShare(file: EncryptedFileHeader) {
        Task {
            do {
                let decrypted = try manager.readAndDecryptPayload(for: file)
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.file_name)
                try decrypted.write(to: tempURL, options: .atomic)
                self.shareSheetItem = ShareItem(url: tempURL)
            } catch {
                manager.activeError = "Export error: \(error.localizedDescription)"
            }
        }
    }

    private func handleFileImports(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result {
            let activeFolder = currentFolderId
            Task {
                for url in urls {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    await manager.importFile(name: url.lastPathComponent, sourceURL: url, folderId: activeFolder)
                }
            }
        }
    }

    private func jumpToPathIndex(_ targetIndex: Int) {
        guard targetIndex < navigationStackPath.count else { return }
        navigationStackPath = Array(navigationStackPath.prefix(targetIndex + 1))
        currentFolderId = navigationStackPath.last?.id
        searchFilter = ""
    }

    private func handleVaultSelection(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result, let selected = urls.first {
            pendingTargetURL = selected
            isCreatingVault = false

            // Check if biometric credentials exist for this specific container
            if manager.isBiometricsAvailable, let savedPwd = manager.readPasswordFromKeychain(for: selected) {
                Task {
                    // Try Face ID / Touch ID first
                    let success = await manager.evaluateBiometricPrompt()
                    if success {
                        await manager.unlockVault(at: selected, password: savedPwd)
                    } else {
                        // If user canceled or Face ID failed, present password sheet as fallback
                        await MainActor.run {
                            self.isPresentingUnlockSheet = true
                        }
                    }
                }
            } else {
                // Give system file-picker sheet time to fully dismiss before triggering unlock sheet
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.isPresentingUnlockSheet = true
                }
            }
        }
    }

    private func systemGlyph(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif": return "photo.fill"
        case "pdf": return "doc.text.fill"
        case "mp4", "mov", "mkv": return "film.fill"
        case "mp3", "m4a", "wav", "flac": return "waveform"
        case "zip", "tar", "gz", "7z": return "archivebox.fill"
        case "swift", "rs", "py", "js", "html": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }
}

struct MoveItemWrapper: Identifiable {
    let id = UUID()
    let item: (id: UUID, name: String, isFolder: Bool)
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct BlankVaultDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    init() {}
    init(configuration: ReadConfiguration) throws {}
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}
