import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ModelVaultPackagePicker: UIViewControllerRepresentable {
    enum Mode {
        case create
        case connect
    }

    let mode: Mode
    let onPick: @MainActor (URL) -> Void
    let onCancel: @MainActor () -> Void
    let onError: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPick: onPick,
            onCancel: onCancel,
            onError: onError
        )
    }

    func makeUIViewController(context: Context) -> PickerHostViewController {
        let host = PickerHostViewController()
        host.mode = mode
        host.coordinator = context.coordinator
        return host
    }

    func updateUIViewController(
        _ uiViewController: PickerHostViewController,
        context: Context
    ) {
        uiViewController.mode = mode
        uiViewController.coordinator = context.coordinator
    }

    @MainActor
    final class PickerHostViewController: UIViewController {
        var mode: Mode = .create
        weak var coordinator: Coordinator?
        private var hasPresentedPicker = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)

            guard !hasPresentedPicker else { return }
            hasPresentedPicker = true

            do {
                let picker: UIDocumentPickerViewController

                switch mode {
                case .create:
                    let packageURL = try ModelVaultManager.shared.makeTemporaryVaultPackage()
                    picker = UIDocumentPickerViewController(
                        forExporting: [packageURL],
                        asCopy: false
                    )

                case .connect:
                    picker = UIDocumentPickerViewController(
                        forOpeningContentTypes: [.bundle],
                        asCopy: false
                    )
                }

                picker.delegate = coordinator
                picker.allowsMultipleSelection = false
                picker.modalPresentationStyle = .fullScreen
                present(picker, animated: true)
            } catch {
                coordinator?.report(error.localizedDescription)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: @MainActor (URL) -> Void
        let onCancel: @MainActor () -> Void
        let onError: @MainActor (String) -> Void

        init(
            onPick: @escaping @MainActor (URL) -> Void,
            onCancel: @escaping @MainActor () -> Void,
            onError: @escaping @MainActor (String) -> Void
        ) {
            self.onPick = onPick
            self.onCancel = onCancel
            self.onError = onError
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else {
                onCancel()
                return
            }

            onPick(url)
        }

        func documentPickerWasCancelled(
            _ controller: UIDocumentPickerViewController
        ) {
            onCancel()
        }

        func report(_ message: String) {
            onError(message)
        }
    }
}
