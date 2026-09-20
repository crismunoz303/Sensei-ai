import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ModelVaultFolderPicker: UIViewControllerRepresentable {
    let onPick: @MainActor (URL) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> PickerHostViewController {
        let host = PickerHostViewController()
        host.coordinator = context.coordinator
        return host
    }

    func updateUIViewController(
        _ uiViewController: PickerHostViewController,
        context: Context
    ) {
        uiViewController.coordinator = context.coordinator
    }

    @MainActor
    final class PickerHostViewController: UIViewController {
        weak var coordinator: Coordinator?
        private var hasPresentedPicker = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)

            guard !hasPresentedPicker else { return }
            hasPresentedPicker = true

            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [.folder]
            )
            picker.delegate = coordinator
            picker.allowsMultipleSelection = false
            picker.modalPresentationStyle = .fullScreen
            present(picker, animated: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: @MainActor (URL) -> Void
        let onCancel: @MainActor () -> Void

        init(
            onPick: @escaping @MainActor (URL) -> Void,
            onCancel: @escaping @MainActor () -> Void
        ) {
            self.onPick = onPick
            self.onCancel = onCancel
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
    }
}
