//
//  APLViewController.swift
//  AVBasicVideoOutput
//
//  Created by 開発 on 2015/10/3.
//  Copyright © 2015 Apple. All rights reserved.
//
/*
    Copyright (C) 2015 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information

    Abstract:
    This view controller handles the UI to load assets for playback and for adjusting the luma and chroma values. It also sets up the AVPlayerItemVideoOutput, from which CVPixelBuffers are pulled out and sent to the shaders for rendering.
*/

import UIKit
import AVFoundation
import MobileCoreServices

private let ONE_FRAME_DURATION = 0.03
private let LUMA_SLIDER_TAG = 0
private let CHROMA_SLIDER_TAG = 1

private var AVPlayerItemStatusContext: Int = Int()

@objc(APLImagePickerController)
class APLImagePickerController: UIImagePickerController {
    
    override var supportedInterfaceOrientations : UIInterfaceOrientationMask {
        return .landscape
    }
    
}

@objc(APLViewController)
class APLViewController: UIViewController, AVPlayerItemOutputPullDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIPopoverControllerDelegate, UIGestureRecognizerDelegate {
    fileprivate dynamic var player: AVPlayer!
    fileprivate var _myVideoOutputQueue: DispatchQueue!
    fileprivate var _notificationToken: AnyObject?
    fileprivate var _timeObserver: AnyObject?
    
    @IBOutlet weak var playerView: APLEAGLView!
    @IBOutlet weak var chromaLevelSlider: UISlider!
    @IBOutlet weak var lumaLevelSlider: UISlider!
    @IBOutlet weak var currentTime: UILabel!
    @IBOutlet weak var timeView: UIView!
    @IBOutlet weak var toolbar: UIToolbar!
    fileprivate var popover: UIPopoverController?
    
    fileprivate var videoOutput: AVPlayerItemVideoOutput!
    fileprivate var displayLink: CADisplayLink!
    
    
    //MARK: -
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.playerView.lumaThreshold = self.lumaLevelSlider.value
        self.playerView.chromaThreshold = self.chromaLevelSlider.value
        
        player = AVPlayer()
        self.addTimeObserverToPlayer()
        
        // Setup CADisplayLink which will callback displayPixelBuffer: at every vsync.
        self.displayLink = CADisplayLink(target: self, selector: #selector(APLViewController.displayLinkCallback(_:)))
        self.displayLink.add(to: RunLoop.current, forMode: RunLoopMode.defaultRunLoopMode)
        self.displayLink.isPaused = true
        
        // Setup AVPlayerItemVideoOutput with the required pixelbuffer attributes.
        let pixBuffAttributes: [String : AnyObject] = [kCVPixelBufferPixelFormatTypeKey as String :  Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) as AnyObject]
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixBuffAttributes)
        _myVideoOutputQueue = DispatchQueue(label: "myVideoOutputQueue", attributes: [])
        self.videoOutput.setDelegate(self, queue: _myVideoOutputQueue)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        self.addObserver(self, forKeyPath: "player.currentItem.status", options: .new, context: &AVPlayerItemStatusContext)
        self.addTimeObserverToPlayer()
        
        super.viewWillAppear(animated)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        self.removeObserver(self, forKeyPath: "player.currentItem.status", context: &AVPlayerItemStatusContext)
        self.removeTimeObserverFromPlayer()
        
        if let token = _notificationToken {
            NotificationCenter.default.removeObserver(token, name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: player.currentItem)
            _notificationToken = nil
        }
        
        super.viewWillDisappear(animated)
    }
    
    //MARK: - Utilities
    
    @IBAction func updateLevels(_ sender: UIControl) {
        let tag = sender.tag
        
        switch tag {
        case LUMA_SLIDER_TAG:
            self.playerView.lumaThreshold = self.lumaLevelSlider.value
        case CHROMA_SLIDER_TAG:
            self.playerView.chromaThreshold = self.chromaLevelSlider.value
            
        default:
            break
        }
    }
    
    @IBAction func loadMovieFromCameraRoll(_ sender: UIBarButtonItem) {
        player.pause()
        self.displayLink.isPaused = true
        
        if self.popover?.isPopoverVisible ?? false {
            self.popover?.dismiss(animated: true)
        }
        // Initialize UIImagePickerController to select a movie from the camera roll
        let videoPicker = APLImagePickerController()
        videoPicker.delegate = self
        videoPicker.modalPresentationStyle = .currentContext
        videoPicker.sourceType = .savedPhotosAlbum
        videoPicker.mediaTypes = [kUTTypeMovie as String]
        
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.popover = UIPopoverController(contentViewController: videoPicker)
            self.popover!.delegate = self
            self.popover!.present(from: sender, permittedArrowDirections: .down, animated: true)
        } else {
            self.present(videoPicker, animated: true, completion: nil)
        }
    }
    
    @IBAction func handleTapGesture(_ tapGestureRecognizer: UITapGestureRecognizer) {
        self.toolbar.isHidden = !self.toolbar.isHidden
    }
    
    override var supportedInterfaceOrientations : UIInterfaceOrientationMask {
        return .landscape
    }
    
    //MARK: - Playback setup
    
    fileprivate func setupPlaybackForURL(_ URL: Foundation.URL) {
        /*
        Sets up player item and adds video output to it.
        The tracks property of an asset is loaded via asynchronous key value loading, to access the preferred transform of a video track used to orientate the video while rendering.
        After adding the video output, we request a notification of media change in order to restart the CADisplayLink.
        */
        
        // Remove video output from old item, if any.
        player.currentItem?.remove(self.videoOutput)
        
        let item = AVPlayerItem(url: URL)
        let asset = item.asset
        
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            
            if asset.statusOfValue(forKey: "tracks", error: nil) == .loaded {
                let tracks = asset.tracks(withMediaType: AVMediaTypeVideo)
                if !tracks.isEmpty {
                    // Choose the first video track.
                    let videoTrack = tracks[0]
                    videoTrack.loadValuesAsynchronously(forKeys: ["preferredTransform"]) {
                        
                        if videoTrack.statusOfValue(forKey: "preferredTransform", error: nil) == .loaded {
                            let preferredTransform = videoTrack.preferredTransform
                            
                            /*
                            The orientation of the camera while recording affects the orientation of the images received from an AVPlayerItemVideoOutput. Here we compute a rotation that is used to correctly orientate the video.
                            */
                            self.playerView.preferredRotation = -1 * atan2(preferredTransform.b, preferredTransform.a).f
                            
                            self.addDidPlayToEndTimeNotificationForPlayerItem(item)
                            
                            DispatchQueue.main.async {
                                item.add(self.videoOutput)
                                self.player.replaceCurrentItem(with: item)
                                self.videoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: ONE_FRAME_DURATION)
                                self.player.play()
                            }
                            
                        }
                        
                    }
                }
            }
            
        }
        
    }
    
    fileprivate func stopLoadingAnimationAndHandleError(_ error: NSError?) {
        guard let error = error else {return}
        let cancelButtonTitle =  NSLocalizedString("OK", comment: "Cancel button title for animation load error")
        if #available(iOS 8.0, *) {
            let alertController = UIAlertController(title: error.localizedDescription, message: error.localizedFailureReason, preferredStyle: .alert)
            let action = UIAlertAction(title: cancelButtonTitle, style: .cancel, handler: nil)
            alertController.addAction(action)
            self.present(alertController, animated: true, completion: nil)
        } else {
            let alertView = UIAlertView(title: error.localizedDescription, message: error.localizedFailureReason, delegate: nil, cancelButtonTitle: cancelButtonTitle)
            alertView.show()
        }
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if context == &AVPlayerItemStatusContext {
            if let status = AVPlayerStatus(rawValue: change![NSKeyValueChangeKey.newKey] as! Int) {
                switch status {
                case .unknown:
                    break
                case .readyToPlay:
                    self.playerView.presentationRect = player.currentItem!.presentationSize
                case .failed:
                    self.stopLoadingAnimationAndHandleError(player.currentItem!.error as NSError?)
                }
            } else {
                fatalError("Invalid value for NSKeyValueChangeNewKey: \(change![NSKeyValueChangeKey.newKey])")
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    fileprivate func addDidPlayToEndTimeNotificationForPlayerItem(_ item: AVPlayerItem) {
        
        /*
        Setting actionAtItemEnd to None prevents the movie from getting paused at item end. A very simplistic, and not gapless, looped playback.
        */
        player.actionAtItemEnd = .none
        _notificationToken = NotificationCenter.default.addObserver(forName: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: item, queue: OperationQueue.main) {note in
            // Simple item playback rewind.
            self.player.currentItem?.seek(to: kCMTimeZero)
        }
    }
    
    fileprivate func syncTimeLabel() {
        var seconds = CMTimeGetSeconds(player.currentTime())
        if seconds.isFinite {
            seconds = 0
        }
        
        var secondsInt = Int32(round(seconds))
        let minutes = secondsInt/60
        secondsInt -= minutes*60
        
        self.currentTime.textColor = UIColor(white: 1.0, alpha: 1.0)
        self.currentTime.textAlignment = .center
        
        self.currentTime.text = String(format: "%.2i:%.2i", minutes, secondsInt)
    }
    
    fileprivate func addTimeObserverToPlayer() {
        /*
        Adds a time observer to the player to periodically refresh the time label to reflect current time.
        */
        if _timeObserver != nil {
            return
        }
        /*
        Use __weak reference to self to ensure that a strong reference cycle is not formed between the view controller, player and notification block.
        */
        _timeObserver = player.addPeriodicTimeObserver(forInterval: CMTimeMakeWithSeconds(1, 10), queue: DispatchQueue.main) {[weak self] time in
            self?.syncTimeLabel()
        } as AnyObject?
    }
    
    fileprivate func removeTimeObserverFromPlayer() {
        if _timeObserver != nil {
            player.removeTimeObserver(_timeObserver!)
            _timeObserver = nil
        }
    }
    
    //MARK: - CADisplayLink Callback
    
    func displayLinkCallback(_ sender: CADisplayLink) {
        /*
        The callback gets called once every Vsync.
        Using the display link's timestamp and duration we can compute the next time the screen will be refreshed, and copy the pixel buffer for that time
        This pixel buffer can then be processed and later rendered on screen.
        */
        var outputItemTime = kCMTimeInvalid
        
        // Calculate the nextVsync time which is when the screen will be refreshed next.
        let nextVSync = (sender.timestamp + sender.duration)
        
        outputItemTime = self.videoOutput.itemTime(forHostTime: nextVSync)
        
        if self.videoOutput.hasNewPixelBuffer(forItemTime: outputItemTime) {
            let pixelBuffer = self.videoOutput.copyPixelBuffer(forItemTime: outputItemTime, itemTimeForDisplay: nil)
            
            self.playerView.displayPixelBuffer(pixelBuffer)
            
        }
    }
    
    //MARK: - AVPlayerItemOutputPullDelegate
    
    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        // Restart display link.
        self.displayLink.isPaused = false
    }
    
    //MARK: - Image Picker Controller Delegate
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String : Any]) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            self.popover?.dismiss(animated: true)
        } else {
            self.dismiss(animated: true, completion: nil)
        }
        
        if player.currentItem == nil {
            self.lumaLevelSlider.isEnabled = true
            self.chromaLevelSlider.isEnabled = true
            self.playerView.setupGL()
        }
        
        // Time label shows the current time of the item.
        if self.timeView.isHidden {
            self.timeView.layer.backgroundColor = UIColor(white: 0.0, alpha: 0.3).cgColor
            self.timeView.layer.cornerRadius = 5.0
            self.timeView.layer.borderColor = UIColor(white: 1.0, alpha: 0.15).cgColor
            self.timeView.layer.borderWidth = 1.0
            self.timeView.isHidden = false
            self.currentTime.isHidden = false
        }
        
        self.setupPlaybackForURL(info[UIImagePickerControllerReferenceURL] as! URL)
        
        picker.delegate = nil
    }
    
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        self.dismiss(animated: true, completion: nil)
        
        // Make sure our playback is resumed from any interruption.
        if let item = player.currentItem {
            self.addDidPlayToEndTimeNotificationForPlayerItem(item)
        }
        
        self.videoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: ONE_FRAME_DURATION)
        player.play()
        
        picker.delegate = nil
    }
    
    //MARK: - Popover Controller Delegate
    
    func popoverControllerDidDismissPopover(_ popoverController: UIPopoverController) {
        // Make sure our playback is resumed from any interruption.
        if let item = player.currentItem {
            self.addDidPlayToEndTimeNotificationForPlayerItem(item)
        }
        self.videoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: ONE_FRAME_DURATION)
        player.play()
        
        self.popover?.delegate = nil
    }
    
    //MARK: - Gesture recognizer delegate
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Ignore touch on toolbar.
        return touch.view === self.view
    }
    
}
