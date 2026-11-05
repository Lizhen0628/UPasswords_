import SwiftUI
import UPasswordsCore
import UPasswordsPersistence
import UPasswordsNetworking

/// Detail pane, grouped-card style: centered header (large icon with a
/// category badge at its bottom-right + bold title below), one rounded card of
/// label-left / value-right rows (fields, labels, modified/created dates,
/// notes), standalone security warning cards underneath, and the bottom action
    /// bar (草稿保存 / 用于自动填充 / 收藏 / share).
struct CardDetailView: View {
    @EnvironmentObject var ctx: AppContext
    @State private var editingCard: Card?
    @State private var editingBaseline: Card?
    @State private var previewAttachment: Attachment?
    @State private var pendingAttachmentPreviewID: UUID?
    @State private var notesEditing = false
    @State private var valueEditorFrame: CGRect = .zero
    @FocusState private var focusedValueFieldID: UUID?

    var body: some View {
        Group {
            if let card = displayCard {
                detail(card)
            } else {
                // 空状态:邮件式居中灰字「未选择项目」,仅底部操作栏可见(按钮置灰)。
                ZStack {
                    Color.appBackground
                    Text(L10n.t("no_selection_text"))
                        .font(.system(size: 22))
                        .foregroundStyle(Color.white.opacity(0.28))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(displayCard)
        }
        .onAppear(perform: resetEditingCard)
        .onChange(of: ctx.selectedCardId) { oldCardID, newCardID in
            if hasUnsavedChanges { saveEdits(selectCard: false) }
            if let oldCardID, oldCardID != newCardID {
                ctx.releaseCachedAttachments(cardID: oldCardID)
            }
            resetEditingCard()
        }
        .onChange(of: currentCard?.images) { _, images in
            mergeDownloadedAttachments(images: images, files: currentCard?.files)
        }
        .onChange(of: currentCard?.files) { _, files in
            mergeDownloadedAttachments(images: currentCard?.images, files: files)
        }
        .sheet(item: $previewAttachment) { attachment in
            AttachmentImagePreview(attachment: attachment) {
                saveAttachment(attachment)
            }
        }
        .task(id: currentCard?.id) {
            guard let cardID = currentCard?.id else { return }
            ctx.loadCachedAttachments(cardID: cardID)
            ctx.prioritizeAttachmentDownload(cardID: cardID)
        }
        .onDisappear {
            if let cardID = ctx.selectedCardId {
                ctx.releaseCachedAttachments(cardID: cardID)
            }
        }
        .onChange(of: currentCard.flatMap { card in
            (card.images + card.files).first { $0.id == pendingAttachmentPreviewID }?.hasContent
        }) { _, hasContent in
            guard hasContent == true,
                  let pendingAttachmentPreviewID,
                  let attachment = currentCard.flatMap({ card in
                      (card.images + card.files).first { $0.id == pendingAttachmentPreviewID }
                  }), attachment.data != nil else { return }
            self.pendingAttachmentPreviewID = nil
            previewAttachment = attachment
        }
    }

    private var currentCard: Card? {
        guard let id = ctx.selectedCardId else { return nil }
        return ctx.database.card(id: id)
    }

    private var displayCard: Card? {
        editingCard ?? currentCard
    }

    private var hasUnsavedChanges: Bool {
        guard let editingCard, let editingBaseline else { return false }
        return editingCard != editingBaseline
    }

    private func resetEditingCard() {
        editingCard = currentCard
        editingBaseline = currentCard
        notesEditing = false
    }

    private func updateDraft(_ update: (inout Card) -> Void) {
        guard var editingCard else { return }
        update(&editingCard)
        self.editingCard = editingCard
    }

    private func toggleFavorite(_ cardID: UUID) {
        ctx.toggleFavorite(cardID)
        guard let favorite = ctx.database.card(id: cardID)?.favorite else { return }

        if var editingCard, editingCard.id == cardID {
            editingCard.favorite = favorite
            self.editingCard = editingCard
        }
        if var editingBaseline, editingBaseline.id == cardID {
            editingBaseline.favorite = favorite
            self.editingBaseline = editingBaseline
        }
    }

    private func mergeDownloadedAttachments(images: [Attachment]?, files: [Attachment]?) {
        guard var editingCard, let currentCard, editingCard.id == currentCard.id else { return }
        if let images {
            let latestByID = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
            editingCard.images = editingCard.images.map { latestByID[$0.id] ?? $0 }
        }
        if let files {
            let latestByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
            editingCard.files = editingCard.files.map { latestByID[$0.id] ?? $0 }
        }
        self.editingCard = editingCard
        if var editingBaseline, editingBaseline.id == currentCard.id {
            if let images {
                editingBaseline.images = editingBaseline.images.map { attachment in
                    images.first { $0.id == attachment.id } ?? attachment
                }
            }
            if let files {
                editingBaseline.files = editingBaseline.files.map { attachment in
                    files.first { $0.id == attachment.id } ?? attachment
                }
            }
            self.editingBaseline = editingBaseline
        }
    }

    private func fieldBinding(for fieldID: UUID, preferredIndex: Int?) -> Binding<Field> {
        Binding(
            get: {
                guard let fields = editingCard?.fields else { return Field(name: "") }
                if let preferredIndex,
                   fields.indices.contains(preferredIndex), fields[preferredIndex].id == fieldID {
                    return fields[preferredIndex]
                }
                return fields.first { $0.id == fieldID } ?? Field(name: "")
            },
            set: { updatedField in
                updateDraft { card in
                    let index: Int
                    if let preferredIndex,
                       card.fields.indices.contains(preferredIndex),
                       card.fields[preferredIndex].id == fieldID {
                        index = preferredIndex
                    } else {
                        guard let matchedIndex = card.fields.firstIndex(where: { $0.id == fieldID }) else {
                            return
                        }
                        index = matchedIndex
                    }
                    card.fields[index] = updatedField
                }
            }
        )
    }

    private func moveField(_ field: Field, offset: Int) {
        guard let editingCard,
              let index = editingCard.fields.firstIndex(where: { $0.id == field.id }) else { return }
        let destination = index + offset
        guard editingCard.fields.indices.contains(destination) else { return }
        updateDraft { $0.fields.swapAt(index, destination) }
        Log.info("ui", "detail field moved cardId=\(editingCard.id) fieldId=\(field.id) dir=\(offset)")
    }

    private func cancelEdits() {
        Log.info("ui", "detail edits cancelled cardId=\(editingCard?.id.uuidString ?? "nil")")
        resetEditingCard()
    }

    private func saveEdits(selectCard: Bool = true) {
        guard let draft = editingCard,
              let latest = ctx.database.card(id: draft.id) else {
            Log.warn("ui", "detail edits save skipped: card no longer exists")
            resetEditingCard()
            return
        }
        var saved = draft
        saved.images = draft.images.map { edited in latest.images.first { $0.id == edited.id } ?? edited }
        saved.files = draft.files.map { edited in latest.files.first { $0.id == edited.id } ?? edited }
        ctx.upsertCard(saved, selectAfterSave: selectCard)
        let persisted = ctx.database.card(id: saved.id) ?? saved
        editingCard = persisted
        editingBaseline = persisted
        notesEditing = false
        Log.info("ui", "detail edits saved cardId=\(saved.id) fields=\(saved.fields.count)")
    }

    private func detail(_ card: Card) -> some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                header(card)
                fieldsCard(card)
                if !card.isTemplate { detailActions(card) }
                warningCards(card)
                if card.hasImages { imagesSection(card) }
                if card.hasFiles { filesSection(card) }
                if card.trashed || card.archived {
                    trashActions(card)
                }
            }
            .padding(24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .coordinateSpace(name: "cardDetailContent")
        .onPreferenceChange(ValueEditorFramePreferenceKey.self) { valueEditorFrame = $0 }
        .simultaneousGesture(
            SpatialTapGesture(coordinateSpace: .named("cardDetailContent"))
                .onEnded { tap in
                    guard focusedValueFieldID != nil,
                          !valueEditorFrame.contains(tap.location) else { return }
                    focusedValueFieldID = nil
                }
        )
    }

    // MARK: Header — 居中大图标(右下角类别徽章)+ 下方加粗标题

    private func header(_ card: Card) -> some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                CardIconView(symbol: card.symbol, color: card.color, size: 84,
                             creditCardNumber: card.fields.first { $0.type == .number }?.value,
                             card: card)
                categoryBadge(card)
                    .offset(x: 4, y: 4)
            }
            .padding(.trailing, 4)
            TextField(L10n.t("title_hint"), text: Binding(
                get: { editingCard?.title ?? card.title },
                set: { title in updateDraft { $0.title = title } }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .bold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: 420)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.025)))
        }
        .frame(maxWidth: .infinity)
    }

    /// 图标右下角的小圆徽章:登录类显示人形,其余按卡片符号。
    private func categoryBadge(_ card: Card) -> some View {
        Image(systemName: badgeSymbol(card))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.appBackground)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color(nsColor: .systemGray)))
            .overlay(Circle().strokeBorder(Color.appBackground, lineWidth: 3))
    }

    private func badgeSymbol(_ card: Card) -> String {
        if card.fields.contains(where: { $0.type == .password || $0.type.isLogin }) { return "person.fill" }
        if card.symbol == "credit_card" { return "creditcard.fill" }
        return SymbolModel.shared.sfSymbol(for: card.symbol ?? "custom")
    }

    // MARK: Fields card — 单张圆角卡片内的「标签居左 / 值居右」行

    private func fieldsCard(_ card: Card) -> some View {
        let fieldIndexes = Dictionary(
            card.fields.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, latest in latest }
        )

        return LazyVStack(spacing: 0) {
            ForEach(card.fields) { field in
                FieldRowView(
                    cardID: card.id,
                    field: fieldBinding(for: field.id, preferredIndex: fieldIndexes[field.id]),
                    canMoveUp: card.fields.first?.id != field.id,
                    canMoveDown: card.fields.last?.id != field.id,
                    onMoveUp: { moveField(field, offset: -1) },
                    onMoveDown: { moveField(field, offset: 1) },
                    onDelete: { updateDraft { $0.fields.removeAll { $0.id == field.id } } },
                    onCommitEditing: { saveEdits(selectCard: false) },
                    focusedValueFieldID: $focusedValueFieldID
                )
                Divider()
            }
            labelsRow(card)
            if hasVisibleNotes(card) || notesEditing {
                Divider()
                notesRow(card)
            }
            Divider()
            dateRow(label: L10n.t("modified_date_text"), millis: card.modified)
            Divider()
            dateRow(label: L10n.t("created_date_text"), millis: card.created)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    private func labelNames(_ card: Card) -> String {
        card.labelIds.compactMap { ctx.database.label(id: $0)?.name }.joined(separator: ", ")
    }

    private func hasVisibleNotes(_ card: Card) -> Bool {
        !card.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func labelsRow(_ card: Card) -> some View {
        HStack {
            Text(L10n.t("labels_text"))
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 24)
            Menu {
                ForEach(ctx.database.labels) { label in
                    Button {
                        updateDraft { draft in
                            if draft.labelIds.contains(label.id) {
                                draft.labelIds.removeAll { $0 == label.id }
                            } else {
                                draft.labelIds.append(label.id)
                            }
                        }
                    } label: {
                        if card.labelIds.contains(label.id) {
                            Label(label.name, systemImage: "checkmark")
                        } else {
                            Text(label.name)
                        }
                    }
                }
            } label: {
                Text(labelNames(card).isEmpty ? L10n.t("no_labels_text") : labelNames(card))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.87))
                    .multilineTextAlignment(.trailing)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help(L10n.t("set_labels_button"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func dateRow(label: String, millis: TimeInterval) -> some View {
        MetaDateRowView(label: label, date: Date(timeIntervalSince1970: millis / 1_000))
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
    }

    /// 备注在详情卡片中切换为原位编辑，不再打开整卡编辑表单。
    private func notesRow(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("notes_tab"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    notesEditing.toggle()
                } label: {
                    Image(systemName: notesEditing ? "checkmark" : "square.and.pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(L10n.t(notesEditing ? "ios_done_button" : "edit_button"))
            }
            if notesEditing {
                TextEditor(text: Binding(
                    get: { editingCard?.notes ?? card.notes },
                    set: { notes in updateDraft { $0.notes = notes } }
                ))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 92, maxHeight: 220)
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.12)))
            } else if hasVisibleNotes(card) {
                Text(AttributedString(NotesMarkdown.render(card.notes)))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.87))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func addMissingFields(from spec: Templates.Spec) {
        guard let card = editingCard else { return }
        var addedCount = 0
        updateDraft { draft in
            for field in spec.fields {
                let name = L10n.db(field.nameKey)
                guard !draft.fields.contains(where: { $0.name == name }) else { continue }
                draft.fields.append(Field(name: name, type: field.type, value: "", autofill: field.autofill))
                addedCount += 1
            }
        }
        Log.info("ui", "detail add fields cardId=\(card.id) template=\(spec.titleKey) added=\(addedCount)")
    }

    private func detailActions(_ card: Card) -> some View {
        HStack(spacing: 14) {
            addFieldMenu(card)
            if !hasVisibleNotes(card) && !notesEditing {
                Button {
                    notesEditing = true
                } label: {
                    Label(L10n.t("notes_prompt"), systemImage: "square.and.pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Menu {
                Button(L10n.t("attach_image_button")) { pickAttachments(isImage: true) }
                Button(L10n.t("attach_file_button")) { pickAttachments(isImage: false) }
            } label: {
                Image(systemName: "paperclip.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help(L10n.t("attach_file_button"))
            Spacer()
        }
    }

    /// 「添加其它条目」菜单:卡片下方独立的小按钮,不挤占分组行。
    private func addFieldMenu(_ card: Card) -> some View {
        Menu {
            ForEach(FieldType.allCases) { type in
                if type.isOneTimePassword {
                    Menu(type.localizedName) {
                        Button(L10n.t("add_field_button")) {
                            appendOneTimeCodeField()
                        }
                        Button(L10n.t("qr_from_screen")) {
                            readOneTimeCodeFromScreen()
                        }
                        Button(L10n.t("qr_from_image")) {
                            readOneTimeCodeFromImage()
                        }
                    }
                } else {
                    Button(type.localizedName) {
                        updateDraft { $0.fields.append(Field(name: type.localizedName, type: type)) }
                    }
                }
            }
            Divider()
            ForEach(Templates.all) { spec in
                Button(L10n.db(spec.titleKey)) {
                    addMissingFields(from: spec)
                }
            }
        } label: {
            Label(L10n.t("add_field_button"), systemImage: "plus.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appendOneTimeCodeField(value: String = "") {
        updateDraft { card in
            card.fields.append(Field(
                name: FieldType.oneTimePassword.localizedName,
                type: .oneTimePassword,
                value: value
            ))
        }
        Log.info("ui", "detail one-time-code field added value.len=\(value.count)")
        if !value.isEmpty {
            AppToast.shared.show(L10n.t("qr_filled"))
        }
    }

    private func readOneTimeCodeFromScreen() {
        guard let cardID = editingCard?.id else { return }
        Task { @MainActor in
            let startedAt = Date()
            Log.info("ui", "otp qr screen read started cardId=\(cardID)")
            do {
                let value = try await QRCodeService.readFromScreen()
                guard editingCard?.id == cardID else { return }
                appendOneTimeCodeField(value: value)
                let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                Log.info("ui", "otp qr screen read completed cardId=\(cardID) ms=\(milliseconds)")
            } catch {
                Log.warn("ui", "otp qr screen read failed cardId=\(cardID): \(String(describing: error))")
                AppToast.shared.show(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func readOneTimeCodeFromImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let cardID = editingCard?.id else { return }
        Task { @MainActor in
            let startedAt = Date()
            Log.info("ui", "otp qr image read started cardId=\(cardID)")
            do {
                let value = try await QRCodeService.readFromImage(at: url)
                guard editingCard?.id == cardID else { return }
                appendOneTimeCodeField(value: value)
                let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                Log.info("ui", "otp qr image read completed cardId=\(cardID) ms=\(milliseconds)")
            } catch {
                Log.warn("ui", "otp qr image read failed cardId=\(cardID): \(String(describing: error))")
                AppToast.shared.show(error.localizedDescription)
            }
        }
    }

    // MARK: Security warnings — 字段卡片下方的独立警告卡片

    @ViewBuilder
    private func warningCards(_ card: Card) -> some View {
        let reusedPassword = isReusedPassword(card)
        if card.compromised || reusedPassword || card.hasWeakPasswords
            || card.isExpired || card.isExpiring {
            VStack(spacing: 10) {
                if card.compromised {
                    warningCard(icon: "exclamationmark.circle.fill", tint: .red,
                                title: L10n.t("compromised_passwords_title"),
                                message: L10n.t("compromised_password_message"))
                }
                if reusedPassword {
                    warningCard(icon: "exclamationmark.circle.fill", tint: .yellow,
                                title: L10n.t("reused_password_warning_title"),
                                message: L10n.t("reused_password_warning_body"))
                }
                if card.hasWeakPasswords {
                    warningCard(icon: "exclamationmark.circle.fill", tint: .yellow,
                                title: L10n.t("weak_passwords_title"),
                                message: L10n.t("weak_password_message"))
                }
                if card.isExpired {
                    warningCard(icon: "clock.badge.exclamationmark", tint: .red,
                                title: L10n.t("card_expired_warning"), message: nil)
                } else if card.isExpiring {
                    warningCard(icon: "hourglass", tint: .orange,
                                title: "\(L10n.t("card_expiring_warning")) \(card.expiringInDays)",
                                message: nil)
                }
            }
        }
    }

    private func warningCard(icon: String, tint: Color, title: String, message: String?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let message {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    /// 此卡密码是否与其他条目重复(SamePasswordsService 分组里含本卡)。
    private func isReusedPassword(_ card: Card) -> Bool {
        ctx.reusedPasswordCardIDs.contains(card.id)
    }

    // MARK: Images / files / footer

    private func imagesSection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            attachmentSectionHeader(L10n.db("images_label")) {
                pickAttachments(isImage: true)
            }
            attachmentDownloadNotice(cardID: card.id)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack {
                    ForEach(card.images) { img in
                        if let data = img.data {
                            AttachmentThumbnailView(
                                data: data,
                                contentVersion: img.contentVersion,
                                name: img.name,
                                onPreview: { previewAttachment = img },
                                onRetry: { requestAttachmentPreview(img) },
                                unavailableSymbol: attachmentStatusSymbol(for: card.id)
                            )
                            .contextMenu {
                                attachmentRetentionButton(img, cardID: card.id)
                                Button(L10n.t("copy_command")) {
                                    ClipboardModel.shared.copy(data.base64EncodedString())
                                }
                                Button(L10n.t("delete_button"), role: .destructive) {
                                    updateDraft { $0.images.removeAll { $0.id == img.id } }
                                }
                            }
                        } else {
                            Button {
                                requestAttachmentPreview(img)
                            } label: {
                                VStack(spacing: 6) {
                                    attachmentStatusSymbol(for: card.id)
                                        .font(.title2)
                                    Text(L10n.t("attachment_content_unavailable"))
                                        .font(.caption)
                                        .multilineTextAlignment(.center)
                                }
                                .foregroundStyle(.secondary)
                                .frame(width: 120, height: 96)
                            }
                            .buttonStyle(.plain)
                            .help(L10n.t("attachment_download_retry"))
                            .accessibilityLabel(img.name)
                            .contextMenu {
                                attachmentRetentionButton(img, cardID: card.id)
                                Button(L10n.t("delete_button"), role: .destructive) {
                                    updateDraft { $0.images.removeAll { $0.id == img.id } }
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        }
    }

    private struct AttachmentThumbnailView<UnavailableSymbol: View>: View {
        let data: Data
        let contentVersion: UUID
        let name: String
        let onPreview: () -> Void
        let onRetry: () -> Void
        let unavailableSymbol: UnavailableSymbol

        @State private var thumbnail: CGImage?
        @State private var isDecoding = true

        var body: some View {
            Group {
                if let thumbnail {
                    Button(action: onPreview) {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                    .help(L10n.t("attachment_preview_button"))
                } else if isDecoding {
                    ProgressView()
                        .frame(width: 96, height: 96)
                        .accessibilityLabel(L10n.t("attachment_preview_button"))
                } else {
                    Button(action: onRetry) {
                        VStack(spacing: 6) {
                            unavailableSymbol
                                .font(.title2)
                            Text(L10n.t("attachment_content_unavailable"))
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 120, height: 96)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.t("attachment_download_retry"))
                    .accessibilityLabel(name)
                }
            }
            .task(id: contentVersion) {
                thumbnail = nil
                isDecoding = true
                let data = data
                let result = await Task.detached(priority: .userInitiated) {
                    AttachmentImageDecoder.thumbnail(
                        data: data,
                        maxPixelSize: AttachmentImageDecoder.galleryThumbnailPixelSize)
                }.value
                guard !Task.isCancelled else { return }
                thumbnail = result
                isDecoding = false
            }
        }
    }

    private func filesSection(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            attachmentSectionHeader(L10n.db("files_label")) {
                pickAttachments(isImage: false)
            }
            if card.images.isEmpty { attachmentDownloadNotice(cardID: card.id) }
            VStack(spacing: 0) {
                ForEach(Array(card.files.enumerated()), id: \.element.id) { i, file in
                    fileRow(file)
                    if i < card.files.count - 1 { Divider() }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        }
    }

    private func fileRow(_ file: Attachment) -> some View {
        HStack {
            Image(systemName: "doc")
            Text(file.name)
                .lineLimit(1)
            Spacer()
            if let data = file.data {
                Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                    .foregroundStyle(.secondary).font(.caption)
                if AttachmentImageDecoder.isImage(data) {
                    Button {
                        previewAttachment = file
                    } label: {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.link)
                    .help(L10n.t("attachment_preview_button"))
                    .accessibilityLabel(L10n.t("attachment_preview_button"))
                }
                Button(L10n.t("save_button")) { saveAttachment(file) }
                    .buttonStyle(.link)
            } else {
                Button {
                    if let cardID = ctx.selectedCardId {
                        ctx.prioritizeAttachmentDownload(cardID: cardID, retryFailures: true)
                    }
                } label: {
                    if let cardID = ctx.selectedCardId {
                        attachmentStatusSymbol(for: cardID)
                    }
                }
                .buttonStyle(.link)
                .help(L10n.t("attachment_download_retry"))
                .accessibilityLabel(L10n.t("attachment_download_retry"))
            }
            Button(role: .destructive) {
                updateDraft { $0.files.removeAll { $0.id == file.id } }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help(L10n.t("delete_button"))
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contextMenu {
            if let cardID = ctx.selectedCardId { attachmentRetentionButton(file, cardID: cardID) }
        }
    }

    private func attachmentRetentionButton(_ attachment: Attachment, cardID: UUID) -> some View {
        let isKeptOffline = ctx.isAttachmentKeptOffline(cardID: cardID, attachmentID: attachment.id)
        return Button(L10n.t(isKeptOffline ? "attachment_release_offline" : "attachment_keep_offline")) {
            ctx.setAttachmentKeptOffline(!isKeptOffline, cardID: cardID, attachmentID: attachment.id)
        }
        .disabled(!attachment.hasPersistentID || !attachment.hasPersistentContentVersion)
    }

    @ViewBuilder
    private func attachmentDownloadNotice(cardID: UUID) -> some View {
        if let status = ctx.attachmentDownloadStatusText(cardID: cardID) {
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }

    @MainActor private func saveAttachment(_ file: Attachment) {
        guard let data = file.data else {
            AppToast.shared.show(L10n.t("attachment_content_unavailable"))
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                Log.info("ui", "detail save attachment cardId ok name.len=\(url.lastPathComponent.count) bytes=\(data.count)")
                AppToast.shared.show(L10n.t("file_saved_message") + " " + url.lastPathComponent)
            } catch {
                Log.error("ui", "detail save attachment failed: \(error)")
                AppToast.shared.show(L10n.t("file_saved_message") + " ✗")
            }
        }
    }

    private func attachmentSectionHeader(_ title: String, addAction: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            Button(action: addAction) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("add_button"))
        }
    }

    @MainActor private func pickAttachments(isImage: Bool) {
        let panel = NSOpenPanel()
        if isImage { panel.allowedContentTypes = [.image] }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                let data = try AttachmentFileReader.readContents(of: url)
                updateDraft { card in
                    let attachment = Attachment(name: url.lastPathComponent, data: data)
                    if isImage {
                        card.images.append(attachment)
                    } else {
                        card.files.append(attachment)
                    }
                }
                Log.info("ui", "detail attachment added image=\(isImage) bytes=\(data.count)")
            } catch let error as AttachmentFileReader.ReadError {
                Log.error("ui", "detail attachment size check failed: \(error)")
                AppToast.shared.show(error.localizedDescription)
            } catch {
                Log.error("ui", "detail attachment read failed: \(error)")
                AppToast.shared.show(L10n.t("ios_import_unreadable_message"))
            }
        }
    }

    private func requestAttachmentPreview(_ attachment: Attachment) {
        guard let cardID = ctx.selectedCardId, ctx.relayBound else {
            AppToast.shared.show(L10n.t("attachment_content_unavailable"))
            return
        }
        pendingAttachmentPreviewID = attachment.id
        ctx.prioritizeAttachmentDownload(cardID: cardID, retryFailures: true)
    }

    @ViewBuilder
    private func attachmentStatusSymbol(for cardID: UUID) -> some View {
        switch ctx.attachmentDownloadStates[cardID] {
        case .queued, .downloading:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "arrow.clockwise").foregroundStyle(.orange)
        case nil:
            Image(systemName: "icloud.and.arrow.down")
        }
    }

    private func trashActions(_ card: Card) -> some View {
        HStack {
            if card.trashed {
                Button(L10n.t("restore_card_command")) { ctx.restoreCard(card.id) }
                Button(L10n.t("delete_button"), role: .destructive) { ctx.deleteCardPermanently(card.id) }
            } else if card.archived {
                Button(L10n.t("unarchive_command")) { ctx.unarchiveCard(card.id) }
            }
            Spacer()
        }
    }

    private func bottomBar(_ card: Card?) -> some View {
        ViewThatFits(in: .horizontal) {
            bottomBarRow(card, showAutofillLabel: true)
            bottomBarRow(card, showAutofillLabel: false)
        }
    }

    private func bottomBarRow(_ card: Card?, showAutofillLabel: Bool) -> some View {
        HStack(spacing: 10) {
            if let card {
                autofillToggle(card, showLabel: showAutofillLabel)
            }
            if hasUnsavedChanges {
                Button(action: cancelEdits) {
                    Image(systemName: "xmark")
                        .frame(width: 30, height: 24)
                }
                .buttonStyle(.plain)
                .help(L10n.t("cancel_button"))
                Button {
                    saveEdits()
                } label: {
                    Label(L10n.t("save_button"), systemImage: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            Spacer(minLength: 8)
            if let card {
                Button {
                    toggleFavorite(card.id)
                } label: {
                    Image(systemName: card.favorite ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(card.favorite ? Color.yellow : Color.white.opacity(0.55))
                        .frame(width: 36, height: 26)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.045)))
                }
                .buttonStyle(.plain)
                .help(L10n.t("favorites_label"))
                ShareLink(item: card.asPlainText()) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 36, height: 26)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.045)))
                }
                .help(L10n.t("share_menu"))
            }
        }
        .padding(.leading, 17.5)
        .padding(.trailing, 21)
        .padding(.bottom, 12)
        .background(Color.appBackground)
    }

    @ViewBuilder
    private func autofillToggle(_ card: Card, showLabel: Bool) -> some View {
        let toggle = Toggle(L10n.t("use_for_autofill_button"), isOn: Binding(
            get: { editingCard?.autofillEnabled ?? card.autofillEnabled },
            set: { enabled in updateDraft { $0.autofillEnabled = enabled } }
        ))
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        .fixedSize()
        if showLabel {
            toggle
        } else {
            toggle.labelsHidden()
                .help(L10n.t("use_for_autofill_button"))
        }
    }
}

/// 字段行 + 密码行 + 一次性代码行布局(分组卡片内):
/// 单击值复制、双击进入行内编辑。
/// 密码默认遮蔽,网站默认显示主机;悬停展示完整值,网站值可点击打开。
struct FieldRowView: View {
    private static let maskedPasswordDotCount = 12
    private static let copyFeedbackAnimationDuration = 0.07
    private static let minimumOneTimePasswordFeedbackWidth: CGFloat = 80

    @EnvironmentObject var settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cardID: UUID
    @Binding var field: Field
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    let onCommitEditing: () -> Void
    let focusedValueFieldID: FocusState<UUID?>.Binding
    @State private var valueHovering = false
    @State private var valueEditing = false
    @State private var copyFeedback = false
    @State private var copyFeedbackID = 0
    @State private var displayedValueWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            TextField(L10n.t("field_name_prompt"), text: fieldNameBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 112, height: 28, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                valueContent
                if field.type == .password && field.hasValue {
                    StrengthIndicatorView(strength: PasswordStrength.score(field.value))
                        .frame(maxWidth: 160, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity)

            fieldOptions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task(id: copyFeedbackID) {
            guard copyFeedbackID > 0 else { return }
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: Self.copyFeedbackAnimationDuration)) {
                copyFeedback = false
            }
        }
        .onPreferenceChange(FieldValueWidthPreferenceKey.self) { width in
            guard width.isFinite, width > 0,
                  abs(displayedValueWidth - width) > 0.5 else { return }
            displayedValueWidth = width
        }
    }

    @ViewBuilder
    private var valueContent: some View {
        if valueEditing {
            valueEditor
        } else if field.type.isOneTimePassword {
            ZStack(alignment: .trailing) {
                OTPView(rawValue: field.value, onCopy: copyText, onEdit: beginValueEditing)
                    .opacity(copyFeedback ? 0 : 1)
                    .accessibilityLabel(field.name)
                    .accessibilityHint(L10n.t("detail_field_value_help"))
                if copyFeedback {
                    copyConfirmation(
                        width: max(displayedValueWidth, Self.minimumOneTimePasswordFeedbackWidth)
                    )
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .trailing)
        } else {
            ZStack(alignment: .trailing) {
                if copyFeedback {
                    copyConfirmation(width: displayedValueWidth)
                } else {
                    Text(displayedValue)
                        .font(
                            .system(
                                size: isPasswordMasked ? 14 : 13,
                                weight: isPasswordMasked ? .medium : .regular,
                                design: isPasswordMasked ? .monospaced : .default
                            )
                        )
                        .tracking(isPasswordMasked ? 1.5 : 0)
                        .foregroundStyle(
                            isPasswordMasked ? Color.white.opacity(0.55) : Color.white.opacity(0.87)
                        )
                        .multilineTextAlignment(.trailing)
                        .truncationMode(field.type == .website ? .middle : .tail)
                        .lineLimit(1)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: FieldValueWidthPreferenceKey.self,
                                    value: geometry.size.width
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .trailing)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .trailing)
            .contentShape(Rectangle())
            .onHover { valueHovering = $0 }
            .help(valueHelpText)
            .gesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { result in
                        switch result {
                        case .first:
                            beginValueEditing()
                        case .second:
                            if field.type == .website { activateValue() }
                        }
                    }
            )
            // Handle copy on the first tap instead of waiting for double-tap disambiguation.
            .simultaneousGesture(
                TapGesture().onEnded {
                    if field.type != .website { activateValue() }
                }
            )
            .accessibilityLabel(field.name)
            .accessibilityValue(copyFeedback ? L10n.t("copy_confirmation_text") : displayedValue)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(valueHelpText)
            .accessibilityAction(named: valueActionName) { activateValue() }
            .accessibilityAction(named: L10n.t("edit_button")) { beginValueEditing() }
        }
    }

    private func copyConfirmation(width: CGFloat) -> some View {
        Text(L10n.t("copy_confirmation_text"))
            .font(.system(size: 13))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(Color.white.opacity(0.72))
            .frame(width: max(width, 1), height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.05))
            )
            .transition(.opacity)
    }

    private var fieldNameBinding: Binding<String> {
        Binding(
            get: { displayedFieldName },
            set: { field.name = $0 }
        )
    }

    private var displayedFieldName: String {
        guard field.type == .website else { return field.name }
        let isDefaultWebsiteName = field.name == L10n.db("url_field")
            || field.name == L10n.db("website_type")
        guard isDefaultWebsiteName else { return field.name }
        return L10n.db("website_field_label")
    }

    private var valueHelpText: String {
        if field.type == .website {
            guard valueHovering && field.hasValue else { return L10n.t("open_website_help") }
            return "\(L10n.t("open_website_help")): \(field.value)"
        }
        if valueHovering && field.hasValue { return field.value }
        return L10n.t("detail_field_value_help")
    }

    private var valueActionName: String {
        L10n.t(field.type == .website ? "open_website_help" : "copy_command")
    }

    private var isPasswordMasked: Bool {
        field.type.isHidden && settings.hidePasswords && !valueHovering && !valueEditing
    }

    private var displayedValue: String {
        guard field.hasValue else { return field.type.valuePlaceholder }
        if isPasswordMasked {
            return String(repeating: "•", count: Self.maskedPasswordDotCount)
        }
        if field.type == .website { return websiteDisplayValue }
        return field.value
    }

    private var websiteDisplayValue: String {
        let rawValue = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return rawValue }
        return rawValue.contains("://") ? rawValue : "https://\(rawValue)"
    }

    private func beginValueEditing() {
        copyFeedback = false
        valueEditing = true
        Log.info("ui", "detail field edit started cardId=\(cardID) fieldId=\(field.id) type=\(field.type.rawValue)")
    }

    private func finishValueEditing() {
        guard valueEditing else { return }
        valueEditing = false
        if focusedValueFieldID.wrappedValue == field.id {
            focusedValueFieldID.wrappedValue = nil
        }
        onCommitEditing()
    }

    @ViewBuilder
    private var valueEditor: some View {
        Group {
            if field.type.isHidden && settings.hidePasswords && field.type != .password {
                SecureField(field.type.valuePlaceholder, text: $field.value)
            } else {
                TextField(field.type.valuePlaceholder, text: $field.value)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 13, design: field.type.isHidden ? .monospaced : .default))
        .multilineTextAlignment(.trailing)
        .focused(focusedValueFieldID, equals: field.id)
        .onAppear { focusedValueFieldID.wrappedValue = field.id }
        .onChange(of: focusedValueFieldID.wrappedValue) { _, focusedID in
            if focusedID != field.id { finishValueEditing() }
        }
        .onSubmit { finishValueEditing() }
        .padding(.horizontal, 7)
        .frame(minHeight: 28)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ValueEditorFramePreferenceKey.self,
                    value: geometry.frame(in: .named("cardDetailContent"))
                )
            }
        }
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.035)))
    }

    private var fieldOptions: some View {
        Menu {
            Menu(L10n.t("type_title")) {
                ForEach(FieldType.allCases) { type in
                    Button {
                        field.type = type
                    } label: {
                        if field.type == type {
                            Label(type.localizedName, systemImage: "checkmark")
                        } else {
                            Text(type.localizedName)
                        }
                    }
                }
            }
            Menu(L10n.t("autofill_title", fallback: "自动填充")) {
                ForEach(Autofill.allCases) { autofill in
                    Button {
                        field.autofill = autofill
                    } label: {
                        if field.autofill == autofill {
                            Label(autofill.localizedName, systemImage: "checkmark")
                        } else {
                            Text(autofill.localizedName)
                        }
                    }
                }
            }
            if field.type == .website {
                Menu(L10n.t("site_match_label")) {
                    ForEach(SiteMatchMode.allCases) { mode in
                        Button {
                            field.siteMatch = mode
                        } label: {
                            if field.siteMatch == mode {
                                Label(mode.localizedName, systemImage: "checkmark")
                            } else {
                                Text(mode.localizedName)
                            }
                        }
                    }
                }
            }
            if field.hasHistory {
                Menu(L10n.t("history_title")) {
                    ForEach(field.history.sorted { $0.time > $1.time }) { entry in
                        Button("\(entry.value) — \(entry.time.date.formatted(date: .abbreviated, time: .shortened))") {
                            field.value = entry.value
                        }
                    }
                }
            }
            Divider()
            Button(L10n.t("move_up_command", fallback: "上移"), action: onMoveUp)
                .disabled(!canMoveUp)
            Button(L10n.t("move_down_command", fallback: "下移"), action: onMoveDown)
                .disabled(!canMoveDown)
            Divider()
            Button(L10n.t("delete_button"), role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.t("edit_field_title"))
    }

    private func openWebsite() {
        let trimmedValue = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmedValue.contains("://") ? trimmedValue : "https://\(trimmedValue)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              let url = components.url else {
            Log.warn("ui", "detail open website rejected cardId=\(cardID)")
            return
        }
        Log.info("ui", "detail open website cardId=\(cardID)")
        if !NSWorkspace.shared.open(url) {
            Log.warn("ui", "detail open website failed cardId=\(cardID)")
        }
    }

    private func activateValue() {
        if field.type == .website {
            openWebsite()
        } else {
            copyValue()
        }
    }

    private func copyValue() {
        guard field.hasValue else { return }
        copyText(field.value)
    }

    private func copyText(_ text: String) {
        guard !valueEditing, !text.isEmpty else { return }
        Log.info("ui", "detail copy field cardId=\(cardID) type=\(field.type.rawValue) len=\(text.utf8.count)")
        ClipboardModel.shared.copy(text, alert: false)
        withAnimation(reduceMotion ? nil : .easeOut(duration: Self.copyFeedbackAnimationDuration)) {
            copyFeedback = true
        }
        copyFeedbackID += 1
    }
}

private struct FieldValueWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ValueEditorFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let frame = nextValue()
        if !frame.isEmpty { value = frame }
    }
}

/// ViewCardOneTimePasswordCell — live RFC 6238 code with rollover progress.
struct OTPView: View {
    let rawValue: String
    let onCopy: (String) -> Void
    let onEdit: () -> Void

    @State private var code: String? = nil
    @State private var period = 30
    @State private var error: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let code {
                OTPCountdownRing(period: period)
                Text(code)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.87))
                    .contentShape(Rectangle())
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: FieldValueWidthPreferenceKey.self,
                    value: geometry.size.width
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .trailing)
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { result in
                    if case .first = result { onEdit() }
                }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                if let code { onCopy(code) }
            }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(code ?? error ?? "—")
        .accessibilityAction(named: L10n.t("copy_command")) {
            if let code { onCopy(code) }
        }
        .accessibilityAction(named: L10n.t("edit_button")) { onEdit() }
        .task(id: rawValue) {
            await refreshCode()
        }
    }

    private func refreshCode() async {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if code != nil { code = nil }
            if error != nil { error = nil }
            return
        }
        guard let config = try? TOTP.parse(rawValue) else {
            error = L10n.t("invalid_value_text")
            if code != nil { code = nil }
            return
        }

        if error != nil { error = nil }
        if period != config.period { period = config.period }

        while !Task.isCancelled {
            let updatedCode = try? TOTP.code(config: config)
            if code != updatedCode { code = updatedCode }

            let periodDuration = TimeInterval(config.period)
            let elapsed = Date().timeIntervalSince1970
                .truncatingRemainder(dividingBy: periodDuration)
            let delay = periodDuration - elapsed
            try? await Task.sleep(for: .seconds(delay))
        }
    }
}

private struct MetaDateRowView: View {
    private static let copyFeedbackAnimationDuration = 0.07

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let label: String
    let date: Date

    @State private var isCopied = false
    @State private var copyFeedbackID = 0
    @State private var displayedTextWidth: CGFloat = 0

    private var formattedDate: String {
        if L10n.effectiveLanguage == "zh-Hans" {
            return Self.isoDateFormatter.string(from: date)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 24)
            ZStack(alignment: .trailing) {
                Text(formattedDate)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.87))
                    .opacity(isCopied ? 0 : 1)
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear { displayedTextWidth = geometry.size.width }
                                .onChange(of: geometry.size.width) { _, width in
                                    displayedTextWidth = width
                                }
                        }
                    }
                if isCopied {
                    Text(L10n.t("copy_confirmation_text"))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(Color.white.opacity(0.72))
                        .frame(width: max(displayedTextWidth, 1), height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white.opacity(0.05))
                        )
                        .transition(.opacity)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contentShape(Rectangle())
            .onTapGesture(perform: copyDate)
            .accessibilityLabel(label)
            .accessibilityValue(isCopied ? L10n.t("copy_confirmation_text") : formattedDate)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: L10n.t("copy_command")) { copyDate() }
        }
        .task(id: copyFeedbackID) {
            guard copyFeedbackID > 0 else { return }
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: Self.copyFeedbackAnimationDuration)) {
                isCopied = false
            }
        }
    }

    private func copyDate() {
        let value = formattedDate
        ClipboardModel.shared.copy(value, alert: false)
        withAnimation(reduceMotion ? nil : .easeOut(duration: Self.copyFeedbackAnimationDuration)) {
            isCopied = true
        }
        copyFeedbackID += 1
        Log.info("ui", "detail date copied len=\(value.utf8.count)")
    }

    private static var isoDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }
}
