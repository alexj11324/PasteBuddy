import PasteBuddyCore
import PasteBuddyMobile
import UIKit

@MainActor
final class ShareActionViewController: UIViewController {
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let doneButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private var store: PasteBuddyStore?

    private var source: SharedContentSource {
        if Bundle.main.bundleIdentifier?.localizedCaseInsensitiveContains("Action") == true {
            .actionExtension
        } else {
            .shareExtension
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        Task { await importSharedContent() }
    }

    private func configureView() {
        view.backgroundColor = .systemBackground

        titleLabel.text = source == .shareExtension ? localized("action.save_to_pastebuddy") : localized("action.copy_to_pastebuddy")
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true

        messageLabel.text = localized("message.preparing_shared_content")
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.numberOfLines = 0
        messageLabel.textColor = .secondaryLabel

        doneButton.setTitle(localized("action.done"), for: .normal)
        doneButton.addTarget(self, action: #selector(done), for: .touchUpInside)

        retryButton.setTitle(localized("action.retry"), for: .normal)
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        retryButton.isHidden = true

        let buttonStack = UIStackView(arrangedSubviews: [retryButton, doneButton])
        buttonStack.axis = .horizontal
        buttonStack.alignment = .center
        buttonStack.distribution = .equalSpacing

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            activityIndicator,
            messageLabel,
            buttonStack
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func providersFromExtensionContext() -> [NSItemProvider] {
        guard let inputItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return []
        }
        return inputItems.flatMap { $0.attachments ?? [] }
    }

    private func importSharedContent() async {
        retryButton.isHidden = true
        activityIndicator.startAnimating()
        messageLabel.text = localized("message.saving_shared_content_to_encrypted_history")

        let providers = providersFromExtensionContext()
        guard !providers.isEmpty else {
            showFailure(MobileItemProviderAdapterError.emptyProviders.localizedDescription)
            return
        }

        let resolvedStore = MobileStoreFactory.makeStore()
        resolvedStore.load()
        switch source {
        case .shareExtension:
            resolvedStore.setShareExtensionEnabled(true)
        case .actionExtension:
            resolvedStore.setActionExtensionEnabled(true)
        default:
            break
        }
        store = resolvedStore

        do {
            let result = try await MobileShareActionExtensionService.importSupportedContent(
                from: providers,
                into: resolvedStore,
                configuration: MobileItemProviderImportConfiguration(source: source)
            )
            showSuccess(result.statusMessage)
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    private func showSuccess(_ message: String) {
        activityIndicator.stopAnimating()
        retryButton.isHidden = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.text = message
    }

    private func showFailure(_ message: String) {
        activityIndicator.stopAnimating()
        retryButton.isHidden = false
        messageLabel.textColor = .systemRed
        messageLabel.text = message
    }

    @objc private func done() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func retry() {
        Task { await importSharedContent() }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
