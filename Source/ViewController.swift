import Cocoa
import MetalKit

var vc:ViewController! = nil
var g = Graphics()
var aData = ArcBallData()

class ViewController: NSViewController, NSWindowDelegate, WGDelegate {
    var isStereo:Bool = false
    var isHighRes:Bool = true
    var control = Control()
    
    var threadGroupCount = MTLSize()
    var threadGroups = MTLSize()
    
    lazy var device: MTLDevice! = MTLCreateSystemDefaultDevice()
    var cBuffer:MTLBuffer! = nil
    var coloringTexture:MTLTexture! = nil
    var outTextureL:MTLTexture! = nil
    var outTextureR:MTLTexture! = nil
    var pipeline1:MTLComputePipelineState! = nil
    let queue = DispatchQueue(label:"Q")
    
    lazy var defaultLibrary: MTLLibrary! = { self.device.makeDefaultLibrary() }()
    lazy var commandQueue: MTLCommandQueue! = { return self.device.makeCommandQueue() }()
    
    @IBOutlet var wg: WidgetGroup!
    @IBOutlet var metalTextureViewL: MetalTextureView!
    @IBOutlet var metalTextureViewR: MetalTextureView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        vc = self
        
        cBuffer = device.makeBuffer(bytes: &control, length: MemoryLayout<Control>.stride, options: MTLResourceOptions.storageModeShared)
        
        do {
            let defaultLibrary:MTLLibrary! = device.makeDefaultLibrary()
            guard let kf1 = defaultLibrary.makeFunction(name: "mandelBoxShader")  else { fatalError() }
            pipeline1 = try device.makeComputePipelineState(function: kf1)
        } catch { fatalError("error creating pipelines") }
        
        let w = pipeline1.threadExecutionWidth
        let h = pipeline1.maxTotalThreadsPerThreadgroup / w
        threadGroupCount = MTLSizeMake(w*2/3, h, 1)  // using values 'full-size' causes slow rendering

        control.txtOnOff = 0    // 'no texture'
        
        wg.delegate = self
        initializeWidgetGroup()
        layoutViews()
        
        Timer.scheduledTimer(withTimeInterval:0.05, repeats:true) { timer in self.timerHandler() }
    }
    
    override func viewDidAppear() {
        view.window?.delegate = self
        resizeIfNecessary()
        dvrCount = 1 // resize metalviews without delay
        reset()
    }
    
    //MARK: -
    
    func resizeIfNecessary() {
        let minWinSize:CGSize = CGSize(width:700, height:675)
        var r:CGRect = (view.window?.frame)!
        
        if r.size.width < minWinSize.width || r.size.height < minWinSize.height {
            r.size = minWinSize
            view.window?.setFrame(r, display: true)
        }
    }
    
    func windowDidResize(_ notification: Notification) {
        resizeIfNecessary()
        resetDelayedViewResizing()
    }
    
    //MARK: -
    
    var dvrCount:Int = 0
    
    // don't realloc metalTextures until they have finished resizing the window
    func resetDelayedViewResizing() {
        dvrCount = 10 // 20 = 1 second delay
    }
    
    @objc func timerHandler() {
        let refresh:Bool = wg.update()
        if refresh && !isBusy { updateImage() }
        
        if dvrCount > 0 {
            dvrCount -= 1
            if dvrCount <= 0 {
                layoutViews()
            }
        }
    }
    
    //MARK: -
    
    func initializeWidgetGroup() {
        let gap:Float = -20
        let coloringHeight:Float = Float(RowHT - 2)
        wg.reset()
        wg.addToggle("Q",.resolution)
        wg.addLine()
        wg.addSingleFloat("Z",&control.zoom,  0.2,2, 0.03, "Zoom")
        wg.addSingleFloat("F",&control.scaleFactor,  -5.0,5.0, 0.001, "SFactor")
        wg.addSingleFloat("E",&control.epsilon,  0.00001, 0.0005, 0.0001, "epsilon")
        wg.addColor(.burningShip,coloringHeight)
        wg.addCommand("3","B Ship",.burningShip)
        wg.addLine()
        wg.addGap(gap)
        let deltaAmountS:Float = 0.005
        wg.addFloat3Dual("S",&control.sphere, 0,2,deltaAmountS, "Sphere")
        wg.addFloat3Dual("",&control.dSphere, 0.1,2,deltaAmountS, "△Sphere")
        wg.addFloat3Dual("",&control.ddSphere, 0.1,2,deltaAmountS, "△△Sph")
        wg.addSingleFloat("",&control.sphereMult,  0.1,6.0,deltaAmountS, "S Mult")
        wg.addLine()
        wg.addGap(gap)
        let deltaAmountB:Float = 0.001
        wg.addFloat3Dual("B",&control.box, 0.5,2.5, deltaAmountB, "Box")
        wg.addFloat3Dual("",&control.dBox,  0.1,2,  deltaAmountB, "△Box")
        wg.addFloat3Dual("",&control.ddBox, 0.1,2,  deltaAmountB, "△△Box")
        wg.addLine()
        wg.addGap(gap)
        wg.addToggle("J",.julia)
        wg.addTriplet("",&control.julia,-10,10,0.01,"Julia")
        wg.addGap(gap)
        wg.addTriplet("C",&control.color,0,1,0.02,"Tint")
        wg.addTriplet("L",&control.lighting.position,-10,10,0.3,"Light")
        
        let sPmin:Float = 0.01
        let sPmax:Float = 1
        let sPchg:Float = 0.01
        wg.addSingleFloat("4",&control.lighting.diffuse,sPmin,sPmax,sPchg, "Bright")
        wg.addSingleFloat("5",&control.lighting.specular,sPmin,sPmax,sPchg, "Shiny")
        wg.addSingleFloat("6",&control.fog,0.4,2,sPchg, "Fog")
        
        wg.addLine()
        wg.addCommand("V","Save/Load",.saveLoad)
        wg.addCommand("H","Help",.help)
        wg.addCommand("7","Reset",.reset)
        
        wg.addLine()
        wg.addCommand("O","Stereo",.stereo)
        let parallaxRange:Float = 0.008
        wg.addSingleFloat("8",&control.parallax, -parallaxRange,+parallaxRange,0.0002, "Parallax")
        
        wg.addLine()
        wg.addSingleFloat("U",&control.radialAngle,0,Float.pi,0.3, "Radial S")
        wg.addLine()
        wg.addCommand("M","Move",.move)
        wg.addCommand("R","Rotate",.rotate)
        
        wg.addLine()
        wg.addColor(.texture,coloringHeight)
        wg.addCommand("2","Texture",.texture)
        wg.addTriplet("T",&control.txtCenter,0,1,0.02,"Pos, Sz")
        
        wg.refresh()
    }
    
    //MARK: -
    
    func wgCommand(_ cmd: WgIdent) {
        func presentPopover(_ name:String) {
            let mvc = NSStoryboard(name: NSStoryboard.Name(rawValue: "Main"), bundle: nil)
            let vc = mvc.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier(rawValue:name)) as! NSViewController
            self.presentViewController(vc, asPopoverRelativeTo: wg.bounds, of: wg, preferredEdge: .maxX, behavior: .transient)
        }
        
        switch(cmd) {
        case .saveLoad :
            presentPopover("SaveLoadVC")
        case .help :
            presentPopover("HelpVC")
        case .stereo :
            isStereo = !isStereo
            initializeWidgetGroup()
            layoutViews()
            updateImage()
        case .burningShip :
            control.isBurningShip = control.isBurningShip > 0 ? 0 : 1
            defaultJbsSettings()
        case .texture :
            if control.txtOnOff > 0 {
               control.txtOnOff = 0
               updateImage()
            }
            else {
                loadImageFile()
            }
        case .reset :
            reset()
        default : break
        }
        
        wg.refresh()
    }
    
    func wgToggle(_ ident:WgIdent) {
        switch(ident) {
        case .resolution :
            isHighRes = !isHighRes
            setImageViewResolution()
            updateImage()
        case .julia :
            control.isJulia = control.isJulia == 1 ? 0 : 1
            defaultJbsSettings()
            wg.moveFocus(1) // companion control widgets
        default : break
        }
        
        wg.refresh()
    }
    
    func wgGetString(_ ident:WgIdent) -> String {
        switch ident {
        case .resolution : return isHighRes ? "Res: High" : "Res: Low"
        case .julia : return control.isJulia == 1 ? "Julia: On" : "Julia: Off"
        default : return ""
        }
    }
    
    func wgGetColor(_ ident:WgIdent) -> NSColor {
        var highlight:Bool = false
        
        switch(ident) {
        case .burningShip : highlight = control.isBurningShip == 1
        case .stereo : highlight = isStereo
        case .texture : highlight = control.txtOnOff > 0
        default : break
        }
        
        return highlight ? wgHighlightColor : wgBackgroundColor
    }
    
    func wgOptionSelected(_ ident: WgIdent, _ index: Int) {}
    func wgGetOptionString(_ ident: WgIdent) -> String { return "" }
    
    //MARK: -
    
    func reset() {
        isHighRes = false
        
        control.camera = vector_float3(0.35912, 2.42031, -0.376283)
        control.focus = vector_float3(0.35912, 2.52031, -0.376283)
        control.zoom = 0.6141
        control.epsilon = 0.000074
        control.scaleFactor = 3
        
        control.sphere.x = 0.25
        control.sphere.y = 1
        control.sphereMult = 4
        control.box.x = 1
        control.box.y = 2
        
        control.julia = float3()
        control.isJulia = 0
        
        control.lighting.position = float3(0.2745, -0.0720005, 1.0)
        control.lighting.diffuse = 0.7066392
        
        control.color = float3(0.28745794, 0.14876868, 0.25867578)
        control.parallax = 0.0011
        control.fog = 1.150418
        
        control.dBox = vector_float3(1,1,1)
        control.dSphere = vector_float3(1,1,1)
        control.ddBox = vector_float3(1,1,1)
        control.ddSphere = vector_float3(1,1,1)
        
        control.radialAngle = 0
        control.isBurningShip = 0
        
        alterAngle(0,0)
        updateImage()
        wg.hotKey("M")
    }
    
    func defaultJbsSettings() {
        var modifierCount = 0
        if control.isJulia == 1 { modifierCount += 1 }
        if control.isBurningShip == 1 { modifierCount += 1 }
        
        if modifierCount == 1 {
            control.camera = vector_float3(0.35912, 2.42031, -0.376283)
            control.focus = vector_float3(0.372051, 2.51716, -0.397411)
            control.julia = vector_float3(1.488, 0.893999, 0.0)
            aData.transformMatrix = simd_float4x4([0.420445, 0.139344, 0.89627, 0.0],[0.12931, 0.968464, -0.211281, 0.0],[-0.897794, 0.20482, 0.3896, 0.0],[0.0, 0.0, 0.0, 1.0])
            aData.endPosition = simd_float3x3([0.420445, 0.139344, 0.89627], [0.12931, 0.968464, -0.211281], [-0.897794, 0.20482, 0.3896])
        }
        else
            if modifierCount == 2 {
                control.camera = vector_float3(-0.130225, 2.91748, -0.496772)
                control.focus = vector_float3(-0.0428743, 2.96485, -0.486126)
                control.julia = vector_float3(-1.3435, 0.496, 0.7725)
                aData.transformMatrix = simd_float4x4([-0.133251, 0.444477, -0.885337, 0.0], [0.873522, 0.473633, 0.106464, 0.0], [0.467023, -0.759618, -0.45197, 0.0], [0.0, 0.0, 0.0, 1.0])
                aData.endPosition = simd_float3x3([-0.133251, 0.444477, -0.885337], [0.873522, 0.473633, 0.106464], [0.467023, -0.759618, -0.45197])
        }
        
        updateImage()
    }
    
    //MARK: -
    
    func loadTexture(from image: NSImage) -> MTLTexture {
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        
        let textureLoader = MTKTextureLoader(device: device)
        do {
            let textureOut = try textureLoader.newTexture(cgImage:cgImage)
            
            control.txtSize.x = Float(cgImage.width)
            control.txtSize.y = Float(cgImage.height)
            control.txtCenter.x = 0.5
            control.txtCenter.y = 0.5
            control.txtCenter.z = 0.01
            return textureOut
        }
        catch {
            fatalError("Can't load texture")
        }
    }
    
    func loadImageFile() {
        control.txtOnOff = 0
        
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false
        openPanel.canChooseFiles = true
        openPanel.title = "Select Image for Texture"
        openPanel.allowedFileTypes = ["jpg","png"]
        
        openPanel.beginSheetModal(for:self.view.window!) { (response) in
            if response.rawValue == NSApplication.ModalResponse.OK.rawValue {
                let selectedPath = openPanel.url!.path
                
                if let image:NSImage = NSImage(contentsOfFile: selectedPath) {
                    self.coloringTexture = self.loadTexture(from: image)
                    self.control.txtOnOff = 1
                }
            }
            
            openPanel.close()
            
            if self.control.txtOnOff > 0 { // just loaded a texture
                self.wg.moveFocus(1)  // companion texture widgets
                self.updateImage()
            }
        }
    }
    
    //MARK: -
    
    func layoutViews() {
        let xs = view.bounds.width
        let ys = view.bounds.height
        let xBase:CGFloat = wg.isHidden ? 0 : 125
        
        if !wg.isHidden {
            wg.frame = CGRect(x:0, y:0, width:xBase, height:ys)
        }
        
        if isStereo {
            metalTextureViewR.isHidden = false
            let xs2:CGFloat = (xs - xBase)/2
            metalTextureViewL.frame = CGRect(x:xBase, y:0, width:xs2, height:ys)
            metalTextureViewR.frame = CGRect(x:xBase+xs2+1, y:0, width:xs2, height:ys) // +1 = 1 pixel of bkground between
        }
        else {
            metalTextureViewR.isHidden = true
            metalTextureViewL.frame = CGRect(x:xBase, y:0, width:xs-xBase, height:ys)
        }
        
        setImageViewResolution()
        updateImage()
    }
    
    func controlJustLoaded() {
        wg.refresh()
        setImageViewResolution()
        updateImage()
    }
    
    func setImageViewResolution() {
        control.xSize = Int32(metalTextureViewL.frame.width)
        control.ySize = Int32(metalTextureViewL.frame.height)
        if !isHighRes {
            control.xSize /= 2
            control.ySize /= 2
        }
        
        let xsz = Int(control.xSize)
        let ysz = Int(control.ySize)
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: xsz,
            height: ysz,
            mipmapped: false)
        
        outTextureL = device.makeTexture(descriptor: textureDescriptor)!
        outTextureR = device.makeTexture(descriptor: textureDescriptor)!
        
        metalTextureViewL.initialize(outTextureL)
        metalTextureViewR.initialize(outTextureR)
        
        threadGroups = MTLSize(width:xsz, height:ysz, depth: 1)
        
//        computeCommandEncoder.dispatchThreads(threadsPerGrid,
//                                              threadsPerThreadgroup: threadsPerThreadgroup)
//
//
//
//
//
//        let maxsz = max(xsz,ysz) + Int(threadGroupCount.width-1)
//        threadGroups = MTLSizeMake(
//            maxsz / threadGroupCount.width,
//            maxsz / threadGroupCount.height,1)
    }
    
    //MARK: -
    
    func calcRayMarch(_ who:Int) {
        func toRectangular(_ sph:float3) -> float3 { let ss = sph.x * sin(sph.z); return float3( ss * cos(sph.y), ss * sin(sph.y), sph.x * cos(sph.z)) }
        func toSpherical(_ rec:float3) -> float3 { return float3(length(rec), atan2(rec.y,rec.x), atan2(sqrt(rec.x*rec.x+rec.y*rec.y), rec.z)) }
        
        var c = control
        
        if isStereo {
            if who == 0 {
                c.camera.x -= control.parallax
                c.focus.x  += control.parallax
                
            } else {
                c.camera.x += control.parallax
                c.focus.x  -= control.parallax
            }
        }
        
        c.viewVector = c.focus - c.camera
        c.topVector = toSpherical(c.viewVector)
        c.topVector.z += 1.5708
        c.topVector = toRectangular(c.topVector)
        c.sideVector = cross(c.viewVector,c.topVector)
        c.sideVector = normalize(c.sideVector) * length(c.topVector)
        c.lighting.position = normalize(c.lighting.position)
        c.fog = pow(control.fog,4) // stronger, smoother
        
        cBuffer.contents().copyMemory(from: &c, byteCount:MemoryLayout<Control>.stride)
        
        let commandBuffer = commandQueue.makeCommandBuffer()!
        let commandEncoder = commandBuffer.makeComputeCommandEncoder()!
        
        commandEncoder.setComputePipelineState(pipeline1)
        commandEncoder.setTexture(who == 0 ? outTextureL : outTextureR, index: 0)
        commandEncoder.setTexture(coloringTexture, index: 1)
        commandEncoder.setBuffer(cBuffer, offset: 0, index: 0)
        commandEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupCount)
        commandEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    //MARK: -

    var isBusy:Bool = false
    
    func updateImage() {
        if isBusy { return }
        isBusy = true
        
        control.deFactor1 = abs(control.scaleFactor - 1.0);
        control.deFactor2 = pow( Float(abs(control.scaleFactor)), Float(1 - 10));
        
        calcRayMarch(0)
        metalTextureViewL.display(metalTextureViewL.layer!)
        
        if isStereo {
            calcRayMarch(1)
            metalTextureViewR.display(metalTextureViewR.layer!)
        }
        
        isBusy = false
    }
    
    //MARK: -
    
    func alterAngle(_ dx:Float, _ dy:Float) {
        let center:CGFloat = 25
        arcBall.mouseDown(CGPoint(x: center, y: center))
        arcBall.mouseMove(CGPoint(x: center + CGFloat(dx), y: center + CGFloat(dy)))
        
        let direction = simd_make_float4(0,0.1,0,0)
        let rotatedDirection = simd_mul(aData.transformMatrix, direction)
        
        control.focus.x = rotatedDirection.x
        control.focus.y = rotatedDirection.y
        control.focus += control.camera
        
        updateImage()
    }
    
    func alterPosition(_ dx:Float, _ dy:Float, _ dz:Float) {
        func axisAlter(_ dir:float4, _ amt:Float) {
            let diff = simd_mul(aData.transformMatrix, dir) * amt / 300.0
            
            func alter(_ value: inout float3) {
                value.x -= diff.x
                value.y -= diff.y
                value.z -= diff.z
            }
            
            alter(&control.camera)
            alter(&control.focus)
        }
        
        let q:Float = optionKeyDown ? 1 : 0.1
        
        if shiftKeyDown {
            axisAlter(simd_make_float4(0,q,0,0),-dx * 2)
            axisAlter(simd_make_float4(0,0,q,0),dy)
        }
        else {
            axisAlter(simd_make_float4(q,0,0,0),dx)
            axisAlter(simd_make_float4(0,0,q,0),dy)
        }
        
        updateImage()
    }
    
    //MARK: -
    
    var shiftKeyDown:Bool = false
    var optionKeyDown:Bool = false
    var letterAKeyDown:Bool = false
    
    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        
        updateModifierKeyFlags(event)
        
        switch event.keyCode {
        case 123:   // Left arrow
            wg.hopValue(-1,0)
            return
        case 124:   // Right arrow
            wg.hopValue(+1,0)
            return
        case 125:   // Down arrow
            wg.hopValue(0,-1)
            return
        case 126:   // Up arrow
            wg.hopValue(0,+1)
            return
        case 43 :   // '<'
            wg.moveFocus(-1)
            return
        case 47 :   // '>'
            wg.moveFocus(1)
            return
        case 53 :   // Esc
            NSApplication.shared.terminate(self)
        case 0 :    // A
            letterAKeyDown = true
        case 18 :   // 1
            wg.isHidden = !wg.isHidden
            layoutViews()
        default:
            break
        }
        
        let keyCode = event.charactersIgnoringModifiers!.uppercased()
        print("KeyDown ",keyCode,event.keyCode)
        
        wg.hotKey(keyCode)
    }
    
    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        
        wg.stopChanges()
        
        switch event.keyCode {
        case 0 :    // A
            letterAKeyDown = false
        default:
            break
        }
        
    }
    
    //MARK: -
    
    func flippedYCoord(_ pt:NSPoint) -> NSPoint {
        var npt = pt
        npt.y = view.bounds.size.height - pt.y
        return npt
    }
    
    func updateModifierKeyFlags(_ ev:NSEvent) {
        let rv = ev.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        shiftKeyDown   = rv & (1 << 17) != 0
        optionKeyDown  = rv & (1 << 19) != 0
    }
    
    var pt = NSPoint()
    
    override func mouseDown(with event: NSEvent) {
        pt = flippedYCoord(event.locationInWindow)
    }
    
    override func mouseDragged(with event: NSEvent) {
        updateModifierKeyFlags(event)
        
        var npt = flippedYCoord(event.locationInWindow)
        npt.x -= pt.x
        npt.y -= pt.y
        wg.focusMovement(npt,1)
    }
    
    override func mouseUp(with event: NSEvent) {
        pt.x = 0
        pt.y = 0
        wg.focusMovement(pt,0)
    }
}

// ===============================================

class BaseNSView: NSView {
    override var acceptsFirstResponder: Bool { return true }
}
