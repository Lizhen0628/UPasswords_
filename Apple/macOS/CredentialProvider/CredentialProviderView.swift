import SwiftUI

import UPasswordsCore

/// macOS 系统自动填充界面展示的紧凑型凭据选择器。
struct CredentialProviderView: View {
    @ObservedObject var model: CredentialProviderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 360, minHeight: 280)
        .padding(.bottom, 12)
        .task { model.attemptBiometricUnlockIfAvailable() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(L10n.t("app_title"))
                .font(.headline)
            Spacer()
            Button(L10n.t("cancel_button")) { model.cancel() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .noVault:
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("ios_af_no_vault_title"))
                    .font(.title3.weight(.semibold))
                Text(L10n.t("ios_af_no_vault_detail"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        case .locked:
            lockedView
        case .unlocked:
            listView
        }
    }

    private var lockedView: some View {
        VStack(spacing: 14) {
            Image(systemName: model.biometricUnlockAvailable ? "touchid" : "lock.fill")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.secondary)
            Text(L10n.t("ios_af_unlock_title"))
                .font(.title3.weight(.semibold))
            if let serviceLabel = model.serviceLabel {
                Text(serviceLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if model.biometricUnlockAvailable {
                Button {
                    model.unlockWithBiometrics()
                } label: {
                    HStack(spacing: 8) {
                        if model.biometricUnlockInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "touchid")
                        }
                        Text(L10n.t("autofill_touch_id_unlock_button"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.biometricUnlockInProgress)
            }
            HStack {
                SecureField(L10n.t("ios_master_password_prompt"), text: $model.masterInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.unlock() }
                    .disabled(model.biometricUnlockInProgress)
                Button(L10n.t("unlock_button")) { model.unlock() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.masterInput.isEmpty || model.biometricUnlockInProgress)
            }
            if model.showUnlockError {
                Text(L10n.t("ios_af_wrong_password_text"))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var listView: some View {
        Group {
            if model.cards.isEmpty {
                Text(L10n.t("ios_af_no_fillable_text"))
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.cards) { card in
                            Button { model.select(card) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(card.login)
                                            .font(.body.weight(.medium))
                                            .lineLimit(1)
                                        Text(card.title.isEmpty ? L10n.t("app_title") : card.title)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }
}
