import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A stable presentation anchor. UIKit presents the system picker itself rather
/// than embedding its remote document browser inside a SwiftUI sheet.
struct AttachmentFilePicker: UIViewControllerRepresentable {
    let attemptId: String?
    let onPick: (String, [URL]) -> Void
    let onCancel: (String) -> Void

    func makeUIViewController(context: Context) -> Presenter { Presenter() }

    func updateUIViewController(_ presenter: Presenter, context: Context) {
        presenter.update(attemptId: attemptId, onPick: onPick, onCancel: onCancel)
    }

    static func dismantleUIViewController(_ presenter: Presenter, coordinator: ()) {
        presenter.stop()
    }

    final class Presenter: UIViewController, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        private var requestedAttemptId: String?
        private var activeAttemptId: String?
        private var finishedAttemptId: String?
        private var picker: UIDocumentPickerViewController?
        private var appeared = false
        private var finishing = false
        private var onPick: (String, [URL]) -> Void = { _, _ in }
        private var onCancel: (String) -> Void = { _ in }

        override func loadView() {
            let anchor = UIView()
            anchor.backgroundColor = .clear
            anchor.isUserInteractionEnabled = false
            view = anchor
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            appeared = true
            presentIfReady()
        }

        override func viewWillDisappear(_ animated: Bool) {
            appeared = false
            super.viewWillDisappear(animated)
        }

        func update(attemptId: String?, onPick: @escaping (String, [URL]) -> Void,
                    onCancel: @escaping (String) -> Void) {
            requestedAttemptId = attemptId
            self.onPick = onPick
            self.onCancel = onCancel
            if let picker, activeAttemptId != attemptId {
                finish(picker, reason: "selection_changed", notify: false)
            } else {
                presentIfReady()
            }
        }

        private func presentIfReady() {
            guard appeared, viewIfLoaded?.window != nil, picker == nil,
                  presentedViewController == nil, let attemptId = requestedAttemptId,
                  attemptId != finishedAttemptId else { return }
            MobileDiagnostics.shared.record("attachment.picker.create_start", detail: ["attemptId": attemptId])
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
            MobileDiagnostics.shared.record("attachment.picker.created", detail: ["attemptId": attemptId])
            picker.allowsMultipleSelection = true
            picker.shouldShowFileExtensions = true
            picker.modalPresentationStyle = .fullScreen
            picker.delegate = self
            self.picker = picker
            activeAttemptId = attemptId
            MobileDiagnostics.shared.record("attachment.picker.configured", detail: [
                "attemptId": attemptId, "directory": "system_default", "asCopy": "false", "presentation": "native_full_screen"
            ])
            present(picker, animated: true) { [weak self, weak picker] in
                guard let self, let picker, self.picker === picker else { return }
                // Presentation completion confirms the container, not that the
                // separate system document-browser service has loaded its UI.
                MobileDiagnostics.shared.record("attachment.picker.presented", detail: [
                    "attemptId": attemptId, "readiness": "container_only"
                ])
            }
            picker.presentationController?.delegate = self
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard picker === controller, let attemptId = activeAttemptId else { return }
            MobileDiagnostics.shared.record("attachment.picker.selected", detail: ["attemptId": attemptId, "count": String(urls.count)])
            finish(controller, reason: "selected", urls: urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard picker === controller, let attemptId = activeAttemptId else { return }
            MobileDiagnostics.shared.record("attachment.picker.cancelled", detail: ["attemptId": attemptId])
            finish(controller, reason: "cancelled")
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard let picker, presentationController.presentedViewController === picker else { return }
            finish(picker, reason: "dismissed")
        }

        private func finish(_ controller: UIDocumentPickerViewController, reason: String,
                            urls: [URL]? = nil, notify: Bool = true) {
            guard picker === controller, let attemptId = activeAttemptId, !finishing else { return }
            finishing = true
            finishedAttemptId = attemptId
            MobileDiagnostics.shared.endFilePicker(reason: reason, attemptId: attemptId)
            let complete = { [weak self] in
                guard let self else { return }
                self.picker = nil
                self.activeAttemptId = nil
                self.finishing = false
                if notify {
                    if let urls { self.onPick(attemptId, urls) }
                    else { self.onCancel(attemptId) }
                }
                self.presentIfReady()
            }
            if controller.presentingViewController != nil {
                controller.dismiss(animated: true, completion: complete)
            } else {
                complete()
            }
        }

        func stop() {
            appeared = false
            requestedAttemptId = nil
            onPick = { _, _ in }
            onCancel = { _ in }
            guard let picker else { return }
            MobileDiagnostics.shared.endFilePicker(reason: "view_removed", attemptId: activeAttemptId)
            picker.delegate = nil
            picker.presentationController?.delegate = nil
            if picker.presentingViewController != nil { picker.dismiss(animated: false) }
            self.picker = nil
            activeAttemptId = nil
        }
    }
}
