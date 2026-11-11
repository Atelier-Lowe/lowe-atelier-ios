//  LoweRoomPlan.swift
//  D'après expo-roomplan 1.3.1 (licence MIT, © 2025 fordat), adapté pour Löwe Atelier :
//  photos prises automatiquement pendant le scan (image + position du téléphone), libellés en français.

//  Licence d'origine (expo-roomplan) :
//  The MIT License (MIT)
//  Copyright © 2025
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//  
//  The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//  
//  THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation
import ExpoModulesCore
import ARKit
import CoreImage
import ImageIO
import RealityKit
import RoomPlan
import UIKit

@available(iOS 16.0, *)
class LoweCaptureViewController: UIViewController, RoomCaptureViewDelegate,
    RoomCaptureSessionDelegate
{
    private var roomCaptureView: RoomCaptureView!
    private var roomCaptureSessionConfig: RoomCaptureSession.Configuration =
        RoomCaptureSession.Configuration()
    private var isSessionRunning: Bool = false

    // Populated via the RoomCaptureViewDelegate review flow. This is the only
    // source of the final room on iOS 16, where RoomBuilder/StructureBuilder
    // don't exist; on iOS 17+ it's unused since we build from capturedRoomArray.
    private var finalResults: CapturedRoom?

    private var _finalStructure: Any?
    @available(iOS 17.0, *)
    private var finalStructure: CapturedStructure? {
        get { _finalStructure as? CapturedStructure }
        set { _finalStructure = newValue }
    }
    private var _structureBuilder: Any?
    @available(iOS 17.0, *)
    private var structureBuilder: StructureBuilder {
        if let existing = _structureBuilder as? StructureBuilder {
            return existing
        }
        let builder = StructureBuilder(options: [.beautifyObjects])
        _structureBuilder = builder
        return builder
    }

    var onDismiss: (([String: Any]) -> Void)?

    var scanName: String?
    var exportType: String?
    var sendFileLoc: Bool?
    var capturedRoomArray: [CapturedRoom] = []
    // Tracks whether the RoomBuilder Task kicked off by captureSession(_:didEndWith:)
    // is still running, so export can be deferred instead of racing it with a fixed timer.
    private var isBuildingRoom = false
    private var pendingExportAfterBuild = false

    // ---- Photos prises pendant le scan (Löwe) ----
    private var photoTimer: Timer?
    private var photos: [[String: Any]] = []
    private var lastPhotoPose: simd_float4x4?
    private var lastPhotoDate = Date.distantPast
    private let ciContext = CIContext(options: nil)
    private let maxPhotos = 45
    private lazy var photoDir: URL = {
        let d = FileManager.default.temporaryDirectory.appending(path: "LowePhotos-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private let photoLabel = UILabel()

    // UI elements
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    @IBOutlet var cancelButton: UIButton!
    @IBOutlet var finishButton: UIButton!
    @IBOutlet var anotherScanButton: UIButton!
    @IBOutlet var exportButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupRoomCaptureView()
        setupActivityIndicator()
    }

    private func setupActivityIndicator() {
        activityIndicator.center = self.view.center
        activityIndicator.hidesWhenStopped = true
        activityIndicator.color = UIColor.white
        view.addSubview(activityIndicator)
    }

    private func setupRoomCaptureView() {
        roomCaptureView = RoomCaptureView(frame: view.bounds)
        roomCaptureView?.captureSession.delegate = self
        // On iOS 17+, rooms are built from raw CapturedRoomData via RoomBuilder
        // (see captureSession(_:didEndWith:) below), so the view-level review
        // delegate is left unset to avoid double-presenting RoomPlan's own UI.
        // On iOS 16, RoomBuilder doesn't exist, so we rely on RoomPlan's built-in
        // review flow and capture the finished room via captureView(didPresent:).
        if #unavailable(iOS 17.0) {
            roomCaptureView?.delegate = self
        }
        view.insertSubview(roomCaptureView, at: 0)

        setupButtons()
        setupConstraints()
    }

    private func setupButtons() {
        // initialize and set up the finish button
        finishButton = UIButton()
        finishButton.translatesAutoresizingMaskIntoConstraints = false
        finishButton.setTitleColor(.white, for: .normal)
        finishButton.titleLabel?.textAlignment = .center
        finishButton.titleLabel?.numberOfLines = 0
        finishButton.titleLabel?.font = UIFont.systemFont(
            ofSize: 16,
            weight: .bold
        )
        finishButton.setTitle("Terminer", for: .normal)

        // Finish should either stop scanning (if running) or confirm exit (if post-scan)
        finishButton.addTarget(
            self,
            action: #selector(finishTapped),
            for: .touchUpInside
        )

        // add the label on top of roomCaptureView
        view.addSubview(finishButton)

        // initialize and set up the cancel button
        cancelButton = UIButton()
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.textAlignment = .center
        cancelButton.titleLabel?.numberOfLines = 0
        cancelButton.titleLabel?.font = UIFont.systemFont(
            ofSize: 16,
            weight: .bold
        )
        cancelButton.setTitle("Annuler", for: .normal)
        // round corners
        cancelButton.layer.masksToBounds = true
        cancelButton.layer.cornerRadius = 5

        // add the action for button press
        cancelButton.addTarget(
            self,
            action: #selector(cancelSession),
            for: .touchUpInside
        )

        // add the label on top of roomCaptureView
        view.addSubview(cancelButton)

        // compteur de photos prises pendant le scan
        photoLabel.translatesAutoresizingMaskIntoConstraints = false
        photoLabel.textColor = .white
        photoLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        photoLabel.textAlignment = .center
        photoLabel.text = "📷 0"
        view.addSubview(photoLabel)
        NSLayoutConstraint.activate([
            photoLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            photoLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
        ])
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            finishButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 10
            ),
            finishButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -20
            ),
            finishButton.widthAnchor.constraint(equalToConstant: 80),
            finishButton.heightAnchor.constraint(equalToConstant: 30),

            cancelButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 10
            ),
            cancelButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 20
            ),
            cancelButton.widthAnchor.constraint(equalToConstant: 80),
            cancelButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func setupPostScanUI() {
        let supportsAddAnotherRoom: Bool
        if #available(iOS 17.0, *) {
            supportsAddAnotherRoom = true
        } else {
            supportsAddAnotherRoom = false
        }

        // initialize and set up the export button
        exportButton = UIButton()
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.setTitleColor(.white, for: .normal)
        exportButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        exportButton.titleLabel?.textAlignment = .center
        exportButton.titleLabel?.numberOfLines = 0
        exportButton.titleLabel?.font = UIFont.systemFont(
            ofSize: 16,
            weight: .bold
        )
        exportButton.setTitle("Valider le scan", for: .normal)  // text
        // round corners
        exportButton.layer.masksToBounds = true
        exportButton.layer.cornerRadius = 15

        exportButton.addTarget(
            self,
            action: #selector(superExportResults),
            for: .touchUpInside
        )

        var stackedButtons: [UIButton] = [exportButton]

        if supportsAddAnotherRoom {
            anotherScanButton = UIButton()
            anotherScanButton.translatesAutoresizingMaskIntoConstraints = false
            anotherScanButton.setTitleColor(.white, for: .normal)
            anotherScanButton.backgroundColor = UIColor.black.withAlphaComponent(
                0.6
            )
            anotherScanButton.titleLabel?.textAlignment = .center
            anotherScanButton.titleLabel?.numberOfLines = 0
            anotherScanButton.titleLabel?.font = UIFont.systemFont(
                ofSize: 16,
                weight: .bold
            )
            anotherScanButton.setTitle("Scanner une autre pièce", for: .normal)  // text
            // round corners
            anotherScanButton.layer.masksToBounds = true
            anotherScanButton.layer.cornerRadius = 15

            anotherScanButton.addTarget(
                self,
                action: #selector(restartSession),
                for: .touchUpInside
            )

            stackedButtons.append(anotherScanButton)
        }

        let buttonStack = UIStackView(arrangedSubviews: stackedButtons)
        buttonStack.axis = .vertical
        buttonStack.spacing = 16
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonStack)

        // alter text on cancel buttons
        UIView.transition(
            with: cancelButton,
            duration: 0.5,
            options: .transitionCrossDissolve,
            animations: {
                self.cancelButton.backgroundColor = UIColor.black
                    .withAlphaComponent(0.6)  // make button background visible
            },
            completion: nil
        )
        // Keep Finish active; it will now confirm exit when no session is running.

        var buttonConstraints = [
            exportButton.heightAnchor.constraint(equalToConstant: 50)
        ]
        if supportsAddAnotherRoom {
            buttonConstraints.append(
                anotherScanButton.heightAnchor.constraint(equalToConstant: 50)
            )
        }

        NSLayoutConstraint.activate(buttonConstraints + [
            buttonStack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: 20
            ),
            buttonStack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -20
            ),
            buttonStack.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -40
            ),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ flag: Bool) {
        super.viewWillDisappear(flag)
        stopPhotos()
        stopSession()
    }

    @IBAction func superExportResults(_ sender: Any) {
        // disable buttons after pressing upload
        exportButton.isEnabled = false
        exportButton.removeTarget(
            self,
            action: #selector(superExportResults),
            for: .touchUpInside
        )
        // Also disable Finish to avoid exiting mid-export
        finishButton.isEnabled = false
        if let anotherScanButton {
            anotherScanButton.isEnabled = false
            anotherScanButton.removeTarget(
                self,
                action: #selector(restartSession),
                for: .touchUpInside
            )
        }
        UIView.animate(withDuration: 0.5) {
            self.anotherScanButton?.backgroundColor = UIColor.white
            self.exportButton.backgroundColor = UIColor.white
        }

        if #available(iOS 17.0, *) {
          roomCaptureView?.captureSession.stop(pauseARSession: false)
        } else {
          roomCaptureView?.captureSession.stop()
        }

        // create a white overlay view that covers the entire screen
        let overlayView = UIView(frame: self.view.bounds)
        overlayView.backgroundColor = UIColor.white
        overlayView.alpha = 1
        overlayView.tag = 999

        // add the overlay above the roomCaptureView but below other UI elements
        self.view.insertSubview(overlayView, aboveSubview: roomCaptureView!)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if self.isBuildingRoom {
                // Last room's RoomBuilder Task hasn't finished appending to
                // capturedRoomArray yet; defer export until it does instead of
                // racing it and handing StructureBuilder an incomplete array.
                print("[RoomPlan] Room build still in flight; deferring export.")
                self.pendingExportAfterBuild = true
                // Safety net: if didEndWith/RoomBuilder never completes (or takes
                // far longer than expected), don't hang forever with no feedback.
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    guard self.pendingExportAfterBuild else { return }
                    self.pendingExportAfterBuild = false
                    self.isBuildingRoom = false
                    print("[RoomPlan] Timed out waiting for room data to finish processing.")
                    self.sendScanResultAndDismiss(
                        status: .Error,
                        errorMessage: "Le scan met trop de temps à se terminer. Réessayez."
                    )
                }
            } else {
                self.exportResults()
            }
        }
    }

    func exportResults() {
        let exportedScanName = scanName ?? "Room"

        let destinationFolderURL = FileManager.default.temporaryDirectory
            .appending(path: "Export")
        let destinationURL = destinationFolderURL.appending(path: "\(exportedScanName).usdz")
        let capturedRoomURL = destinationFolderURL.appending(path: "\(exportedScanName).json")

        // UI responsiveness, disable cancel button
        cancelButton.removeTarget(
            self,
            action: #selector(cancelSession),
            for: .touchUpInside
        )
        cancelButton.isEnabled = false
        UIView.transition(
            with: cancelButton,
            duration: 0.2,
            options: .transitionCrossDissolve,
            animations: {
                self.cancelButton.backgroundColor = UIColor.white
            },
            completion: nil
        )

        Task {
            do {
                try FileManager.default.createDirectory(
                    at: destinationFolderURL,
                    withIntermediateDirectories: true
                )

                var finalExportType = CapturedRoom.USDExportOptions.parametric;

                if (exportType == "MESH") {
                    finalExportType = CapturedRoom.USDExportOptions.mesh;
                } else if (exportType == "MODEL") {
                    finalExportType = CapturedRoom.USDExportOptions.model;
                }

                let jsonEncoder = JSONEncoder()

                if #available(iOS 17.0, *) {
                    guard !capturedRoomArray.isEmpty else {
                        throw NSError(
                            domain: "ExpoRoomPlan",
                            code: 2,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Aucune pièce n'a été captée. Recommencez en balayant davantage les murs et le sol avant de terminer."
                            ]
                        )
                    }
                    finalStructure = try await structureBuilder.capturedStructure(
                        from: capturedRoomArray
                    )

                    let jsonData = try jsonEncoder.encode(finalStructure)
                    try jsonData.write(to: capturedRoomURL)
                    try finalStructure?.export(
                        to: destinationURL,
                        exportOptions: finalExportType
                    )

                    finalStructure = nil
                } else {
                    guard let room = finalResults else {
                        throw NSError(
                            domain: "ExpoRoomPlan",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Aucun scan à enregistrer."
                            ]
                        )
                    }

                    let jsonData = try jsonEncoder.encode(room)
                    try jsonData.write(to: capturedRoomURL)
                    try room.export(
                        to: destinationURL,
                        exportOptions: finalExportType
                    )
                }

                let shouldSendFileLoc = sendFileLoc ?? false

                if (shouldSendFileLoc) {
                    self.sendScanResultAndDismiss(status: .OK, scanUrl: destinationURL.absoluteString, jsonUrl: capturedRoomURL.absoluteString)
                    return
                }

                let activityVC = UIActivityViewController(
                    activityItems: [destinationFolderURL],
                    applicationActivities: nil
                )
                activityVC.modalPresentationStyle = .popover

                activityVC.completionWithItemsHandler = {
                    activityType,
                    completed,
                    returnedItems,
                    activityError in
                    self.sendScanResultAndDismiss(status: .OK)
                }

                if let popOver = activityVC.popoverPresentationController {
                    popOver.sourceView = self.exportButton
                }

                present(activityVC, animated: true, completion: nil)

            } catch {
                print("[RoomPlan] ERROR MERGING")
                print("[RoomPlan] Error = \(error)")
                self.sendScanResultAndDismiss(status: .Error, errorMessage: error.localizedDescription)
                return
            }
        }
    }

    func sendScanResultAndDismiss(status: ScanStatus? = nil, scanUrl: String? = nil, jsonUrl: String? = nil, errorMessage: String? = nil) {
        var eventData: [String: Any] = [:]

        if let status = status {
            eventData["status"] = status.rawValue
        }

        if let jsonUrl = jsonUrl {
            eventData["jsonUrl"] = jsonUrl
        }

        if let scanUrl = scanUrl {
            eventData["scanUrl"] = scanUrl
        }

        if let errorMessage = errorMessage {
            eventData["errorMessage"] = errorMessage
        }

        if status == .OK, let pj = writePhotosJson() {
            eventData["photosUrl"] = pj
        }

        // Send the unified event
        onDismiss?(eventData)
        
        let dismissAction = {
            self.activityIndicator.stopAnimating()
            self.dismiss(animated: true, completion: nil)
        }
        
        // Handle timing and cleanup based on status
        if status == .OK {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.5,
                execute: dismissAction
            )
        } else {
            if #available(iOS 17.0, *) {
                finalStructure = nil
            }
            DispatchQueue.main.async(execute: dismissAction)
        }
    }

    public func startSession() {
        print("[RoomPlan] starting session")
        roomCaptureView?.captureSession.run(
            configuration: roomCaptureSessionConfig
        )
        isSessionRunning = true
        startPhotos()
    }

    // Prend une photo quand le téléphone a bougé (≥ 40 cm ou ≥ 18°) ou toutes les 4 s, au plus 45 photos.
    private func startPhotos() {
        photoTimer?.invalidate()
        photoTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in self?.maybeTakePhoto() }
    }
    private func stopPhotos() { photoTimer?.invalidate(); photoTimer = nil }

    private func maybeTakePhoto() {
        guard isSessionRunning, photos.count < maxPhotos,
              let frame = roomCaptureView?.captureSession.arSession.currentFrame else { return }
        guard case .normal = frame.camera.trackingState else { return }
        let T = frame.camera.transform
        let now = Date()
        if now.timeIntervalSince(lastPhotoDate) < 0.9 { return }
        if let L = lastPhotoPose {
            let d = simd_distance(simd_make_float3(T.columns.3), simd_make_float3(L.columns.3))
            let f1 = simd_normalize(simd_make_float3(T.columns.2)), f0 = simd_normalize(simd_make_float3(L.columns.2))
            let ang = acos(max(-1, min(1, simd_dot(f1, f0))))
            if d < 0.4 && ang < 0.31 && now.timeIntervalSince(lastPhotoDate) < 4 { return }
        }
        lastPhotoPose = T; lastPhotoDate = now
        let K = frame.camera.intrinsics, res = frame.camera.imageResolution
        let scale = 1280.0 / Double(max(res.width, res.height))
        let img = CIImage(cvPixelBuffer: frame.capturedImage).transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        let idx = photos.count
        let url = photoDir.appending(path: String(format: "p%03d.jpg", idx))
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let data = ciContext.jpegRepresentation(of: img, colorSpace: cs, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.62]) else { return }
        do { try data.write(to: url) } catch { return }
        var m: [Float] = []
        for c in 0..<4 { let col = T[c]; m += [col.x, col.y, col.z, col.w] }
        photos.append([
            "file": url.absoluteString,
            "w": Int((Double(res.width) * scale).rounded()), "h": Int((Double(res.height) * scale).rounded()),
            "fx": Double(K[0][0]) * scale, "fy": Double(K[1][1]) * scale,
            "cx": Double(K[2][0]) * scale, "cy": Double(K[2][1]) * scale,
            "T": m, "t": now.timeIntervalSince1970
        ])
        photoLabel.text = "📷 \(photos.count)"
    }

    private func writePhotosJson() -> String? {
        guard !photos.isEmpty else { return nil }
        let url = photoDir.appending(path: "photos.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: ["v": 1, "photos": photos], options: [])
            try data.write(to: url)
            return url.absoluteString
        } catch { return nil }
    }

    @IBAction func restartSession() {
        print("[RoomPlan] restarting session")
        exportButton.removeFromSuperview()
        anotherScanButton?.removeFromSuperview()
        roomCaptureView?.captureSession.run(
            configuration: roomCaptureSessionConfig
        )
        isSessionRunning = true
        startPhotos()
        UIView.transition(
            with: cancelButton,
            duration: 0.5,
            options: .transitionCrossDissolve,
            animations: {
                self.cancelButton.backgroundColor = UIColor.black
                    .withAlphaComponent(0)  // make button background invisible again
            },
            completion: nil
        )
        // finishButton remains bound to finishTapped
        finishButton.isEnabled = true
    }

    @objc
    public func stopSession() {
        // A didEndWith callback (and its RoomBuilder Task) is guaranteed to follow
        // this stop() call, so mark the build as in-flight now rather than waiting
        // for didEndWith to fire — otherwise a fast export tap can race the gap
        // between calling stop() and the delegate callback actually arriving.
        if #available(iOS 17.0, *) {
            isBuildingRoom = true
            roomCaptureView?.captureSession.stop(pauseARSession: false)
        } else {
            roomCaptureView?.captureSession.stop()
        }
        isSessionRunning = false
        stopPhotos()
        setupPostScanUI()
    }

    @objc
    private func finishTapped() {
        if isSessionRunning {
            // Current behavior during scanning: stop the session and show post-scan UI
            stopSession()
        } else {
            // Post-scan (or no active session): confirm finishing and exit the view
            let alertController = UIAlertController(
                title: "Fermer le scanner ?",
                message:
                    "Touchez « Valider le scan » pour garder ce scan, ou fermez sans l'enregistrer.",
                preferredStyle: .alert
            )

            let confirmAction = UIAlertAction(title: "Fermer", style: .destructive) { _ in
                self.sendScanResultAndDismiss(status: .OK)
            }
            alertController.addAction(confirmAction)

            let cancelAction = UIAlertAction(title: "Continuer", style: .cancel, handler: nil)
            alertController.addAction(cancelAction)

            self.present(alertController, animated: true, completion: nil)
        }
    }

    @objc
    func cancelSession() {
        let alertController = UIAlertController(
            title: "Annuler le scan ?",
            message:
                "Le scan en cours sera perdu.",
            preferredStyle: .alert
        )

        let confirmAction = UIAlertAction(title: "Annuler le scan", style: .destructive)
        { action in
            if #available(iOS 17.0, *) {
                self.finalStructure = nil
            }
            self.sendScanResultAndDismiss(status: .Canceled)
        }
        alertController.addAction(confirmAction)

        let cancelAction = UIAlertAction(
            title: "Continuer",
            style: .cancel,
            handler: nil
        )
        alertController.addAction(cancelAction)

        self.present(alertController, animated: true, completion: nil)
    }

    @objc
    static func requiresMainQueueSetup() -> Bool {
        return true
    }
}

@available(iOS 17.0, *)
extension LoweCaptureViewController {
    func captureSession(_ session: RoomCaptureSession, didUpdate: CapturedRoom)
    {
        print("[RoomPlan] didUpdate", didUpdate.objects.count)
    }

    func captureSession(_ session: RoomCaptureSession, didChange: CapturedRoom)
    {
        print("[RoomPlan] didChange", didChange.objects.count)
    }
}

@available(iOS 16.0, *)
extension LoweCaptureViewController {
    // captureSession(_:didEndWith:error:) is a base RoomCaptureSessionDelegate
    // requirement present since iOS 16 (unlike didUpdate/didChange above, which
    // are iOS 17+ additions for multi-room support). It must live at the same
    // availability floor as the class's own protocol conformance — nesting it
    // inside an @available(iOS 17.0, *) extension left it mismatched with the
    // class's iOS 16 floor, which meant it was never wired up as the delegate
    // callback at all and silently never fired.
    func captureSession(
        _ session: RoomCaptureSession,
        didEndWith: CapturedRoomData,
        error: (any Error)?
    ) {
        if let error {
            print("[RoomPlan] Session ended with error: \(error.localizedDescription)")
        }
        print("[RoomPlan] didEndWith")
        guard #available(iOS 17.0, *) else { return }
        let roomBuilder = RoomBuilder(options: [.beautifyObjects])
        isBuildingRoom = true
        Task {
            do {
                let capturedRoom = try await roomBuilder.capturedRoom(
                    from: didEndWith
                )
                print("[RoomPlan] Appending new captured room")
                self.capturedRoomArray.append(capturedRoom)
            } catch {
                print("[RoomPlan] Failed to build captured room: \(error.localizedDescription)")
            }
            await MainActor.run {
                self.isBuildingRoom = false
                if self.pendingExportAfterBuild {
                    self.pendingExportAfterBuild = false
                    self.exportResults()
                }
            }
        }
    }

    func captureView(
        shouldPresent roomDataForProcessing: CapturedRoomData,
        error: Error?
    ) -> Bool {
        return true
    }

    // access the final results
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        finalResults = processedResult
    }
}


enum ScanStatus: String {
  case NotStarted
  case Canceled
  case Error
  case OK
}


// Module « LoweRoomPlan » : scan RoomPlan + photos (voir LoweCaptureViewController.swift)
public class LoweRoomPlanModule: Module {
    private var captureViewController: LoweCaptureViewController?

    public func definition() -> ModuleDefinition {
        Name("LoweRoomPlan")

        Events("onDismissEvent")

        AsyncFunction("startCapture") { (scanName: String, exportType: String, sendFileLoc: Bool) in
            DispatchQueue.main.async {
                let captureVC = LoweCaptureViewController()
                captureVC.scanName = scanName
                captureVC.modalPresentationStyle = .fullScreen
                captureVC.exportType = exportType
                captureVC.sendFileLoc = sendFileLoc
                captureVC.onDismiss = { eventData in
                    self.sendEvent("onDismissEvent", eventData)
                }
                guard let rootVC = UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
                    .first?.rootViewController else { return }
                var top = rootVC
                while let p = top.presentedViewController { top = p }
                top.present(captureVC, animated: true, completion: nil)
                self.captureViewController = captureVC
            }
        }

        AsyncFunction("stopCapture") {
            DispatchQueue.main.async {
                self.captureViewController?.stopSession()
                self.captureViewController?.dismiss(animated: true, completion: nil)
            }
        }
    }
}
