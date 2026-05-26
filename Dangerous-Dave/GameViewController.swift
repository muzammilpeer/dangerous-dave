//
//  GameViewController.swift
//  Dave1
//

import Cocoa
import MetalKit

class GameViewController: NSViewController {

    private var renderer: Renderer!
    private var mtkView: MTKView!
    private var keyMonitor: Any?
    private var hasPresentedPlayerNamePrompt = false
    private let hudLabel = NSTextField(labelWithString: "")

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let mtkView = self.view as? MTKView else {
            print("View attached to GameViewController is not an MTKView")
            return
        }

        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported on this device")
            return
        }

        self.mtkView = mtkView
        mtkView.device = defaultDevice
        mtkView.preferredFramesPerSecond = 60
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false

        guard let newRenderer = Renderer(metalKitView: mtkView) else {
            print("Renderer cannot be initialized")
            return
        }

        renderer = newRenderer
        renderer.statusHandler = { [weak self] status in
            self?.hudLabel.stringValue = status
        }

        configureHUD()
        installKeyboardMonitor()

        renderer.mtkView(mtkView, drawableSizeWillChange: mtkView.drawableSize)
        mtkView.delegate = renderer
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
        promptForPlayerNameIfNeeded()
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
    }

    private func configureHUD() {
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        hudLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        hudLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.18, alpha: 1.0)
        hudLabel.backgroundColor = NSColor(calibratedRed: 0.05, green: 0.025, blue: 0.015, alpha: 0.82)
        hudLabel.drawsBackground = true
        hudLabel.isBordered = false
        hudLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(hudLabel)

        NSLayoutConstraint.activate([
            hudLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            hudLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            hudLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            hudLabel.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func promptForPlayerNameIfNeeded() {
        let key = "Dave1.hasConfirmedPlayerName"
        let hasConfirmedName = UserDefaults.standard.bool(forKey: key)
        guard !hasConfirmedName, !hasPresentedPlayerNamePrompt, let window = view.window else { return }
        hasPresentedPlayerNamePrompt = true

        let alert = NSAlert()
        alert.messageText = "Player Name"
        alert.informativeText = "Enter the name saved with your high score."
        alert.addButton(withTitle: "Start")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        textField.stringValue = Renderer.savedPlayerNameForPrompt()
        alert.accessoryView = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.renderer.setPlayerName(textField.stringValue)
                UserDefaults.standard.set(true, forKey: key)
            }
            self.view.window?.makeFirstResponder(self.view)
        }
    }

    private func installKeyboardMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window === self.view.window else { return event }

            let isPressed = event.type == .keyDown
            if isPressed && event.isARepeat {
                return nil
            }

            switch Int(event.keyCode) {
            case 0, 123:
                self.renderer.setKey(.left, isPressed: isPressed)
            case 2, 124:
                self.renderer.setKey(.right, isPressed: isPressed)
            case 1, 45, 125:
                self.renderer.setKey(.down, isPressed: isPressed)
            case 13, 126, 49:
                self.renderer.setKey(.jump, isPressed: isPressed)
            case 3:
                self.renderer.setKey(.shoot, isPressed: isPressed)
            case 15:
                if isPressed { self.renderer.restartCurrentLevel() }
            case 35:
                self.renderer.setKey(.pause, isPressed: isPressed)
            case 46:
                self.renderer.setKey(.settings, isPressed: isPressed)
            default:
                return event
            }

            return nil
        }
    }
}
