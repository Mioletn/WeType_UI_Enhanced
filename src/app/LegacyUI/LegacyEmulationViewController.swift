// SPDX-License-Identifier: GPL-2.0-or-later
//
// The iOS 12.2 shell's Emulation screen.
//
// The guest's shell runs on the serial port, not on the framebuffer: a Linux VT
// only takes keys from legacy keyboard drivers, so QEMU's keyboard device can
// never type into it (see LegacySerialLink for the whole story). That makes the
// serial stream the real console, so it is the primary view here -- a large
// monospace terminal with an input line, and the virtio-gpu framebuffer
// available behind a Console/Screen switch for anything that paints.
//
// Pure UIKit: no SwiftUI, which does not exist on iOS 12.
import UIKit

final class LegacyEmulationViewController: UIViewController {

    private let statusLabel = UILabel()
    /// One line about the guest's three moving parts. Two of them live outside
    /// the IPA, so "missing" has to be visible before Start is pressed.
    private let guestLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .white)
    private let modeControl = UISegmentedControl(items: ["Console", "Screen"])
    private let terminalView = UITextView()
    private let screenView = UIImageView()
    /// The GPU surface. virgl renders into its CAMetalLayer, so this is the view
    /// that shows an accelerated guest; screenView stays as the software path.
    private let glView = LegacyGLView.shared
    private let inputField = UITextField()
    private let enterButton = UIButton(type: .system)
    private let ctrlCButton = UIButton(type: .system)
    private let tabButton = UIButton(type: .system)

    private var tickTimer: Timer?
    private var screenTimer: Timer?
    private var lastSeq: UInt64 = 0
    private var lastRendered = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Emulation"
        view.backgroundColor = LegacyUI.background
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startTimers()
        refreshStatus()
        refreshGuestCard()
        refreshTerminal()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopTimers()
    }

    // MARK: - UI

    private func setupUI() {
        statusLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        statusLabel.textColor = LegacyUI.text
        statusLabel.text = "Idle"
        statusLabel.textAlignment = .center

        guestLabel.font = huskMonospacedFont(ofSize: 11, weight: .regular)
        guestLabel.textColor = LegacyUI.textDim
        guestLabel.textAlignment = .center
        guestLabel.numberOfLines = 0

        startButton.setTitle("Start guest (QEMU)", for: .normal)
        startButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)

        stopButton.setTitle("Stop", for: .normal)
        stopButton.addTarget(self, action: #selector(stopTapped), for: .touchUpInside)
        stopButton.isEnabled = false

        spinner.hidesWhenStopped = true

        resetButton.setTitle("Reset disk", for: .normal)
        resetButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        resetButton.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)

        let buttonRow = UIStackView(arrangedSubviews: [startButton, stopButton,
                                                       resetButton, spinner])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 16
        buttonRow.alignment = .center
        buttonRow.distribution = .fill

        modeControl.selectedSegmentIndex = 0
        modeControl.tintColor = LegacyUI.accent
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        // The terminal. Not editable: typing goes through the input line below, so
        // the caret and the keyboard never fight with the guest's cursor.
        terminalView.backgroundColor = UIColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
        terminalView.textColor = LegacyUI.text
        terminalView.font = huskMonospacedFont(ofSize: 11, weight: .regular)
        terminalView.isEditable = false
        terminalView.isSelectable = true
        terminalView.layer.cornerRadius = 8
        terminalView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        terminalView.text = "The guest console appears here once QEMU is running."
        terminalView.setContentHuggingPriority(.defaultLow, for: .vertical)
        terminalView.isUserInteractionEnabled = true
        terminalView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(focusInput)))

        screenView.contentMode = .scaleAspectFit
        screenView.backgroundColor = .black
        screenView.layer.borderColor = LegacyUI.surfaceHigh.cgColor
        screenView.layer.borderWidth = 1
        screenView.layer.cornerRadius = 8
        screenView.setContentHuggingPriority(.defaultLow, for: .vertical)
        screenView.isHidden = true
        screenView.isUserInteractionEnabled = true
        screenView.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(screenTapped(_:))))

        glView.backgroundColor = .black
        glView.layer.cornerRadius = 8
        glView.clipsToBounds = true
        glView.setContentHuggingPriority(.defaultLow, for: .vertical)
        glView.isHidden = true
        // The presenter needs the same layer the EGL surface is built on; it is
        // one object for the life of the process.
        LegacyMetalPresenter.shared.attach(layer: glView.metalLayer)

        // Input line. Every edit is refused and forwarded to the guest instead, so
        // the field stays empty and acts as a keystroke surface.
        inputField.backgroundColor = LegacyUI.surface
        inputField.textColor = LegacyUI.text
        inputField.tintColor = LegacyUI.accent
        inputField.font = huskMonospacedFont(ofSize: 13, weight: .regular)
        inputField.placeholder = "Type into the guest console"
        inputField.autocorrectionType = .no
        inputField.autocapitalizationType = .none
        inputField.spellCheckingType = .no
        inputField.keyboardType = .asciiCapable
        inputField.returnKeyType = .send
        inputField.delegate = self
        inputField.layer.cornerRadius = 8
        inputField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        inputField.leftViewMode = .always
        inputField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        styleKey(enterButton, "⏎", #selector(enterTapped))
        styleKey(ctrlCButton, "⌃C", #selector(ctrlCTapped))
        styleKey(tabButton, "⇥", #selector(tabTapped))

        let inputRow = UIStackView(arrangedSubviews: [inputField, enterButton,
                                                      ctrlCButton, tabButton])
        inputRow.axis = .horizontal
        inputRow.spacing = 8
        inputRow.alignment = .fill
        inputRow.distribution = .fill

        let vstack = UIStackView(arrangedSubviews: [statusLabel, guestLabel, buttonRow, modeControl,
                                                    terminalView, glView, screenView, inputRow])
        vstack.axis = .vertical
        vstack.spacing = 10
        vstack.alignment = .fill
        vstack.distribution = .fill
        vstack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vstack)

        NSLayoutConstraint.activate([
            vstack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            vstack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            vstack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            vstack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            inputRow.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    private func styleKey(_ b: UIButton, _ title: String, _ action: Selector) {
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = huskMonospacedFont(ofSize: 15, weight: .regular)
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.backgroundColor = LegacyUI.surface
        b.layer.cornerRadius = 8
        b.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - actions

    @objc private func startTapped() {
        startButton.isEnabled = false
        spinner.startAnimating()
        // A GL guest needs its surface on screen before the EGL context is built
        // against it: a hidden view has no window and no bounds, and creating a
        // window surface on that is asking for a failure. This also means the
        // picture appears where the user is already looking.
        if LegacyEmulationController.shared.bootWantsGL {
            modeControl.selectedSegmentIndex = 1
            applyMode()
            view.layoutIfNeeded()
        }
        LegacyEmulationController.shared.start()
        stopButton.isEnabled = true
        refreshStatus()
    }

    @objc private func stopTapped() {
        LegacyEmulationController.shared.stop()
        stopButton.isEnabled = false
    }

    /// Recovery path: a broken persistent root cannot be repaired from inside
    /// the guest that is running off it, so throw the disk away instead.
    @objc private func resetTapped() {
        guard !LegacyEmulationController.shared.isRunning else {
            LegacyUI.Banner("Stop the guest first", color: LegacyUI.warn).show(in: view)
            return
        }
        let a = UIAlertController(
            title: "Reset guest disk?",
            message: "Deletes husk-root.img. The next start boots from the seed into a "
                   + "throwaway tmpfs, and anything installed since is lost.",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in
            LegacyEmulationController.shared.resetRootDisk()
            self?.refreshGuestCard()
        })
        present(a, animated: true)
    }

    @objc private func modeChanged() {
        applyMode()
        if modeControl.selectedSegmentIndex == 0 { refreshTerminal() }
    }

    /// Console, or Screen -- and inside Screen either the GPU surface or the CPU
    /// framebuffer. Which one is only known after Start, so this is re-applied
    /// whenever the guest's display state changes.
    private func applyMode() {
        let console = modeControl.selectedSegmentIndex == 0
        let gl = LegacyEmulationController.shared.glActive
        terminalView.isHidden = !console
        glView.isHidden = console || !gl
        screenView.isHidden = console || gl

        if console || gl {
            // Nothing to poll: with GL up the presenter draws on QEMU's thread,
            // and in console mode the framebuffer is not on screen at all.
            screenTimer?.invalidate()
            screenTimer = nil
        } else {
            startScreenTimer()
        }
        if !console { pumpFrame() }
    }

    /// GL comes up a second or two after Start, so the two screen surfaces have
    /// to swap themselves without the user touching the tab again.
    private func syncScreenVisibility() {
        guard modeControl.selectedSegmentIndex == 1 else { return }
        if glView.isHidden == LegacyEmulationController.shared.glActive {
            applyMode()
        }
    }

    @objc private func focusInput() {
        inputField.becomeFirstResponder()
    }

    @objc private func enterTapped() {
        LegacyEmulationController.shared.typeText("\r")
    }

    @objc private func ctrlCTapped() {
        LegacyEmulationController.shared.typeText("\u{03}")
    }

    @objc private func tabTapped() {
        LegacyEmulationController.shared.typeText("\t")
    }

    /// A tap on the guest framebuffer becomes a click in guest pixels. The image
    /// is aspect-fitted, so the letterbox bars have to be undone first.
    @objc private func screenTapped(_ g: UITapGestureRecognizer) {
        guard let img = screenView.image else { return }
        let bounds = screenView.bounds
        let iw = img.size.width, ih = img.size.height
        guard bounds.width > 0, bounds.height > 0, iw > 0, ih > 0 else { return }

        let scale = min(bounds.width / iw, bounds.height / ih)
        let ox = (bounds.width - iw * scale) / 2
        let oy = (bounds.height - ih * scale) / 2
        let p = g.location(in: screenView)

        let gx = (p.x - ox) / scale
        let gy = (p.y - oy) / scale
        guard gx >= 0, gy >= 0, gx < iw, gy < ih else { return }

        LegacyEmulationController.shared.sendClick(guestX: Int(gx), guestY: Int(gy))
    }

    // MARK: - timers

    private func startTimers() {
        guard tickTimer == nil else { return }
        // 10 Hz is enough for a console and far cheaper than re-reading a growing
        // log file on every frame.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshTerminal()
            self?.refreshStatus()
            self?.refreshGuestCard()
            self?.syncScreenVisibility()
        }
        applyMode()
    }

    private func startScreenTimer() {
        guard screenTimer == nil else { return }
        screenTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.pumpFrame()
        }
    }

    private func stopTimers() {
        tickTimer?.invalidate(); tickTimer = nil
        screenTimer?.invalidate(); screenTimer = nil
    }

    // MARK: - rendering

    private func refreshTerminal() {
        let raw = LegacyEmulationController.shared.terminalText()
        guard !raw.isEmpty else { return }
        let text = LegacyANSI.strip(raw)
        guard text != lastRendered else { return }
        lastRendered = text
        terminalView.text = text
        let end = NSRange(location: (text as NSString).length, length: 0)
        terminalView.scrollRangeToVisible(end)
    }

    private func pumpFrame() {
        guard let frame = LegacyEmulationController.shared.grabFrame() else { return }
        lastSeq = LegacyEmulationController.shared.latestSequence()
        guard let img = makeImage(data: frame.data, width: frame.width,
                                  height: frame.height, stride: frame.stride) else { return }
        screenView.image = img
    }

    private func makeImage(data: Data, width: Int, height: Int, stride: Int) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // virtio-gpu gives 32bpp; Metal's BGRA8Unorm is the matching iOS layout.
        let bmi = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cg = CGImage(width: width, height: height,
                               bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: stride,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: bmi,
                               provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    private func refreshGuestCard() {
        let s = LegacyEmulationController.shared.guestStatus()
        if s.usingCustomArgs {
            // The built-in fields describe the Alpine profile; under a custom
            // command line they would be misleading, so name the profile instead.
            guestLabel.text = "custom boot profile (husk-boot.args)"
            guestLabel.textColor = LegacyUI.textDim
            return
        }
        let gib = String(format: "%.1f GiB", Double(s.diskBytes) / 1_073_741_824)
        let kernel = s.kernelPresent ? "kernel OK" : "kernel MISSING"
        let root = s.rootImagePresent ? "root image OK" : "root image MISSING (Phase 0)"
        let disk = s.diskFormatted ? "disk \(gib) ext4" : "disk \(gib) unformatted"
        guestLabel.text = "\(kernel)   ·   \(root)   ·   \(disk)"
        guestLabel.textColor = (s.kernelPresent && s.rootImagePresent)
            ? LegacyUI.textDim : LegacyUI.warn
    }

    private func refreshStatus() {
        let running = LegacyEmulationController.shared.isRunning
        let console = LegacyEmulationController.shared.isConsoleConnected
        if running {
            statusLabel.text = console ? "QEMU running — console attached"
                                       : "QEMU running — attaching console…"
            statusLabel.textColor = console ? LegacyUI.accent : LegacyUI.warn
            spinner.stopAnimating()
        } else {
            statusLabel.text = "Idle"
            statusLabel.textColor = LegacyUI.text
            spinner.stopAnimating()
        }
    }
}

// MARK: - keystrokes -> guest

extension LegacyEmulationViewController: UITextFieldDelegate {

    /// Every edit is refused and forwarded instead, so the field stays empty and
    /// the guest sees exactly the bytes that were typed (paste included).
    func textField(_ textField: UITextField,
                   shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        if string.isEmpty {
            // Backspace arrives as a deletion with no replacement text. A terminal
            // sends DEL (0x7f) for erase, not a cursor key.
            LegacyEmulationController.shared.typeText("\u{7f}")
            return false
        }
        LegacyEmulationController.shared.typeText(string)
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        LegacyEmulationController.shared.typeText("\r")
        return false
    }
}

// MARK: - the GPU surface (the iOS 12 port of Husk's GL display)

/// A CAMetalLayer-backed view. It is both what ANGLE creates its EGL window
/// surface against and what the Metal presenter draws into.
///
/// Same role as HuskGLView on iOS 15, without the SwiftUI plumbing: layerClass,
/// CAMetalLayer and Metal are all present on 12.2, which is what makes this path
/// possible here at all. The engine itself is already inside the QEMU dylib --
/// husk_display_gl_early/create/bind are exported, and ANGLE is built with a
/// 12.2 deployment target.
///
/// One instance for the process: QEMU builds its EGL window surface against
/// whichever layer is published when GL comes up and never rebuilds it, so a
/// second view would orphan the display -- a frame counter climbing happily
/// against a black screen.
final class LegacyGLView: UIView {
    static let shared = LegacyGLView(frame: .zero)

    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        // ANGLE presents through this layer, so it is rendered into rather than
        // merely displayed.
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = resizeDrawable()
    }

    /// The EGL surface is sized from the layer at create time, so it has to be
    /// real before then. A view hidden inside a stack has zero bounds, hence the
    /// screen-sized fallback: Android draws at panel resolution regardless, and
    /// the presenter letterboxes whatever arrives.
    @discardableResult
    func resizeDrawable() -> CGSize {
        var size = bounds.size
        if size.width < 1 || size.height < 1 { size = UIScreen.main.bounds.size }
        let scale = UIScreen.main.scale
        let px = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        if px.width >= 1, px.height >= 1, metalLayer.drawableSize != px {
            metalLayer.drawableSize = px
        }
        return metalLayer.drawableSize
    }

    /// Main thread. The layer plus the pixel size to build the surface at.
    static func prepareSurface() -> (UnsafeMutableRawPointer, CGSize)? {
        let v = shared
        let px = v.resizeDrawable()
        guard px.width >= 1, px.height >= 1 else { return nil }
        return (Unmanaged.passUnretained(v.metalLayer).toOpaque(), px)
    }
}

/// Draws each guest scanout from its own MTLTexture.
///
/// Not from the GL texture id virgl reports: that id belongs to virglrenderer's
/// context, so attaching it to a framebuffer of ours raises
/// GL_INVALID_FRAMEBUFFER_OPERATION on every blit and the picture stays black
/// while the guest is demonstrably drawing. The pixels are in the MTLTexture this
/// QEMU fork carries beside the id -- which is also what UTM's display reaches
/// for first.
final class LegacyMetalPresenter {
    static let shared = LegacyMetalPresenter()

    private var layer: CAMetalLayer?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private let lock = NSLock()
    private var presented: UInt64 = 0

    func attach(layer: CAMetalLayer) {
        lock.lock()
        self.layer = layer
        lock.unlock()
    }

    /// Build against the texture's own device: a texture can only be sampled by
    /// the device that owns it, and ANGLE picked that device, not us.
    private func prepare(for texture: MTLTexture, _ layer: CAMetalLayer) -> Bool {
        if pipeline != nil, device === texture.device { return true }

        let dev = texture.device
        device = dev
        layer.device = dev
        queue = dev.makeCommandQueue()

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VOut { float4 pos [[position]]; float2 uv; };
        struct Params { float flip; float rotate; float2 scale; };

        vertex VOut husk_vertex(uint vid [[vertex_id]],
                                constant Params &p [[buffer(0)]]) {
            const float2 corners[4] = { float2(-1, -1), float2(1, -1),
                                        float2(-1,  1), float2(1,  1) };
            VOut o;
            o.pos = float4(corners[vid] * p.scale, 0, 1);
            float2 uv = corners[vid] * 0.5 + 0.5;
            // Metal samples from the top-left, clip space counts y upward; the
            // guest's own y_0_top then flips it back.
            uv = float2(uv.x, p.flip > 0.5 ? uv.y : 1.0 - uv.y);
            o.uv = p.rotate > 0.5 ? float2(1.0 - uv.y, uv.x) : uv;
            return o;
        }

        fragment float4 husk_fragment(VOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      sampler smp [[sampler(0)]]) {
            // Alpha forced opaque: Android's scanout is commonly B8G8R8X8, whose
            // fourth byte is ignored by definition and zero in practice, and
            // Core Animation would blend the frame away.
            return float4(tex.sample(smp, in.uv).rgb, 1.0);
        }
        """

        do {
            let library = try dev.makeLibrary(source: source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "husk_vertex")
            desc.fragmentFunction = library.makeFunction(name: "husk_fragment")
            desc.colorAttachments[0].pixelFormat = layer.pixelFormat
            pipeline = try dev.makeRenderPipelineState(descriptor: desc)
        } catch {
            HuskLog.log("emu", "metal: could not build the present pipeline: \(error)")
            pipeline = nil
            return false
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = dev.makeSamplerState(descriptor: sd)

        HuskLog.log("emu", "metal: presenting on \(dev.name), guest "
                        + "\(texture.width)x\(texture.height) -> layer "
                        + "\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height))")
        return sampler != nil
    }

    /// Called from QEMU's thread, once per guest frame.
    func present(texture: MTLTexture, flip: Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard let layer = layer, prepare(for: texture, layer),
              let queue = queue, let pipeline = pipeline, let sampler = sampler
        else { return }

        // nil when the pool is exhausted: a dropped frame, not an error.
        guard let drawable = layer.nextDrawable() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        // Letterbox rather than stretch: whichever axis runs out first sets the
        // scale and the other is inset, so the guest keeps its aspect ratio.
        let gw = Float(texture.width), gh = Float(texture.height)
        let lw = Float(layer.drawableSize.width), lh = Float(layer.drawableSize.height)
        var sx: Float = 1, sy: Float = 1
        if gw > 0, gh > 0, lw > 0, lh > 0 {
            let guestAspect = gw / gh
            let layerAspect = lw / lh
            if guestAspect > layerAspect { sy = layerAspect / guestAspect }
            else                        { sx = guestAspect / layerAspect }
        }

        var params = (flip: Float(flip ? 1 : 0), rotate: Float(0), sx: sx, sy: sy)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&params, length: MemoryLayout<Float>.size * 4, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // No manual retain of the texture: a command buffer keeps every resource
        // it references alive until it completes, which is exactly the window in
        // which the GPU reads it.
        buffer.present(drawable)
        buffer.commit()

        presented &+= 1
        if presented == 1 || presented % 600 == 0 {
            HuskLog.log("emu", "metal: presented \(presented) frames "
                            + "(\(texture.width)x\(texture.height), flip=\(flip))")
        }
    }
}

/// The C entry point QEMU calls. A plain function pointer, so everything hangs
/// off the shared presenter rather than a capture.
private let legacyMetalPresent: husk_metal_present_fn = { texture, flip, _, _ in
    guard let texture = texture else { return }
    let obj = Unmanaged<AnyObject>.fromOpaque(texture).takeUnretainedValue()
    guard let tex = obj as? MTLTexture else { return }
    LegacyMetalPresenter.shared.present(texture: tex, flip: flip != 0)
}

func legacyInstallMetalPresenter() {
    husk_display_gl_set_metal_presenter(legacyMetalPresent)
}
