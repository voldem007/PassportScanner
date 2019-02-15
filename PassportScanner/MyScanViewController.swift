//
//  MyScanViewController.swift
//  PassportOCR
//
//  Created by Edwin Vermeer on 9/7/15.
//  Copyright (c) 2015 mirabeau. All rights reserved.
//

import Foundation

protocol ProcessMRZ {
    func processMRZ(mrz:MRZParser)
}

class MyScanViewController: PassportScannerController {
    
    /// Delegate set by the calling controler so that we can pass on ProcessMRZ events.
    var delegate: ProcessMRZ?
    
    lazy var scanButton: UIButton = {
        let button = UIButton(frame: CGRect(x: 10, y: 10, width: 40, height: 40))
        button.backgroundColor = .blue
        button.addTarget(self, action:#selector(self.buttonClicked), for: .touchUpInside)
        return button
    }()
    
    override func viewDidLoad() {
        super.viewDidLoad();
        debug = true // So that we can see what's going on (scan text and quality indicator)
        accuracy = 0.8//1  // 1 = all checksums should pass (is the default so we could skip this line)
        isAutoMode = false
        mrzType = .auto // Performs a little better when set to td1 or td3
        showPostProcessingFilters = false// true // Set this to true to to give you a good indication of the scan quality
        
        view.addSubview(scanButton)
    }
    
    @objc func buttonClicked() {
         self.startScan()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.bringSubviewToFront(scanButton)
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscapeRight
    }
    
    override var shouldAutorotate: Bool {
        return true
    }
    
    /**
    Called by the PassportScannerController when there was a succesfull scan
    
    :param: mrz The scanned MRZ
    */
    override func successfulScan(mrz: MRZParser) {
        print("mrz: {\(mrz.description)\n}")
        delegate?.processMRZ(mrz: mrz)
        self.dismiss(animated: true, completion: nil)
    }

    /**
    Called by the PassportScannerController when the 'close' button was pressed.
    */
    override func abortScan() {
        self.dismiss(animated: true, completion: nil)
    }
}
