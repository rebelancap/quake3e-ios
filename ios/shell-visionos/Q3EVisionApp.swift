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
private func q3eSetSpatialAudio(immersive: Bool) {
    do {
        let session = AVAudioSession.sharedInstance()
        if immersive {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .large, anchoringStrategy: .front))
        } else {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
        Q3E_BlackBox_Str("Swift: spatial audio -> \(immersive ? "front (3D)" : "automatic (2D)")")
    } catch {
        NSLog("Q3E-VISION Swift: setIntendedSpatialExperience failed: \(error)")
        Q3E_BlackBox_Str("Swift: spatial audio FAILED: \(error.localizedDescription)")
    }
}

// Shared bridge the ObjC/C side pokes to open/close the 3D immersive space.
final class Q3EAppModel: ObservableObject {
    static let shared = Q3EAppModel()
    @Published var immersive = false
}

// Called from the (shared) settings toggle to switch between 2D window and 3D
// immersive presentation.
@_cdecl("Q3E_SetImmersiveMode")
func Q3E_SetImmersiveMode(_ on: Bool) {
    DispatchQueue.main.async { Q3EAppModel.shared.immersive = on }
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
            // 3D toggle + settings gear hang fully BELOW the window (Austin's preferred
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
                        Q3E_Enter3D(!model.immersive)   // gw_minimized before the space opens
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
                        q3eSetSpatialAudio(immersive: true)    // sound follows the panel
                    } else {
                        await dismissImmersiveSpace()
                        q3eSetSpatialAudio(immersive: false)   // back to the window
                        Q3E_BlackBox_Str("Swift: dismissed immersive")
                    }
                }
            }
    }
}

@main
struct Q3EVisionApp: App {
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
    }
}
