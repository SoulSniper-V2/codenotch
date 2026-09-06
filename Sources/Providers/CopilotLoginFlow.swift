import AppKit
import Foundation

/// Presents the GitHub OAuth Device Flow to the user.
///
/// 1. Requests a device code from GitHub.
/// 2. Copies the one-time user code to the system clipboard.
/// 3. Prompts the user to open GitHub in their browser and paste the code.
/// 4. Polls for the authorization token in the background while displaying a cancellable waiting sheet.
/// 5. Stores the resulting token in `SecretStore` and posts a refresh notification.
@MainActor
enum CopilotLoginFlow {
    static func run() {
        Task { @MainActor in
            await start()
        }
    }

    private static func start() async {
        let flow = CopilotDeviceFlow()

        let code: CopilotDeviceFlow.DeviceCodeResponse
        do {
            code = try await flow.requestDeviceCode()
        } catch {
            let err = NSAlert()
            err.messageText = "GitHub Copilot Sign In Failed"
            err.informativeText = "Unable to initiate GitHub device authorization: \(error.localizedDescription)"
            err.addButton(withTitle: "OK")
            err.runModal()
            return
        }

        // Copy code to system clipboard
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code.userCode, forType: .string)

        // Initial alert showing code and prompt to open browser
        let initialAlert = NSAlert()
        initialAlert.messageText = "Sign in to GitHub Copilot"
        initialAlert.informativeText =
            "Your one-time device code has been copied to your clipboard:\n\n"
            + "    \(code.userCode)\n\n"
            + "Click 'Open Browser' to go to GitHub, paste the code into the verification page, and authorize Codenotch."
        initialAlert.addButton(withTitle: "Open Browser")
        initialAlert.addButton(withTitle: "Cancel")

        let response = initialAlert.runModal()
        guard response == .alertFirstButtonReturn else {
            return // User cancelled
        }

        if let url = URL(string: code.verificationURLToOpen) {
            NSWorkspace.shared.open(url)
        }

        // Prepare waiting alert
        let waitingAlert = NSAlert()
        waitingAlert.messageText = "Waiting for GitHub Authorization…"
        waitingAlert.informativeText =
            "Device code: \(code.userCode) (copied to clipboard)\n\n"
            + "Complete authorization in your browser. Codenotch will automatically detect when you are finished."
        waitingAlert.addButton(withTitle: "Cancel")

        let parentWindow = resolveParentWindow()
        let hostWindow = parentWindow ?? makeHostWindow()
        let shouldCloseHost = parentWindow == nil

        let tokenTask = Task.detached(priority: .userInitiated) {
            try await flow.pollForToken(deviceCode: code.deviceCode, interval: code.interval)
        }

        let waitTask = Task { @MainActor in
            await presentWaitingAlert(waitingAlert, parentWindow: hostWindow)
        }

        let tokenResult: Result<String, Error>
        do {
            let token = try await tokenTask.value
            tokenResult = .success(token)
        } catch {
            tokenResult = .failure(error)
        }

        dismissWaitingAlert(waitingAlert, parentWindow: hostWindow, closeHost: shouldCloseHost)
        _ = await waitTask.value

        switch tokenResult {
        case .success(let token):
            // Save token to SecretStore
            SecretStore.save(token, id: "copilot")

            var loginName: String? = nil
            if let user = try? await flow.fetchUser(token: token) {
                loginName = user.login
            }

            // Trigger immediate refresh across the app
            NotificationCenter.default.post(
                name: NSNotification.Name("CodenotchRefreshProvider"),
                object: "copilot"
            )

            let success = NSAlert()
            success.messageText = "GitHub Copilot Connected"
            if let loginName {
                success.informativeText = "Successfully authenticated as @\(loginName). Quota readings will now appear in your notch."
            } else {
                success.informativeText = "Successfully authenticated with GitHub Copilot. Quota readings will now appear in your notch."
            }
            success.addButton(withTitle: "Done")
            success.runModal()

        case .failure(let error):
            guard !(error is CancellationError) else { return }
            let err = NSAlert()
            err.messageText = "Authentication Incomplete"
            err.informativeText = error.localizedDescription
            err.addButton(withTitle: "OK")
            err.runModal()
        }
    }

    private static func presentWaitingAlert(
        _ alert: NSAlert,
        parentWindow: NSWindow
    ) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: parentWindow) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private static func dismissWaitingAlert(
        _ alert: NSAlert,
        parentWindow: NSWindow,
        closeHost: Bool
    ) {
        let alertWindow = alert.window
        if alertWindow.sheetParent != nil {
            parentWindow.endSheet(alertWindow)
        } else {
            alertWindow.orderOut(nil)
        }
        if closeHost {
            parentWindow.orderOut(nil)
            parentWindow.close()
        }
    }

    private static func resolveParentWindow() -> NSWindow? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return window
        }
        return NSApp.windows.first { $0.isVisible && !$0.ignoresMouseEvents }
    }

    private static func makeHostWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 1),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
