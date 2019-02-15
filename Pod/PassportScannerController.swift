//
//  PassportScannerController.swift
//
//  Created by Edwin Vermeer on 9/7/15.
//  Copyright (c) 2015. All rights reserved.
//

import Foundation
import UIKit
import TesseractOCRSDKiOS
import EVGPUImage2
import GPUImage //Still using this for the rotate
import UIImage_Resize
import AVFoundation

// based to https://www.icao.int/publications/pages/publication.aspx?docnum=9303
@objc
public enum MRZType: Int {
    case auto
    case td1 // 3 lines - 30 chars per line
    //case td2 // to be implemented
    case td3 // 2 lines - 44 chars per line
}

@objc(PassportScannerController)
open class PassportScannerController: UIViewController, MGTesseractDelegate {
    
    /// Set debug to true if you want to see what's happening
    @objc public var debug = false
    
    /// Set accuracy that is required for the scan. 1 = all checksums should be ok
    @objc public var accuracy: Float = 1
    
    @objc public var isAutoMode: Bool = true
    
    /// If false then apply filters in post processing, otherwise instead of in camera preview
    @objc public var showPostProcessingFilters = false
    
    // The parsing to be applied
    @objc public var mrzType: MRZType = MRZType.auto
    
    // For if you want the data on a different location than standard
    @objc public var tesseractTrainedDataAbsolutePath: String?
    
    // Can be sat as a callback function
    @objc public var scannerDidCompleteWith:((MRZParser?) -> ())?
    
    // The size and location of the scan area so that you could create your own custom interface.
    var ocrParsingRect: CGRect = CGRect(x: 350, y: 0, width: 350, height: 1920)
    
    // We only wan to do the setup once.
    @objc public var setupCompleted = false
    
    /// When you create your own view, then make sure you have a GPUImageView that is linked to this
    lazy var renderView: RenderView = {
        let renderView = RenderView.init(frame: view.bounds)
        view.addSubview(renderView)
        renderView.orientation = .landscapeRight
        return renderView
    }()
    
    /// For capturing the video and passing it on to the filters.
    var camera: Camera!
    
    // Quick reference to the used filter configurations
    var exposure: ExposureAdjustment!
    var highlightShadow: HighlightsAndShadows!
    var saturation: SaturationAdjustment!
    var contrast: ContrastAdjustment!
    var adaptiveThreshold: AdaptiveThreshold!
    var averageColor: AverageColorExtractor!
    
    lazy var crop = Crop()
    let defaultExposure: Float = 1.5
    
    //Post processing filters
    private var averageColorFilter: GPUImageAverageColor!
    private var lastExposure: CGFloat = 1.5
    private let shotsCountPerSession = 5
    private var currentCountPerSession = 0

    
    let exposureFilter: GPUImageExposureFilter = GPUImageExposureFilter()
    let highlightShadowFilter: GPUImageHighlightShadowFilter = GPUImageHighlightShadowFilter()
    let saturationFilter: GPUImageSaturationFilter = GPUImageSaturationFilter()
    let contrastFilter: GPUImageContrastFilter = GPUImageContrastFilter()
    let adaptiveThresholdFilter: GPUImageAdaptiveThresholdFilter = GPUImageAdaptiveThresholdFilter()
    
    private lazy var pictureOutput = PictureOutput()
    
    /// The tesseract OCX engine
    private lazy var tesseract: MGTesseract = {
        if let path = self.tesseractTrainedDataAbsolutePath {
            return MGTesseract(language: "eng", configDictionary: nil, configFileNames: nil, absoluteDataPath: path, engineMode: MGOCREngineMode.tesseractOnly)
        } else {
            return MGTesseract(language: "eng")
        }
    }()
    
    public init() {
        super.init(nibName: nil, bundle: nil)
    }
    
    public required init?(coder _: NSCoder) { fatalError() }
    
    /**
     Hide the status bar during scan
     
     :returns: true to indicate the statusbar should be hidden
     */
    override open var prefersStatusBarHidden: Bool {
        get { return true }
    }
    
    /**
     Initialize all graphic filters in the viewDidLoad
     */
    open override func viewDidLoad() {
        super.viewDidLoad()
        
        if !self.setupCompleted {
            self.setup()
        }
    }
    
    @objc public func setup() {
        if self.setupCompleted {
            return
        }
        self.setupCompleted = true
        
        // Specify the crop region that will be used for the OCR
        
        crop.cropSizeInPixels = Size(width: Float(ocrParsingRect.size.width), height: Float(ocrParsingRect.size.height))
        crop.locationOfCropInPixels = Position(Float(ocrParsingRect.origin.x), Float(ocrParsingRect.origin.y), nil)
        crop.overriddenOutputRotation = .rotateClockwise
        
        if !showPostProcessingFilters {
            exposureFilter.exposure = CGFloat(self.defaultExposure)
            highlightShadowFilter.highlights = 0.8
            saturationFilter.saturation = 0.6
            contrastFilter.contrast = 2.0
            adaptiveThresholdFilter.blurRadiusInPixels = 8.0
        } else {
            // Filter settings
            exposure = ExposureAdjustment()
            exposure.exposure = 0.7 // -10 - 10
            
            highlightShadow = HighlightsAndShadows()
            highlightShadow.highlights  = 0.6 // 0 - 1
            
            saturation = SaturationAdjustment();
            saturation.saturation  = 0.6 // 0 - 2
            
            contrast = ContrastAdjustment();
            contrast.contrast = 2.0  // 0 - 4
            
            adaptiveThreshold = AdaptiveThreshold();
            adaptiveThreshold.blurRadiusInPixels = 8.0
            
            // Try to dynamically optimize the exposure based on the average color
            averageColor = AverageColorExtractor();
            averageColor.extractedColorCallback = { color in
                let lighting = color.blueComponent + color.greenComponent + color.redComponent
                let currentExposure = self.exposure.exposure
                
                // The stable color is between 2.75 and 2.85. Otherwise change the exposure
                if lighting < 2.75 {
                    self.exposure.exposure = currentExposure + (2.80 - lighting) * 2
                }
                
                if lighting > 2.85 {
                    self.exposure.exposure = currentExposure - (lighting - 2.80) * 2
                }
                
                if self.exposure.exposure > 2 {
                    self.exposure.exposure = self.defaultExposure
                }
                if self.exposure.exposure < -2 {
                    self.exposure.exposure = self.defaultExposure
                }
            }
        }
        
        // download trained data to tessdata folder for language from:
        // https://code.google.com/p/tesseract-ocr/downloads/list
        // optimisations created based on https://github.com/gali8/Tesseract-OCR-iOS/wiki/Tips-for-Improving-OCR-Results
        
        // tesseract OCR settings
        self.tesseract.setVariableValue("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN OPQRSTUVWXYZ<", forKey: "tessedit_char_whitelist")
        self.tesseract.delegate = self
        
        self.tesseract.rect = CGRect(x: 0, y: 0, width: ocrParsingRect.size.height / 2, height: ocrParsingRect.size.width / 2)
        
        // see http://www.sk-spell.sk.cx/tesseract-ocr-en-variables
        self.tesseract.setVariableValue("1", forKey: "tessedit_serial_unlv")
        self.tesseract.setVariableValue("FALSE", forKey: "x_ht_quality_check")
        self.tesseract.setVariableValue("FALSE", forKey: "load_system_dawg")
        self.tesseract.setVariableValue("FALSE", forKey: "load_freq_dawg")
        self.tesseract.setVariableValue("FALSE", forKey: "load_unambig_dawg")
        self.tesseract.setVariableValue("FALSE", forKey: "load_punc_dawg")
        self.tesseract.setVariableValue("FALSE", forKey: "load_number_dawg")
        self.tesseract.setVariableValue("FALSE", forKey: "load_fixed_length_dawgs")
        self.tesseract.setVariableValue("FALSE", forKey: "load_bigram_dawg")
        self.tesseract.setVariableValue("FALSE", forKey: "wordrec_enable_assoc")
    }
    
    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        startCapturing()
        
        if isAutoMode {
            scanning()
        }
    }
    
    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Clean cache only after using engine in 10 sec
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            MGTesseract.clearCache()
        }
    }
    
    func initCamera(){
        do {
            // Initialize the camera
            camera = try Camera(sessionPreset: AVCaptureSession.Preset.hd1920x1080)
            camera.location = PhysicalCameraLocation.backFacing
            
            if !showPostProcessingFilters {
                // Apply only the cropping
                camera --> renderView
                camera --> crop
            } else {
                // Chain the filter to the render view
                camera --> exposure  --> highlightShadow  --> saturation --> contrast --> adaptiveThreshold --> renderView
                // Use the same chained filters and forward these to 2 other filters
                adaptiveThreshold --> crop --> averageColor
            }
            
            if debug {
                let debugViewFrame : CGRect = self.getOcrParsingRectDebugView()
                let scanAreaDebug = UIView (frame: CGRect(x: debugViewFrame.origin.x, y: debugViewFrame.origin.y, width: debugViewFrame.size.width, height: debugViewFrame.size.height))
                scanAreaDebug.backgroundColor = UIColor.red.withAlphaComponent(0.5)
                renderView.addSubview(scanAreaDebug)
            }
            
        } catch {
            fatalError("Could not initialize rendering pipeline: \(error)")
        }
    }
    
    func evaluateExposure(image: UIImage){
        if self.averageColorFilter != nil {
            return
        }
        
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf.averageColorFilter = GPUImageAverageColor()
            strongSelf.averageColorFilter.colorAverageProcessingFinishedBlock = {red, green, blue, alpha, time in
                let lighting = blue + green + red
                let currentExposure = strongSelf.lastExposure
                
                // The stable color is between 2.75 and 2.85. Otherwise change the exposure
                if lighting < 2.75 {
                    strongSelf.lastExposure = currentExposure + (2.80 - lighting) * 2
                }
                if lighting > 2.85 {
                    strongSelf.lastExposure = currentExposure - (lighting - 2.80) * 2
                }
                
                if strongSelf.lastExposure > 2 {
                    strongSelf.lastExposure = CGFloat(strongSelf.defaultExposure)
                }
                if strongSelf.lastExposure < -2 {
                    strongSelf.lastExposure = CGFloat(strongSelf.defaultExposure)
                }
                
                strongSelf.averageColorFilter = nil
            }
            strongSelf.averageColorFilter.image(byFilteringImage: image)
        }
    }
    
    open func preprocessedImage(for tesseract: MGTesseract, sourceImage: UIImage!) -> UIImage! {
        // sourceImage is the same image you sent to Tesseract above.
        // Processing is already done in dynamic filters
        if showPostProcessingFilters { return sourceImage }
        
        var filterImage: UIImage = sourceImage
        exposureFilter.exposure = self.lastExposure
        filterImage = exposureFilter.image(byFilteringImage: filterImage)
        filterImage = highlightShadowFilter.image(byFilteringImage: filterImage)
        filterImage = saturationFilter.image(byFilteringImage: filterImage)
        filterImage = contrastFilter.image(byFilteringImage: filterImage)
        filterImage = adaptiveThresholdFilter.image(byFilteringImage: filterImage)
        self.evaluateExposure(image: filterImage)
        return filterImage
    }
    
    /**
     The frame of the ocr parsing. It is in locical pixel, relative to the vc's view.
     The frame is used to show the area that will be scanned (if debug = true)
     The real scan area is converted to a coordinate relative to the final image (fullhd frame)
     */
    @objc public func setOcrParsingRect(frame: CGRect){
        
        let videoFrameSize : CGSize = CGSize(width: 1080, height: 1920)
        
        let scale : CGFloat = UIScreen.main.scale
        
        let x : CGFloat = (frame.origin.x * scale * videoFrameSize.width) / (self.view.frame.size.width * scale)
        let y : CGFloat = (frame.origin.y * scale * videoFrameSize.height) / (self.view.frame.size.height * scale)
        
        let w : CGFloat = (frame.size.width  * scale * videoFrameSize.width) / (self.view.frame.size.width  * scale)
        let h : CGFloat = (frame.size.height * scale * videoFrameSize.height) / (self.view.frame.size.height * scale)
        
        self.ocrParsingRect = CGRect(x: x, y: y, width: w, height: h)
        
        crop.cropSizeInPixels = Size(width: Float(ocrParsingRect.size.width), height: Float(ocrParsingRect.size.height))
        crop.locationOfCropInPixels = Position(Float(ocrParsingRect.origin.x), Float(ocrParsingRect.origin.y), nil)
        self.tesseract.rect = CGRect(x: 0, y: 0, width: ocrParsingRect.size.height / 2, height: ocrParsingRect.size.width / 2)
        
    }
    
    func getOcrParsingRectDebugView() -> CGRect{
        let videoFrameSize : CGSize = CGSize(width: 1920, height: 1080)
        
        let h = (self.ocrParsingRect.size.height / videoFrameSize.height) * renderView.frame.size.height
        let w = (self.ocrParsingRect.size.width / videoFrameSize.width) * renderView.frame.size.width
        let x = (self.ocrParsingRect.origin.x / videoFrameSize.width) * renderView.frame.size.width
        let y = (self.ocrParsingRect.origin.y / videoFrameSize.height) * renderView.frame.size.height
        
        return CGRect(x: y, y: x, width: h, height: w)
    }
    
    
    private func startCapturing() {
        self.setup()
        
        if camera == nil {
            self.initCamera()
        }
        
        camera.startCapture()
    }
    
    @objc public func startScanning() {
        if !isAutoMode {
            self.currentCountPerSession = 0
            scanning()
        }
    }
    
    private func scanning() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let strongSelf = self else { return }
            //print("Start OCR")
            strongSelf.pictureOutput = PictureOutput()
            strongSelf.pictureOutput.encodedImageFormat = .png
            strongSelf.pictureOutput.onlyCaptureNextFrame = true
            strongSelf.pictureOutput.imageAvailableCallback = { sourceImage in
                DispatchQueue.global().async() { [weak self] in
                    guard let strongSelf = self else { return }
                    if strongSelf.processImage(sourceImage: sourceImage) { return }
                    // Not successful, start another scan
                    if strongSelf.isAutoMode || strongSelf.shotsCountPerSession > strongSelf.currentCountPerSession {
                        strongSelf.currentCountPerSession = strongSelf.currentCountPerSession + 1
                        strongSelf.scanning()
                    }
                }
            }
            strongSelf.crop --> strongSelf.pictureOutput
        }
    }
    
    @objc public func stopScan() {
        camera.stopCapture()
        abortScan()
        clearRenderView()
    }
    
    private func clearRenderView() {
        let subviews = renderView.subviews
        for view in subviews {
            view.removeFromSuperview()
        }
    }
    
    /**
     call this from your code to stop a scan or hook it to a button
     
     :param: sender the sender of this event
     */
    @IBAction open func StopScan(sender: AnyObject) {
        self.stopScan()
    }
    
    /**
     Processing the image
     
     - parameter sourceImage: The image that needs to be processed
     */
    open func processImage(sourceImage: UIImage) -> Bool {
        
        // resize image. Smaller images are faster to process. When letters are too big the scan quality also goes down.
        let croppedImage: UIImage = sourceImage.resizedImageToFit(in: CGSize(width: ocrParsingRect.size.width * 0.5, height: ocrParsingRect.size.height * 0.5), scaleIfSmaller: true)
        
        // rotate image. tesseract needs the correct orientation.
        // let image: UIImage = croppedImage.rotate(by: -90)!
        // strange... this rotate will cause 1/2 the image to be skipped
        
        // Rotate cropped image
        let selectedFilter = GPUImageTransformFilter()
        selectedFilter.setInputRotation(kGPUImageRotateLeft, at: 0)
        let image: UIImage = selectedFilter.image(byFilteringImage: croppedImage)
        
        // Perform the OCR scan
        let result = self.doOCR(image: image)
        
        // Create the MRZ object and validate if it's OK
        var mrz: MRZParser
        
        if mrzType == MRZType.auto {
            mrz = MRZTD1(scan: result, debug: self.debug)
            if  mrz.isValid() < self.accuracy {
                mrz = MRZTD3(scan: result, debug: self.debug)
            }
        } else if mrzType == MRZType.td1 {
            mrz = MRZTD1(scan: result, debug: self.debug)
        } else {
            mrz = MRZTD3(scan: result, debug: self.debug)
        }
        
        if  mrz.isValid() < self.accuracy {
            print("Scan quality insufficient : \(mrz.isValid())")
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }
                
                strongSelf.clearRenderView()
                strongSelf.camera.stopCapture()
                strongSelf.successfulScan(mrz: mrz)
            }
            return true
        }
        return false
    }
    
    /**
     Perform the tesseract OCR on an image.
     
     - parameter image: The image to be scanned
     
     - returns: The OCR result
     */
    open func doOCR(image: UIImage) -> String {
        // Start OCR
        self.tesseract.image = image
        
        print("- Start recognize")
        self.tesseract.recognize()
        let result = self.tesseract.recognizedText
        
        print("Scan result : \(result ?? "")")
        return result ?? ""
    }
    
    /**
     Override this function in your own class for processing the result
     
     :param: mrz The MRZ result
     */
    open func successfulScan(mrz: MRZParser) {
        if let success = self.scannerDidCompleteWith {
            success(mrz)
        } else {
            assertionFailure("You should overwrite this function to handle the scan results")
        }
    }
    
    /**
     Override this function in your own class for processing a cancel
     */
    open func abortScan() {
        if let abort = self.scannerDidCompleteWith {
            abort(nil)
        } else {
            assertionFailure("You should overwrite this function to handle an abort")
        }
    }
}

// Wanted to use this rotation function. Tesseract does not like the result image.
// Went back to GpuImage for the rotation.
// Will try again later so that we can remove the old GpuImage dependency
@available(iOS 10.0, *)
extension UIImage {
    func rotate(by degrees: Double) -> UIImage? {
        guard let cgImage = self.cgImage else { return nil }
        
        let transform = CGAffineTransform(rotationAngle: CGFloat(degrees * .pi / 180.0))
        var rect = CGRect(origin: .zero, size: self.size).applying(transform)
        rect.origin = .zero
        
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        
        return renderer.image { renderContext in
            renderContext.cgContext.translateBy(x: rect.midX, y: rect.midY)
            renderContext.cgContext.rotate(by: CGFloat(degrees * .pi / 180.0))
            renderContext.cgContext.scaleBy(x: 1.0, y: -1.0)
            
            let drawRect = CGRect(origin: CGPoint(x: -self.size.width/2, y: -self.size.height/2), size: self.size)
            renderContext.cgContext.draw(cgImage, in: drawRect)
        }
    }
}
