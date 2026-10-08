import SwiftUI
import QuickLook
import UniformTypeIdentifiers

// MARK: - Unified Row Model

private struct UnifiedVaultItem: Identifiable {
    enum ItemType {
        case folder(VaultFolder)
        case file(EncryptedFileHeader)
    }

    let id: UUID
    let name: String
    let date: Date
    let type: ItemType

    var isFolder: Bool {
        if case .folder = type { return true }
        return false
    }

    var fileHeader: EncryptedFileHeader? {
        if case .file(let header) = type { return header }
        return nil
    }

    var folderModel: VaultFolder? {
        if case .folder(let model) = type { return model }
        return nil
    }

    static func from(folder: VaultFolder) -> UnifiedVaultItem {
        UnifiedVaultItem(id: folder.id, name: folder.name, date: folder.created_at, type: .folder(folder))
    }

    static func from(file: EncryptedFileHeader) -> UnifiedVaultItem {
        UnifiedVaultItem(id: file.id, name: file.file_name, date: file.created_at, type: .file(file))
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var manager = VaultManager()

    // Navigation Hierarchy
    @State private var currentFolderId: UUID? = nil
    @State private var navigationStackPath: [(id: UUID?, name: String)] = [(nil, "Vault")]

    // Search
    @State private var searchFilter = ""

    // System File Operations
    @State private var isVaultPickerOpen = false
    @State private var isVaultSaverOpen = false
    @State private var isDocumentPickerOpen = false
    @State private var isFolderPickerOpen = false
    @State private var pendingTargetURL: URL? = nil

    // Security & Authentication Modals
    @State private var isPresentingUnlockSheet = false
    @State private var isCreatingVault = false
    @State private var passwordBuffer = ""
    @State private var rememberBiometrics = false
    @State private var isShowingVaultInfo = false
    @State private var isShowingRekeySheet = false
    @State private var newRekeyPasswordBuffer = ""

    // Item Management Modals
    @State private var isCreatingFolder = false
    @State private var newFolderNameBuffer = ""
    @State private var renamingItem: (id: UUID, name: String, isFolder: Bool)? = nil
    @State private var updatedNameBuffer = ""
    @State private var movingItem: (id: UUID, name: String, isFolder: Bool)? = nil
    @State private var detailedFileItem: EncryptedFileHeader? = nil

    // QuickLook State
    @State private var previewFileLocation: URL? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                if manager.isUnlocked {
                    mainVaultContent
                } else {
                    initialVaultsList
                }
            }
            .navigationTitle(manager.isUnlocked ? (navigationStackPath.last?.name ?? "Vault") : "IronVault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if manager.isUnlocked {
                    // Leading Back / Close Button
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                currentFolderId = nil
                                navigationStackPath = [(nil, "Vault")]
                                searchFilter = ""
                                manager.lockVault()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Vaults")
                                    .font(.system(size: 16))
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                    }

                    // Trailing Action Menu for Opened Vault
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Section("Add Content") {
                                Button {
                                    isCreatingFolder = true
                                } label: {
                                    Label("New Folder", systemImage: "folder.badge.plus")
                                }
                                Button {
                                    isFolderPickerOpen = true
                                } label: {
                                    Label("Import Folder...", systemImage: "folder.badge.gearshape")
                                }
                                Button {
                                    isDocumentPickerOpen = true
                                } label: {
                                    Label("Import Files...", systemImage: "doc.badge.plus")
                                }
                            }

                            Section("Security & Storage") {
                                Button {
                                    isShowingVaultInfo = true
                                } label: {
                                    Label("Vault Properties", systemImage: "info.circle")
                                }
                                Button {
                                    isShowingRekeySheet = true
                                } label: {
                                    Label("Change Password", systemImage: "key.fill")
                                }
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                    }
                } else {
                    // Trailing Action Menu for Vault Selection Screen
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                isVaultSaverOpen = true
                            } label: {
                                Label("Create New Vault", systemImage: "plus.square.fill")
                            }

                            Button {
                                isVaultPickerOpen = true
                            } label: {
                                Label("Open Vault from Files...", systemImage: "folder.badge.gearshape")
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
            // System Importers / Exporters
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
            .fileImporter(
                isPresented: $isFolderPickerOpen,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderImports(result)
            }
            // Modals
            .sheet(isPresented: $isPresentingUnlockSheet) {
                authenticationModalSheet
                    .presentationDetents([.fraction(0.40)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingRekeySheet) {
                rekeyModalSheet
                    .presentationDetents([.fraction(0.35)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingVaultInfo) {
                vaultInfoModalSheet
                    .presentationDetents([.fraction(0.48)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $detailedFileItem) { file in
                fileDetailsModalSheet(file: file)
                    .presentationDetents([.fraction(0.40)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: Binding(
                get: { movingItem != nil ? MoveItemWrapper(item: movingItem!) : nil },
                set: { movingItem = $0?.item }
            )) { wrapper in
                moveItemModalSheet(item: wrapper.item)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            // Creation & Rename Alerts
            .alert("New Folder", isPresented: $isCreatingFolder) {
                TextField("Folder Name", text: $newFolderNameBuffer)
                    .multilineTextAlignment(.center)
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
                    .multilineTextAlignment(.center)
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
            .alert("Vault Notification", isPresented: Binding(
                get: { manager.activeError != nil },
                set: { if !$0 { manager.activeError = nil } }
            )) {
                Button("Dismiss", role: .cancel) { manager.activeError = nil }
            } message: {
                Text(manager.activeError ?? "An unexpected exception occurred.")
            }
        }
    }

    // MARK: - Initial Vaults List (Entire Screen Plain List)

    private var initialVaultsList: some View {
        Group {
            if manager.availableVaults.isEmpty {
                VStack {
                    Spacer()
                    ContentUnavailableView {
                        Label("No Saved Vaults", systemImage: "lock.shield")
                    } description: {
                        Text("Tap the plus button (+) in the top right to create a new vault or open an existing one from Files.")
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
            } else {
                List {
                    ForEach(Array(manager.availableVaults.enumerated()), id: \.element) { index, vaultURL in
                        Button {
                            pendingTargetURL = vaultURL
                            isCreatingVault = false
                            authenticateAndUnlock(vaultURL)
                        } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.accentColor.opacity(0.12))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: "lock.shield.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(vaultURL.deletingPathExtension().lastPathComponent)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Color.primary)

                                    if let attrs = try? FileManager.default.attributesOfItem(atPath: vaultURL.path),
                                       let size = attrs[.size] as? Int64 {
                                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text(vaultURL.lastPathComponent)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                manager.removeVaultFromList(at: index)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    manager.refreshAvailableVaults()
                }
            }
        }
    }

    // MARK: - Main Content Layout

    private var mainVaultContent: some View {
        VStack(spacing: 0) {
            if navigationStackPath.count > 1 {
                breadcrumbPillBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            activeUnifiedList
        }
        .searchable(
            text: $searchFilter,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search files and folders"
        )
    }

    // MARK: - Breadcrumb Navigation Strip

    private var breadcrumbPillBar: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(navigationStackPath.enumerated()), id: \.offset) { index, segment in
                            let isCurrent = index == navigationStackPath.count - 1

                            Button {
                                withAnimation(.snappy(duration: 0.25)) {
                                    jumpToPathIndex(index)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    if index == 0 {
                                        Image(systemName: "lock.shield.fill")
                                            .font(.system(size: 11, weight: .bold))
                                    }
                                    Text(segment.name)
                                        .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isCurrent ? Color.accentColor.opacity(0.15) : Color(uiColor: .tertiarySystemFill))
                                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                                .clipShape(Capsule())
                            }
                            .id(index)
                            .disabled(isCurrent)

                            if index < navigationStackPath.count - 1 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    proxy.scrollTo(navigationStackPath.count - 1, anchor: .trailing)
                }
                .onChange(of: navigationStackPath.count) { newCount in
                    withAnimation {
                        proxy.scrollTo(newCount - 1, anchor: .trailing)
                    }
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - Unified Single List (Entire Screen Plain List)

    private var activeUnifiedList: some View {
        let isSearching = !searchFilter.trimmingCharacters(in: .whitespaces).isEmpty

        let matchingFolders = isSearching
            ? manager.metadata.folders.filter { $0.name.localizedCaseInsensitiveContains(searchFilter) }
            : (manager.subfoldersByParent[currentFolderId] ?? [])

        let matchingFiles = isSearching
            ? manager.metadata.fileHeaders.filter { $0.file_name.localizedCaseInsensitiveContains(searchFilter) }
            : (manager.filesByFolder[currentFolderId] ?? [])

        var items: [UnifiedVaultItem] = []
        items.append(contentsOf: matchingFolders.map { UnifiedVaultItem.from(folder: $0) })
        items.append(contentsOf: matchingFiles.map { UnifiedVaultItem.from(file: $0) })

        return Group {
            if items.isEmpty {
                emptyDirectoryStateView(isSearching: isSearching)
            } else {
                List {
                    ForEach(items) { item in
                        switch item.type {
                        case .folder(let folder):
                            folderRowView(folder)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        currentFolderId = folder.id
                                        navigationStackPath.append((folder.id, folder.name))
                                        searchFilter = ""
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .contextMenu {
                                    itemContextMenu(name: folder.name, id: folder.id, isFolder: true, fileHeader: nil)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    itemTrailingSwipeActions(name: folder.name, id: folder.id, isFolder: true, fileHeader: nil)
                                }

                        case .file(let file):
                            fileRowView(file)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    exportAndPreview(file: file)
                                }
                                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                                .contextMenu {
                                    itemContextMenu(name: file.file_name, id: file.id, isFolder: false, fileHeader: file)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    itemTrailingSwipeActions(name: file.file_name, id: file.id, isFolder: false, fileHeader: file)
                                }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Centered Empty Directory Placeholder

    private func emptyDirectoryStateView(isSearching: Bool) -> some View {
        VStack {
            Spacer()
            ContentUnavailableView {
                Label(
                    isSearching ? "No Matching Items" : "Folder Is Empty",
                    systemImage: isSearching ? "magnifyingglass" : "tray"
                )
            } description: {
                Text(isSearching
                     ? "Check spelling or search another keyword."
                     : "Use the plus icon (+) in the toolbar to import files or create folders.")
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Row Views

    private func folderRowView(_ folder: VaultFolder) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: "folder.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                Text(folder.created_at.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func fileRowView(_ file: EncryptedFileHeader) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 40, height: 40)
                Image(systemName: systemGlyph(for: file.file_name))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(file.file_name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.file_size_bytes), countStyle: .file))
                        .monospacedDigit()
                    Text("•")
                    Text(file.created_at.formatted(date: .abbreviated, time: .shortened))
                    if !file.sha256_checksum.isEmpty {
                        Text("•")
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Row Actions (Context Menu & Swipes)

    @ViewBuilder
    private func itemContextMenu(name: String, id: UUID, isFolder: Bool, fileHeader: EncryptedFileHeader?) -> some View {
        Button {
            updatedNameBuffer = name
            renamingItem = (id, name, isFolder)
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            movingItem = (id, name, isFolder)
        } label: {
            Label("Move...", systemImage: "folder.badge.gearshape")
        }

        if let file = fileHeader {
            Button {
                detailedFileItem = file
            } label: {
                Label("Inspect Integrity (SHA-256)", systemImage: "checkmark.shield")
            }
        }

        Divider()

        Button(role: .destructive) {
            Task {
                if isFolder {
                    await manager.deleteFolder(id: id)
                } else {
                    await manager.deleteFile(id: id)
                }
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func itemTrailingSwipeActions(name: String, id: UUID, isFolder: Bool, fileHeader: EncryptedFileHeader?) -> some View {
        Button(role: .destructive) {
            Task {
                if isFolder {
                    await manager.deleteFolder(id: id)
                } else {
                    await manager.deleteFile(id: id)
                }
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }

        Button {
            movingItem = (id, name, isFolder)
        } label: {
            Label("Move", systemImage: "arrow.right.doc.on.clipboard")
        }
        .tint(.indigo)

        Button {
            updatedNameBuffer = name
            renamingItem = (id, name, isFolder)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .tint(.orange)
    }

    // MARK: - Sheet Modals

    private var authenticationModalSheet: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Enter Master Password", text: $passwordBuffer)
                        .textContentType(.password)
                        .multilineTextAlignment(.center)
                } header: {
                    Text(isCreatingVault ? "New Master Password" : "Authentication")
                } footer: {
                    Text("Key derivation uses Argon2id with 64 MB memory clamping.")
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                if manager.isBiometricsAvailable {
                    Section {
                        Toggle("Save Password to Face ID / Touch ID", isOn: $rememberBiometrics)
                    }
                }

                Section {
                    Button {
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
                    } label: {
                        Text(isCreatingVault ? "Create Container" : "Unlock Vault")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                    }
                    .disabled(passwordBuffer.isEmpty)
                }
            }
            .navigationTitle(isCreatingVault ? "New Vault" : "Unlock")
            .navigationBarTitleDisplayMode(.inline)
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

    private var vaultInfoModalSheet: some View {
        NavigationStack {
            List {
                Section("Container Metrics") {
                    let totalBytes = manager.metadata.fileHeaders.reduce(0) { $0 + $1.file_size_bytes }
                    LabeledContent("Indexed Files", value: "\(manager.metadata.fileHeaders.count)")
                    LabeledContent("Total Folders", value: "\(manager.metadata.folders.count)")
                    LabeledContent("Total Uncompressed Volume", value: ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))
                    if let url = manager.activeVaultURL {
                        LabeledContent("Archive Path", value: url.lastPathComponent)
                    }
                }

                Section("Cryptographic Parameters") {
                    LabeledContent("Block Cipher", value: "AES-256-GCM")
                    LabeledContent("Integrity Verification", value: "Per-File SHA-256")
                    LabeledContent("KDF", value: "Argon2id v1.3")
                    LabeledContent("Memory Clamping", value: "64 MB RAM")
                    LabeledContent("Architecture", value: "Virtual Chunk Container")
                }
            }
            .navigationTitle("Vault Properties")
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
            Form {
                Section {
                    SecureField("New Master Password", text: $newRekeyPasswordBuffer)
                        .textContentType(.newPassword)
                        .multilineTextAlignment(.center)
                } footer: {
                    Text("All stored file blocks will be atomically re-encrypted using a new Argon2id salt and key.")
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                Section {
                    Button("Rekey Container") {
                        guard !newRekeyPasswordBuffer.isEmpty else { return }
                        let pwd = newRekeyPasswordBuffer
                        isShowingRekeySheet = false
                        newRekeyPasswordBuffer = ""
                        Task { await manager.changeMasterPassword(newPassword: pwd) }
                    }
                    .disabled(newRekeyPasswordBuffer.isEmpty)
                }
            }
            .navigationTitle("Change Password")
            .navigationBarTitleDisplayMode(.inline)
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

    private func fileDetailsModalSheet(file: EncryptedFileHeader) -> some View {
        NavigationStack {
            List {
                Section("File Attributes") {
                    LabeledContent("File Name", value: file.file_name)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: Int64(file.file_size_bytes), countStyle: .file))
                    LabeledContent("Added", value: file.created_at.formatted(date: .abbreviated, time: .shortened))
                }

                Section("Cryptographic Hash") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SHA-256 CHECKSUM")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(file.sha256_checksum.isEmpty ? "No checksum available" : file.sha256_checksum)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
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

    private func moveItemModalSheet(item: (id: UUID, name: String, isFolder: Bool)) -> some View {
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
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(Color.accentColor)
                            Text("Root Directory")
                                .fontWeight(.medium)
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
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.blue)
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

    private var loadingShieldOverlay: some View {
        Group {
            if manager.isBusy {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()

                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text(manager.statusDescription)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    // MARK: - Handlers

    private func authenticateAndUnlock(_ vaultURL: URL) {
        if manager.isBiometricsAvailable, let savedPwd = manager.readPasswordFromKeychain(for: vaultURL) {
            Task {
                let success = await manager.evaluateBiometricPrompt()
                if success {
                    await manager.unlockVault(at: vaultURL, password: savedPwd)
                } else {
                    await MainActor.run {
                        self.passwordBuffer = ""
                        self.isPresentingUnlockSheet = true
                    }
                }
            }
        } else {
            self.passwordBuffer = ""
            self.isPresentingUnlockSheet = true
        }
    }

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

    private func handleFolderImports(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result, let selectedFolder = urls.first {
            let activeFolder = currentFolderId
            Task {
                await manager.importFolderRecursively(from: selectedFolder, parentFolderId: activeFolder)
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
            authenticateAndUnlock(selected)
        }
    }

    private func systemGlyph(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp": return "photo.fill"
        case "pdf": return "doc.text.fill"
        case "mp4", "mov", "mkv", "avi": return "film.fill"
        case "mp3", "m4a", "wav", "flac", "aac": return "waveform"
        case "zip", "tar", "gz", "7z", "rar": return "archivebox.fill"
        case "swift", "rs", "py", "js", "ts", "html", "c", "cpp": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.fill"
        }
    }
}

// MARK: - Supporting Helpers

struct MoveItemWrapper: Identifiable {
    let id = UUID()
    let item: (id: UUID, name: String, isFolder: Bool)
}

struct BlankVaultDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    init() {}
    init(configuration: ReadConfiguration) throws {}
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}
