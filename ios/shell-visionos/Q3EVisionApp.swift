// Q3EVisionApp.swift — SwiftUI app entry for the visionOS target.
//
// visionOS requires a SwiftUI `App` to declare an `ImmersiveSpace` (UIKit can't
// open one). So the app entry is SwiftUI, but it just HOSTS the existing UIKit
// engine view controller (Q3EVisionViewController) in a WindowGroup for the 2D
// window, and declares an ImmersiveSpace for the 3D stereoscopic mode. All the
// engine/shell logic stays in ObjC/C; this file is only the scene plumbing.

import SwiftUI
import CompositorServices
import AVFAudio

// Anchor the app's audio at the 3D panel instead of the parked 2D window (vkQuake
// finding: entering the space leaves sound spatialized at the old window position).
// .headTracked + .front keeps the soundstage in front of the user — where the panel
// is; restored to the automatic window-anchored experience on exit.
// Mode 2 (VR) is `.bypassed`: in VR the ENGINE head-pans its own audio (the
// listener follows the head pose), so a second head-tracked spatialisation on
// top of it would pan an already-panned mix.
@_cdecl("Q3E_SetSpatialAudioMode")
func Q3E_SetSpatialAudioMode(_ mode: Int32) {
    do {
        let session = AVAudioSession.sharedInstance()
        switch mode {
        case 2:
            try session.setIntendedSpatialExperience(.bypassed)
        case 1:
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .large, anchoringStrategy: .front))
        default:
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
        Q3E_BlackBox_Str("Swift: spatial audio -> \(mode == 2 ? "bypassed (VR)" : (mode == 1 ? "front (3D)" : "automatic (2D)"))")
    } catch {
        NSLog("Q3E-VISION Swift: setIntendedSpatialExperience failed: \(error)")
        Q3E_BlackBox_Str("Swift: spatial audio FAILED: \(error.localizedDescription)")
    }
}



// Shared bridge the ObjC/C side pokes to open/close the 3D immersive space.
final class Q3EAppModel: ObservableObject {
    static let shared = Q3EAppModel()
    @Published var immersive = false   // the 3D panel space
    @Published var vr = false          // the full-immersion VR space
    // R4.3 item 1 (donor parity: "Show Hands"). The VR space's
    // .upperLimbVisibility was a compile-time constant; a scene modifier can
    // only be moved by re-evaluating the scene, so the value has to live on the
    // one observable object the App already watches. false == .hidden, which is
    // what every build up to 1.0.4.14 shipped.
    @Published var showHands = false
}

// Called from the (shared) settings toggle to switch between 2D window and 3D
// immersive presentation.
@_cdecl("Q3E_SetImmersiveMode")
func Q3E_SetImmersiveMode(_ on: Bool) {
    DispatchQueue.main.async { Q3EAppModel.shared.immersive = on }
}

// Same, for the VR space. Both spaces are declared in the App below; only one
// can be open at a time, which is why the mode machine sequences a direct
// 3D<->VR switch as dismiss-then-open.
@_cdecl("Q3E_SetVRSpace")
func Q3E_SetVRSpace(_ on: Bool) {
    DispatchQueue.main.async { Q3EAppModel.shared.vr = on }
}

// R4.3 item 1. The settings row's applier, from ObjC. Applied while the space is
// OPEN as well as before it opens: the modifier is part of the scene's body, so
// publishing a new value re-evaluates it and visionOS takes the change live —
// which is the whole point of a comfort row (a setting that needs a VR exit to
// take effect is a setting nobody changes in the headset).
@_cdecl("Q3E_VR_SetShowHands")
func Q3E_VR_SetShowHands(_ on: Bool) {
    DispatchQueue.main.async {
        guard Q3EAppModel.shared.showHands != on else { return }
        Q3EAppModel.shared.showHands = on
        Q3E_BlackBox_Str("Swift: upper-limb visibility -> \(on ? "visible" : "hidden")")
    }
}

// Hosts the UIKit engine view controller (the 2D window) inside SwiftUI.
struct Q3EWindowView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Q3EVisionViewController {
        return Q3EVisionViewController()
    }
    func updateUIViewController(_ vc: Q3EVisionViewController, context: Context) {}
}

// CompositorServices layer configuration for the immersive (3D) render path.
struct Q3ECompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        NSLog("Q3E-VISION Swift: makeConfiguration called")
        Q3E_BlackBox_Str("Swift: makeConfiguration called")
        // Query supported layouts so we never request an unsupported combination
        // (that makes openImmersiveSpace fail with a generic .error).
        let layouts = capabilities.supportedLayouts(options: [])
        // Eye-tracked foveation (VISIONOS-FOVEATION-GUIDE.md): the drawable becomes
        // gaze-tracked variable-density — effective foveal resolution multiplies and
        // the panel blur is gone, at NEGATIVE GPU cost (fewer total fragments). The
        // old "foveation off" was a vkQuake Vulkan-era constraint this native-Metal
        // pass never had. Always on where supported (device-verified, table stakes);
        // the simulator reports supportsFoveation false -> plain layered path.
        let fov = capabilities.supportsFoveation
        configuration.isFoveationEnabled = fov
        // TRAP (guide): .layered + one-render-pass-per-slice + foveation rasterizes
        // BOTH eyes with layer 0's rate map while the compositor unwarps each eye
        // with its own -> right-eye fisheye. Dedicated layout gives each eye its own
        // texture AND rate map; Q3EImmersive.m targets passes via the view texture
        // map, so it handles either layout.
        if fov && layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else {
            configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        }
        // Do NOT touch maxRenderQuality: requesting a raised value aborts at
        // immersive entry (guide trap 2); foveation alone delivers the win.
        configuration.colorFormat = capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        configuration.depthFormat = capabilities.supportedDepthFormats.first ?? .depth32Float
        Q3E_BlackBox_Str("Swift: layer config — foveation \(fov ? "ON" : "off"), layout \(configuration.layout == .dedicated ? "dedicated" : "layered")")
    }
}

// The window's root View — owns the immersive-space open/close (these environment
// actions are only valid inside a View, not the App struct) and observes the
// shared model the ObjC/C side toggles.
// Hosts the UIKit settings sheet in a SwiftUI sheet. A UIKit modal presented directly
// (Q3E_OpenSettings) works in 2D but silently fails over an open ImmersiveSpace; a
// SwiftUI .sheet presents correctly alongside the 3D panel, giving live-tuning access.
struct Q3ESettingsSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Q3ESettingsController { Q3ESettingsController() }
    func updateUIViewController(_ vc: Q3ESettingsController, context: Context) {}
}

struct Q3ERootView: View {
    @ObservedObject private var model = Q3EAppModel.shared
    @State private var showSettings = false
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        Q3EWindowView()
            .ignoresSafeArea()
            // 3D toggle + settings gear hang fully BELOW the window (the preferred
            // layout, via the vkQuake recipe): anchor .scene(.bottom) with
            // contentAlignment .top pins the pill's TOP to the window's bottom edge —
            // no straddling/overlap of the game content (an ornament's default center
            // alignment sits ON the boundary). Exit 3D with the button or the Crown.
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                // A "3D"/"Exit" toggle and a settings gear. The gear works while
                // immersive too, so the 3D sliders (distance / size / depth) can be
                // tuned with live feedback on the panel.
                HStack(spacing: 16) {
                    Button(model.immersive ? "Exit" : "3D") {
                        // Q3E_EnterMode is the single owner of every transition;
                        // it handles a direct 3D<->VR switch as dismiss-then-open.
                        Q3E_EnterMode(model.immersive ? 0 : 1)
                    }
                    Button(model.vr ? "Exit VR" : "VR") {
                        Q3E_EnterMode(model.vr ? 0 : 2)
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
                .font(.title3)          // q2repro-sized buttons (caption2 was too small)
                .buttonStyle(.borderless)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassBackgroundEffect()
                .opacity(0.85)
                .padding(.top, 14)      // gap between window bottom edge and pill
            }
            .sheet(isPresented: $showSettings) { Q3ESettingsSheet() }
            .onOpenURL { url in Q3E_HandleURL(url.absoluteString) }
            .onChange(of: model.immersive) { _, on in
                NSLog("Q3E-VISION Swift: immersive onChange -> \(on)")
                Task {
                    if on {
                        Q3E_BlackBox_Str("Swift: calling openImmersiveSpace")
                        let r = await openImmersiveSpace(id: "Q3E3D")
                        NSLog("Q3E-VISION Swift: openImmersiveSpace -> \(String(describing: r))")
                        Q3E_BlackBox_Str("Swift: openImmersiveSpace -> \(r)")
                        Q3E_AssertModePolicy()             // the MODE decides, not this Task
                    } else {
                        await dismissImmersiveSpace()
                        Q3E_BlackBox_Str("Swift: dismissed immersive")
                        // NOT an unconditional "back to the window": by the time
                        // this completion runs the mode may already be VR, and
                        // writing mode 0 here leaves the whole VR session
                        // double-panned. Re-assert whatever the mode is NOW.
                        Q3E_AssertModePolicy()
                    }
                }
            }
            // The VR space. Open/dismiss MUST go through the SwiftUI environment
            // action: calling from a UIKit context works in 2D and silently fails
            // over an open space. The exit finalize runs in the DISMISSAL
            // COMPLETION — stop the render thread, wait, dismiss, then finalize;
            // any other order produces a wedge.
            .onChange(of: model.vr) { _, on in
                NSLog("Q3E-VISION Swift: vr onChange -> \(on)")
                Task {
                    if on {
                        Q3E_BlackBox_Str("Swift: calling openImmersiveSpace(Q3EVR)")
                        let r = await openImmersiveSpace(id: "Q3EVR")
                        Q3E_BlackBox_Str("Swift: openImmersiveSpace(Q3EVR) -> \(r)")
                        // A refused open is not a warning to log and carry on
                        // from: nothing will ever publish an eye pose, so the
                        // entry would commit on its timeout, park the window
                        // behind a curtain, and leave the player looking at
                        // their own room with no way back.
                        if r != .opened {
                            model.vr = false
                            Q3E_VR_OpenFailed()
                        }
                    } else {
                        await dismissImmersiveSpace()
                        Q3E_BlackBox_Str("Swift: dismissed VR space")
                        Q3E_ExitVRFinalize()
                        // The mode owns the audio experience, not this
                        // completion: a 3D<->VR switch has one space's dismissal
                        // racing the other's entry.
                        Q3E_AssertModePolicy()
                    }
                }
            }
    }
}

@main
struct Q3EVisionApp: App {
    // R4.3 item 1: the App observes the same shared model the root view does, so
    // the VR space's upper-limb modifier below is a value rather than a literal.
    @ObservedObject private var model = Q3EAppModel.shared

    var body: some Scene {
        WindowGroup {
            Q3ERootView()
        }
        ImmersiveSpace(id: "Q3E3D") {
            CompositorLayer(configuration: Q3ECompositorConfiguration()) { layerRenderer in
                Q3E_BlackBox_Str("Swift: CompositorLayer closure entered — spawning render thread")
                // Run the render loop on a DEDICATED thread. This closure runs on the
                // MAIN thread, so running the infinite loop directly here blocks the
                // engine's display link -> whole-engine freeze (the sound-loop hang the
                // black box caught: main frozen at tick 7471 while this loop ran at
                // ~360fps on the same thread t259).
                let renderThread = Thread { Q3E_Immersive_Run(layerRenderer) }
                renderThread.name = "Q3E-Immersive"
                renderThread.stackSize = 2 << 20
                renderThread.start()
            }
        }
        // MIXED immersion (explicit): the panel floats in real passthrough — the
        // drawable clears to alpha 0 and the in-scene dim layer ("Dim surroundings"
        // slider) darkens the room continuously; 100% is the old full-immersion void.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        // VR: a SEPARATE space, because the immersion style set is fixed per space
        // at compile time and one space cannot express both. FULL immersion — the
        // player is inside the level, not looking at it.
        ImmersiveSpace(id: "Q3EVR") {
            CompositorLayer(configuration: Q3ECompositorConfiguration()) { layerRenderer in
                Q3E_BlackBox_Str("Swift: VR CompositorLayer entered — spawning render thread")
                let renderThread = Thread { Q3E_VR_Run(layerRenderer) }
                renderThread.name = "Q3E-VR"
                renderThread.stackSize = 2 << 20
                renderThread.start()
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        // R4.3 item 1: hidden by default — full immersion means the player is
        // inside the level, and a pair of real forearms in front of a Quake gun
        // is the first thing that breaks it. The row exists because the donor
        // ships it: some players want their hands while they find a controller.
        .upperLimbVisibility(model.showHands ? .visible : .hidden)
    }
}
