/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Main view controller for the AR experience.
*/

import UIKit
import SceneKit
import ARKit

class ViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {
    // MARK: - IBOutlets
    
    @IBOutlet weak var sessionInfoView: UIView!
    @IBOutlet weak var sessionInfoLabel: UILabel!
    @IBOutlet weak var sceneView: ARSCNView!
    @IBOutlet weak var saveExperienceButton: UIButton!
    @IBOutlet weak var decorationModeButton: UIButton!
    @IBOutlet weak var discardDecorButton: UIButton!
    @IBOutlet weak var removeAllWorldsButton: UIButton!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var snapshotThumbnail: UIImageView!
    
    var worldName: String = ""
    var gameName: String = "dragon-game"
    var saveFileExtension: String = ".arexperience"
    var isInDecorationMode: Bool = false
    var worldHasBeenSaved: Bool = false
    var isCreatingNewWorld: Bool = false
    var isRelocalizing: Bool = false
    var worldHasLoaded: Bool = false
    var initLock = NSLock()

    // MARK: - View Life Cycle
    
    // Lock the orientation of the app to the orientation in which it is launched
    override var shouldAutorotate: Bool {
        return false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Read in any already saved map to see if we can load one.
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        guard ARWorldTrackingConfiguration.isSupported else {
            fatalError("""
                ARKit is not available on this device. For apps that require ARKit
                for core functionality, use the `arkit` key in the key in the
                `UIRequiredDeviceCapabilities` section of the Info.plist to prevent
                the app from installing. (If the app can't be installed, this error
                can't be triggered in a production scenario.)
                In apps where AR is an additive feature, use `isSupported` to
                determine whether to show UI for launching AR experiences.
            """) // For details, see https://developer.apple.com/documentation/arkit
        }

        // Start the view's AR session.

        exitDecorationMode()
        self.decorationModeButton.isHidden = true
//        removeAllSavedWorlds()

        let savedWorldNames = readSavedWorldNames()
        if savedWorldNames.count == 0 {
            onboardNewUser()
        } else {
            selectWorldToLoad()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the view's AR session.
        sceneView.session.pause()
    }
    
    // MARK: - ARSCNViewDelegate
    
    /// - Tag: RestoreVirtualContent
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard anchor.name == virtualObjectAnchorName
            else { return }
        
        // save the reference to the virtual object anchor when the anchor is added from relocalizing
        if virtualObjectAnchor == nil {
            virtualObjectAnchor = anchor
        }
        node.addChildNode(virtualObject)
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState.description {
        case "Relocalizing":
            self.snapshotThumbnail.isHidden = false
            self.isRelocalizing = true
        default:
            self.snapshotThumbnail.isHidden = true
            if self.isRelocalizing && !self.worldHasLoaded {
                self.worldHasLoaded = true
                enterMainScene()
            }
        }
    }
    
    /// - Tag: CheckMappingStatus
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Enable Save button only when the mapping status is good and an object has been placed
        
        if self.worldName.count == 0 { return }
        
        initLock.lock()
        if self.isCreatingNewWorld && !self.worldHasBeenSaved {
            switch frame.worldMappingStatus {
            case .extending, .mapped:
                self.saveExperience(self.saveExperienceButton)
                self.enterMainScene()
            default:
                break
            }
        }
        initLock.unlock()

        if isInDecorationMode {
            switch frame.worldMappingStatus {
            case .extending, .mapped:
                saveExperienceButton.isEnabled =
                    virtualObjectAnchor != nil && frame.anchors.contains(virtualObjectAnchor!)
            default:
                saveExperienceButton.isEnabled = false
            }
        }
        statusLabel.text = """
        Translation: \(getCoordsString(transform: frame.camera.transform))
        Rotation: \(getRotationString(eulerAngles: frame.camera.eulerAngles))
        Tea Cup Position: \(virtualObjectAnchor == nil ? "" :
        getCoordsString(transform: virtualObjectAnchor!.transform))
        """
    }
    
    // MARK: - ARSessionObserver
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay.
        sessionInfoLabel.text = "Session was interrupted"
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required.
        sessionInfoLabel.text = "Session interruption ended"
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        sessionInfoLabel.text = "Session failed: \(error.localizedDescription)"
        guard error is ARError else { return }
        
        let errorWithInfo = error as NSError
        let messages = [
            errorWithInfo.localizedDescription,
            errorWithInfo.localizedFailureReason,
            errorWithInfo.localizedRecoverySuggestion
        ]
        
        // Remove optional error messages.
        let errorMessage = messages.compactMap({ $0 }).joined(separator: "\n")
        
        DispatchQueue.main.async {
            // Present an alert informing about the error that has occurred.
            let alertController = UIAlertController(title: "The AR session failed.", message: errorMessage, preferredStyle: .alert)
            let restartAction = UIAlertAction(title: "Restart Session", style: .default) { _ in
                alertController.dismiss(animated: true, completion: nil)
                self.resetTracking(nil)
            }
            alertController.addAction(restartAction)
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        return true
    }
    
    func getSaveURL(name: String) -> URL {
        return {
            do {
                return try FileManager.default
                    .url(for: .documentDirectory,
                         in: .userDomainMask,
                         appropriateFor: nil,
                         create: true)
                    .appendingPathComponent(name + saveFileExtension)
            } catch {
                fatalError("Can't get file save URL: \(error.localizedDescription)")
            }
        }()
    }
    
    // MARK: - Persistence: Saving and Loading
    
    func readSavedWorldNames() -> Array<String> {
        let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        do {
            let savedWorldFiles = try FileManager.default.contentsOfDirectory(at: documentsUrl, includingPropertiesForKeys: nil).filter{ $0.pathExtension == "arexperience" }
            return savedWorldFiles.map{ $0.deletingPathExtension().lastPathComponent }
        } catch {
            fatalError("Can't load saved worlds")
        }
    }
    
    /// - Tag: GetWorldMap
    @IBAction func saveExperience(_ button: UIButton) {
        print(self.worldName)
        sceneView.session.getCurrentWorldMap { worldMap, error in
            guard let map = worldMap
                else { self.showAlert(title: "Can't get current world map", message: error!.localizedDescription); return }

            // Add a snapshot image indicating where the map was captured.
            guard let snapshotAnchor = SnapshotAnchor(capturing: self.sceneView)
                else { fatalError("Can't take snapshot") }
            map.anchors.append(snapshotAnchor)
            
            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                try data.write(to: self.getSaveURL(name: self.worldName), options: [.atomic])
            } catch {
                fatalError("Can't save map: \(error.localizedDescription)")
            }
        }
        exitDecorationMode()
    }
    
    @IBAction func enterDecorationMode(_ button: UIButton) {
        isInDecorationMode = true
        saveExperienceButton.isHidden = false
        discardDecorButton.isHidden = false
        discardDecorButton.isEnabled = true
    }

    @IBAction func exitDecorationMode() {
        decorationModeButton.isHidden = false
        saveExperienceButton.isHidden = true
        isInDecorationMode = false
        discardDecorButton.isHidden = true
        discardDecorButton.isEnabled = false
    }
    
    @IBAction func discardDecoration() {
        loadExperience()
        exitDecorationMode()
    }
    
    // Called opportunistically to verify that map data can be loaded from filesystem.
    var mapDataFromFile: Data? {
        return try? Data(contentsOf: self.getSaveURL(name: self.worldName))
    }
    
    /// - Tag: RunWithWorldMap
    func loadExperience() {
        
        /// - Tag: ReadWorldMap
        let worldMap: ARWorldMap = {
            guard let data = mapDataFromFile
                else { fatalError("Map data should already be verified to exist before Load button is enabled.") }
            do {
                guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
                    else { fatalError("No ARWorldMap in archive.") }
                return worldMap
            } catch {
                fatalError("Can't unarchive ARWorldMap from file data: \(error)")
            }
        }()

        // Display the snapshot image stored in the world map to aid user in relocalizing.
        if let snapshotData = worldMap.snapshotAnchor?.imageData,
            let snapshot = UIImage(data: snapshotData) {
            self.snapshotThumbnail.image = snapshot
        } else {
            print("No snapshot image in world map")
        }
        
        // Remove the snapshot anchor from the world map since we do not need it in the scene.
        worldMap.anchors.removeAll(where: { $0 is SnapshotAnchor })
        
        let configuration = self.defaultConfiguration // this app's standard world tracking settings
        configuration.initialWorldMap = worldMap
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        isRelocalizingMap = true
        virtualObjectAnchor = nil
    }

    // MARK: - AR session management
    
    var isRelocalizingMap = false

    var defaultConfiguration: ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = .horizontal
        configuration.environmentTexturing = .automatic
        return configuration
    }
    
    @IBAction func resetTracking(_ sender: UIButton?) {
        sceneView.session.run(defaultConfiguration, options: [.resetTracking, .removeExistingAnchors])

        isRelocalizingMap = false
        virtualObjectAnchor = nil
    }

    // MARK: - Placing AR Content
    
    /// - Tag: PlaceObject
    @IBAction func handleSceneTap(_ sender: UITapGestureRecognizer) {
        // Disable placing objects when the session is still relocalizing
        if !isInDecorationMode {
            return
        }
        if isRelocalizingMap && virtualObjectAnchor == nil {
            return
        }
        // Hit test to find a place for a virtual object.
        guard let hitTestResult = sceneView
            .hitTest(sender.location(in: sceneView), types: [.existingPlaneUsingGeometry, .estimatedHorizontalPlane])
            .first
            else {
                return
            }

        // Remove exisitng anchor and add new anchor
        if let existingAnchor = virtualObjectAnchor {
            sceneView.session.remove(anchor: existingAnchor)
        }
        virtualObjectAnchor = ARAnchor(name: virtualObjectAnchorName, transform: hitTestResult.worldTransform)
        sceneView.session.add(anchor: virtualObjectAnchor!)
    }

    var virtualObjectAnchor: ARAnchor?
    let virtualObjectAnchorName = "virtualObject"

    var virtualObject: SCNNode = {
        guard let sceneURL = Bundle.main.url(forResource: "cup", withExtension: "scn", subdirectory: "Assets.scnassets/cup"),
            let referenceNode = SCNReferenceNode(url: sceneURL) else {
                fatalError("can't load virtual object")
        }
        referenceNode.load()
        
        return referenceNode
    }()
    
    func removeSavedWorldByName(name: String) {
        let fileManager = FileManager.default
        let dirPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as NSString
        let filePath = dirPath.appendingPathComponent(name + self.saveFileExtension)
        try! fileManager.removeItem(atPath: filePath)
    }

    @IBAction func removeAllSavedWorlds() {
        for name in readSavedWorldNames() {
            removeSavedWorldByName(name: name)
        }
    }

    func onboardNewUser() {
        self.isCreatingNewWorld = true
        let alert = UIAlertController(title: "Welcome to \(gameName)! Please name your world.",
            message: "", preferredStyle: .alert)
        let defaultName = "DK's Forest"
        alert.addTextField { (textField) in textField.placeholder = defaultName }
        alert.addAction(UIAlertAction(title: "Confirm", style: .default, handler: { [weak alert] (_) in
            guard let textField = alert?.textFields?[0], let userText = textField.text else { return }
            self.worldName = userText.count > 0 ? userText : defaultName
            print(self.worldName)
            self.worldHasBeenSaved = false
            self.sessionInfoLabel.text = "The World has not been saved. Move your camera around."
            self.sceneView.debugOptions = [ .showFeaturePoints ]
            
            self.decorationModeButton.isHidden = true
            self.runSession()
        }))
    
        self.present(alert, animated: true, completion: nil)
    }

    func selectWorldToLoad() {
        let savedWorlds = readSavedWorldNames()
        let alert = UIAlertController(title: "Welcome back to \(gameName)! Please select a world to load, or start a new world by entering 'New'.",
        message: "", preferredStyle: .alert)
        let defaultText = savedWorlds[0]
        print(savedWorlds)
        alert.addTextField { (textField) in textField.placeholder = defaultText }
        alert.addAction(UIAlertAction(title: "Confirm", style: .default, handler: { [weak alert] (_) in
            guard let textField = alert?.textFields?[0], let userText = textField.text else { return }
    
            let userEntry = userText.count > 0 ? userText : defaultText
            if userEntry == "New" {
                self.onboardNewUser()
            } else {
                for savedWorld in savedWorlds {
                    if userEntry == savedWorld {
                        self.worldName = userEntry
                        self.runSession()
                        self.loadExperience()
//                        self.enterMainScene()
                        break
                    }
                }
            }
        }))
        
        self.present(alert, animated: true, completion: nil)
    }

    func enterMainScene() {
        self.worldHasBeenSaved = true
        self.sceneView.debugOptions = []
        self.sessionInfoLabel.text = "Welcome to \(self.worldName)! Decorate your space or play a minigame."
        self.decorationModeButton.isHidden = false
    }
    
    func runSession() {
        sceneView.session.delegate = self
        sceneView.session.run(defaultConfiguration)

        // Prevent the screen from being dimmed after a while as users will likely
        // have long periods of interaction without touching the screen or buttons.
        UIApplication.shared.isIdleTimerDisabled = true
    }

}
