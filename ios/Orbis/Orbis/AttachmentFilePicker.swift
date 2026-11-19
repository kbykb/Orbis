import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A fresh system document picker for each attachment presentation. The uploader
/// retains responsibility for opening security-scoped URLs after selection.
struct AttachmentFilePicker: UIViewControllerRepresentable {
    let attemptId: String
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(attemptId: attemptId, onPick: onPick, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        MobileDiagnostics.shared.record("attachment.picker.create_start", detail: ["attemptId": attemptId])
        let picker = TracedDocumentPicker(attemptId: attemptId)
        MobileDiagnostics.shared.record("attachment.picker.created", detail: ["attemptId": attemptId])
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        picker.delegate = context.coordinator
        MobileDiagnostics.shared.record("attachment.picker.configured", detail: ["attemptId": attemptId, "directory": "app_documents", "asCopy": "false"])
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }

    static func dismantleUIViewController(_ picker: UIDocumentPickerViewController, coordinator: Coordinator) {
        MobileDiagnostics.shared.endFilePicker(reason: "view_removed", attemptId: coordinator.attemptId)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let attemptId: String
        var onPick: ([URL]) -> Void
        var onCancel: () -> Void

        init(attemptId: String, onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.attemptId = attemptId
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            MobileDiagnostics.shared.record("attachment.picker.selected", detail: ["attemptId": attemptId, "count": String(urls.count)])
            MobileDiagnostics.shared.endFilePicker(reason: "selected", attemptId: attemptId)
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            MobileDiagnostics.shared.record("attachment.picker.cancelled", detail: ["attemptId": attemptId])
            MobileDiagnostics.shared.endFilePicker(reason: "cancelled", attemptId: attemptId)
            onCancel()
        }
    }
}

private final class TracedDocumentPicker: UIDocumentPickerViewController {
    private let attemptId: String

    init(attemptId: String) {
        self.attemptId = attemptId
        super.init(forOpeningContentTypes: [.item], asCopy: false)
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        trace("loaded")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        trace("will_appear")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        trace("appeared")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        trace("disappeared")
    }

    private func trace(_ stage: String) {
        MobileDiagnostics.shared.record("attachment.picker." + stage, detail: ["attemptId": attemptId])
    }
}
