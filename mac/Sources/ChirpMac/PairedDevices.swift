import ChirpCore
import Foundation

/// The device store of this Mac's server: `chirp-server pair --name` and `devices`, run from the same environment as the
/// models helper. Shared by Settings → Devices and the Pair a Phone window.
enum PairedDevices {
    static let store: any DeviceStoring = DeviceCLI(executable: { LocalModelsWindowController.executable() }, run: TailscaleCLI.run)
}
