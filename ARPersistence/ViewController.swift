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
    @IBOutlet weak var exitDecorationModeButton: UIButton!
    @IBOutlet weak var nextObjectButton: UIButton!
    @IBOutlet weak var discardDecorButton: UIButton!
    @IBOutlet weak var removeAllWorldsButton: UIButton!
    @IBOutlet weak var statusLabel: UILabel!
    @IBOutlet weak var snapshotThumbnail: UIImageView!
    
    var worldName: String = ""
    var gameName: String = "dragon-game"
    var saveFileExtension: String = ".arexperience"
    
    var availableObjects: [String] = ["cup", "chair", "candle"]
    var dragonAnimations: [String] = ["run", "fly"]
    var currentObjectIndex: Int = 0
    
    var isInDecorationMode: Bool = false
    var worldHasBeenSaved: Bool = false
    var isCreatingNewWorld: Bool = false
    var isRelocalizing: Bool = false
    var worldHasLoaded: Bool = false
    var useRaycast: Bool = false
    var initLock = NSLock()
    
    var parentNode: SCNNode = SCNNode.init()
    
    var virtualObjectNodes: [SCNNode] = []
    var virtualObjectAnchors: [ARAnchor] = []
    var virtualPetNodes: [SCNNode] = []
    var virtualPetAnchors: [ARAnchor] = []
    var unsavedVirtualObjectIndices: [Int] = []
    var cameraTransform: simd_float4x4 = simd_float4x4.init()

    // MARK: - View Life Cycle
    
    // Lock the orientation of the app to the orientation in which it is launched
    override var shouldAutorotate: Bool {
        return true
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

        prepareMainScene()
        self.decorationModeButton.isHidden = true
//        removeAllSavedWorlds()

        let savedWorldNames = readSavedWorldNames()
        self.virtualObjectNodes = []
        if savedWorldNames.count == 0 {
            onboardNewUser()
        } else {
            selectWorldToLoad()
        }
        updateNextObjectButtonLabel()
        
        let anchorName = virtualPetAnchorName
        let virtualPetAnchor = ARAnchor(name: anchorName, transform: float4x4(SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, -0.2, 0, 1)))
        sceneView.session.add(anchor: virtualPetAnchor)
        
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Pause the view's AR session.
        sceneView.session.pause()
    }

    // MARK: - ARSCNViewDelegate

    /// - Tag: RestoreVirtualContent
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        if let name = anchor.name {
            if name.contains(virtualObjectAnchorName) {
                let nodeTypeIndex = Int(name.components(separatedBy: " ")[1])
                let newNode = getNewVirtualObjectInstance(index: nodeTypeIndex!)
                node.addChildNode(newNode)
                node.name = virtualObjectNodeName
                self.virtualObjectNodes.append(newNode)
                self.virtualObjectAnchors.append(anchor)
                guard self.virtualObjectAnchors.count == self.virtualObjectNodes.count else {
                    print("ERROR! COUNTS DON'T MATCH")
                    return
                }
                print(self.unsavedVirtualObjectIndices)
            } else if name == virtualPetAnchorName {
                self.parentNode = node
                let newNodes = getDragonAnimations()
                for newNode in newNodes {
                    node.addChildNode(newNode)
                    self.virtualPetNodes.append(newNode)
                }
                self.virtualPetAnchors.append(anchor)
                setPetAnimation(name: "fly")
            }
        }
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
            case .mapped:
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
                saveExperienceButton.isEnabled = true
            default:
                saveExperienceButton.isEnabled = false
            }
        }
        statusLabel.text = """
        Mapping: \(frame.worldMappingStatus.description)
        Tracking: \(frame.camera.trackingState.description)
        """

        let transform = frame.camera.transform.columns.3
        self.cameraTransform = float4x4(SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0), SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(transform.x, transform.y, transform.z, 1))
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
        self.unsavedVirtualObjectIndices = []
//        exitDecorationMode()
    }
    
    @IBAction func enterDecorationMode(_ button: UIButton) {
        isInDecorationMode = true
        saveExperienceButton.isHidden = false
        discardDecorButton.isHidden = false
        discardDecorButton.isEnabled = true
        decorationModeButton.isHidden = true
        exitDecorationModeButton.isHidden = false
        nextObjectButton.isHidden = false
    }

    @IBAction func exitDecorationMode() {
        discardDecoration()
        prepareMainScene()
    }
    
    @IBAction func discardDecoration() {
//        loadExperience()
        for index in self.unsavedVirtualObjectIndices.reversed() {
            let anchor = self.virtualObjectAnchors[index]
            let node = self.virtualObjectNodes[index]
            self.sceneView.session.remove(anchor: anchor)
            node.removeFromParentNode()
            self.virtualObjectAnchors.remove(at: index)
            self.virtualObjectNodes.remove(at: index)
        }
        self.unsavedVirtualObjectIndices = []
//        exitDecorationMode()
    }
    
    func removeNodeFromCache(node : SCNNode) {
        print(self.virtualObjectNodes.count)
        if let index = self.virtualObjectNodes.firstIndex(of: node) {
            self.virtualObjectNodes.remove(at: index)
        }
    }
    
    func prepareMainScene() {
        decorationModeButton.isHidden = false
        saveExperienceButton.isHidden = true
        isInDecorationMode = false
        discardDecorButton.isHidden = true
        discardDecorButton.isEnabled = false
        exitDecorationModeButton.isHidden = true
        nextObjectButton.isHidden = true
    }
    
    func setPetAnimation(name: String) -> SCNNode {
        let index = self.dragonAnimations.firstIndex(of: name)!
        for i in 0...self.virtualPetNodes.count - 1 {
            self.virtualPetNodes[i].removeFromParentNode()
        }
        parentNode.addChildNode(self.virtualPetNodes[index])
        return self.virtualPetNodes[index]
    }
    
    func movePet(transform: simd_float4x4) {
        print(parentNode.childNodes)
        let runNode = setPetAnimation(name: "run")
        print(parentNode.childNodes)
        SCNTransaction.animationDuration = 3.0
        runNode.simdTransform = transform
        runNode.simdScale = SIMD3<Float>(0.2, 0.2, 0.2)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let flyNode = self.setPetAnimation(name: "fly")
            print(self.parentNode.childNodes)
            SCNTransaction.animationDuration = 0
            flyNode.simdTransform = transform
            flyNode.simdScale = SIMD3<Float>(0.2, 0.2, 0.2)
        }
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
        self.virtualObjectNodes = []
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

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
    }

    // MARK: - Placing AR Content
    
    /// - Tag: PlaceObject
    @IBAction func handleSceneTap(_ sender: UITapGestureRecognizer) {
        // Disable placing objects when the session is still relocalizing
        if isInDecorationMode {
            // Hit test to find a place for a virtual object.
            guard let transform = useRaycast ? sceneView
                .hitTest(sender.location(in: sceneView), types: [.existingPlaneUsingGeometry, .estimatedHorizontalPlane])
                .first?.worldTransform : self.cameraTransform
                else {
                    return
                }

            // Remove exisitng anchor and add new anchor
    //        if let existingAnchor = virtualObjectAnchor {
    //            sceneView.session.remove(anchor: existingAnchor)
    //        }
            let anchorName = virtualObjectAnchorName + String(self.virtualObjectNodes.count) +
                " " + String(currentObjectIndex)
            let virtualObjectAnchor = ARAnchor(name: anchorName, transform: transform)
            sceneView.session.add(anchor: virtualObjectAnchor)
            self.unsavedVirtualObjectIndices.append(self.virtualObjectNodes.count)
        }
        else {
            guard let transform = sceneView
                .hitTest(sender.location(in: sceneView), types: [.existingPlaneUsingGeometry, .estimatedHorizontalPlane])
                .first?.worldTransform
                else {
                    return
                }

            print(self.virtualPetNodes.count)
            if self.virtualPetNodes.count > 0 {
                movePet(transform: transform)
            }
        }
    }

//    var virtualObjectAnchor: ARAnchor?
    let virtualObjectAnchorName = "VirtualObjectAnchor"
    let virtualObjectNodeName = "VirtualObjectNode"
    
    let virtualPetAnchorName = "VirtualPetAnchor"
    let virtualPetNodeName = "VirtualPetNode"
    
    func getNewVirtualObjectInstance(index: Int) -> SCNNode {
        let currentObjectStr = availableObjects[index]
        guard let sceneURL = Bundle.main.url(forResource: currentObjectStr, withExtension: "scn", subdirectory: "Assets.scnassets/" + currentObjectStr),
            let referenceNode = SCNReferenceNode(url: sceneURL) else {
                fatalError("can't load virtual object")
        }
        referenceNode.load()
        referenceNode.name = self.virtualObjectNodeName + String(self.virtualObjectNodes.count)
    
        return referenceNode
    }
    
    func getDragonAnimations() -> [SCNNode] {
        var nodes : [SCNNode] = []
        
        for name in dragonAnimations {
            guard let usdzURL = Bundle.main.url(forResource: name, withExtension: "usdz"),
                let referenceNode = SCNReferenceNode(url: usdzURL)
                else { fatalError("can't find dragon asset") }
            referenceNode.load()
            referenceNode.simdScale = SIMD3<Float>(0.2, 0.2, 0.2)
            referenceNode.name = virtualPetNodeName + name
            nodes.append(referenceNode)
        }

        return nodes
    }
    
    @IBAction func nextObject() {
        self.currentObjectIndex = (self.currentObjectIndex + 1) % self.availableObjects.count
        updateNextObjectButtonLabel()
    }
    
    func updateNextObjectButtonLabel() {
        let currentObjectStr = availableObjects[currentObjectIndex]
        self.nextObjectButton.setTitle(currentObjectStr, for: .normal)
    }

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
