import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ModelVaultFolderPicker: UIViewControllerRepresentable {
    let onPick: @MainActor (URL) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder],
            asCopy: false
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

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
                Task { @MainActor in
                    onCancel()
                }
                return
            }

            Task { @MainActor in
                onPick(url)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Task { @MainActor in
                onCancel()
            }
        }
    }
}
