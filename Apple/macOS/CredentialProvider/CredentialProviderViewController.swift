import AppKit
import AuthenticationServices
import SwiftUI

/// macOS 系统密码自动填充扩展的界面入口。
final class CredentialProviderViewController: ASCredentialProviderViewController {
    private let model = CredentialProviderModel()
    private var hostingController: NSHostingController<CredentialProviderView>?

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        model.attach(context: extensionContext, serviceIdentifiers: serviceIdentifiers)
        installView()
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        let error = NSError(
            domain: ASExtensionErrorDomain,
            code: ASExtensionError.userInteractionRequired.rawValue)
        extensionContext.cancelRequest(withError: error)
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        model.attach(context: extensionContext, request: credentialRequest)
        installView()
    }

    private func installView() {
        let controller = NSHostingController(rootView: CredentialProviderView(model: model))
        hostingController = controller
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
