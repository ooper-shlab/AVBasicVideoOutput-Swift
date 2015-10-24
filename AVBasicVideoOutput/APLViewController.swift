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
    
    override func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        return .Landscape
    }
    
}

@objc(APLViewController)
class APLViewController: UIViewController, AVPlayerItemOutputPullDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIPopoverControllerDelegate, UIGestureRecognizerDelegate {
    private dynamic var player: AVPlayer!
    private var _myVideoOutputQueue: dispatch_queue_t!
    private var _notificationToken: AnyObject?
    private var _timeObserver: AnyObject?
    
    @IBOutlet weak var playerView: APLEAGLView!
    @IBOutlet weak var chromaLevelSlider: UISlider!
    @IBOutlet weak var lumaLevelSlider: UISlider!
    @IBOutlet weak var currentTime: UILabel!
    @IBOutlet weak var timeView: UIView!
    @IBOutlet weak var toolbar: UIToolbar!
    private var popover: UIPopoverController?
    
    private var videoOutput: AVPlayerItemVideoOutput!
    private var displayLink: CADisplayLink!
    
    
    //MARK: -
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.playerView.lumaThreshold = self.lumaLevelSlider.value
        self.playerView.chromaThreshold = self.chromaLevelSlider.value
        
        player = AVPlayer()
        self.addTimeObserverToPlayer()
        
        // Setup CADisplayLink which will callback displayPixelBuffer: at every vsync.
        self.displayLink = CADisplayLink(target: self, selector: "displayLinkCallback:")
        self.displayLink.addToRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)
        self.displayLink.paused = true
        
        // Setup AVPlayerItemVideoOutput with the required pixelbuffer attributes.
        let pixBuffAttributes: [String : AnyObject] = [kCVPixelBufferPixelFormatTypeKey as String :  Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixBuffAttributes)
        _myVideoOutputQueue = dispatch_queue_create("myVideoOutputQueue", DISPATCH_QUEUE_SERIAL)
        self.videoOutput.setDelegate(self, queue: _myVideoOutputQueue)
    }
    
    override func viewWillAppear(animated: Bool) {
        self.addObserver(self, forKeyPath: "player.currentItem.status", options: .New, context: &AVPlayerItemStatusContext)
        self.addTimeObserverToPlayer()
        
        super.viewWillAppear(animated)
    }
    
    override func viewWillDisappear(animated: Bool) {
        self.removeObserver(self, forKeyPath: "player.currentItem.status", context: &AVPlayerItemStatusContext)
        self.removeTimeObserverFromPlayer()
        
        if let token = _notificationToken {
            NSNotificationCenter.defaultCenter().removeObserver(token, name: AVPlayerItemDidPlayToEndTimeNotification, object: player.currentItem)
            _notificationToken = nil
        }
        
        super.viewWillDisappear(animated)
    }
    
    //MARK: - Utilities
    
    @IBAction func updateLevels(sender: UIControl) {
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
    
    @IBAction func loadMovieFromCameraRoll(sender: UIBarButtonItem) {
        player.pause()
        self.displayLink.paused = true
        
        if self.popover?.popoverVisible ?? false {
            self.popover?.dismissPopoverAnimated(true)
        }
        // Initialize UIImagePickerController to select a movie from the camera roll
        let videoPicker = APLImagePickerController()
        videoPicker.delegate = self
        videoPicker.modalPresentationStyle = .CurrentContext
        videoPicker.sourceType = .SavedPhotosAlbum
        videoPicker.mediaTypes = [kUTTypeMovie as String]
        
        if UIDevice.currentDevice().userInterfaceIdiom == .Pad {
            self.popover = UIPopoverController(contentViewController: videoPicker)
            self.popover!.delegate = self
            self.popover!.presentPopoverFromBarButtonItem(sender, permittedArrowDirections: .Down, animated: true)
        } else {
            self.presentViewController(videoPicker, animated: true, completion: nil)
        }
    }
    
    @IBAction func handleTapGesture(tapGestureRecognizer: UITapGestureRecognizer) {
        self.toolbar.hidden = !self.toolbar.hidden
    }
    
    override func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        return .Landscape
    }
    
    //MARK: - Playback setup
    
    private func setupPlaybackForURL(URL: NSURL) {
        /*
        Sets up player item and adds video output to it.
        The tracks property of an asset is loaded via asynchronous key value loading, to access the preferred transform of a video track used to orientate the video while rendering.
        After adding the video output, we request a notification of media change in order to restart the CADisplayLink.
        */
        
        // Remove video output from old item, if any.
        player.currentItem?.removeOutput(self.videoOutput)
        
        let item = AVPlayerItem(URL: URL)
        let asset = item.asset
        
        asset.loadValuesAsynchronouslyForKeys(["tracks"]) {
            
            if asset.statusOfValueForKey("tracks", error: nil) == .Loaded {
                let tracks = asset.tracksWithMediaType(AVMediaTypeVideo)
                if !tracks.isEmpty {
                    // Choose the first video track.
                    let videoTrack = tracks[0]
                    videoTrack.loadValuesAsynchronouslyForKeys(["preferredTransform"]) {
                        
                        if videoTrack.statusOfValueForKey("preferredTransform", error: nil) == .Loaded {
                            let preferredTransform = videoTrack.preferredTransform
                            
                            /*
                            The orientation of the camera while recording affects the orientation of the images received from an AVPlayerItemVideoOutput. Here we compute a rotation that is used to correctly orientate the video.
                            */
                            self.playerView.preferredRotation = -1 * atan2(preferredTransform.b, preferredTransform.a).f
                            
                            self.addDidPlayToEndTimeNotificationForPlayerItem(item)
                            
                            dispatch_async(dispatch_get_main_queue()) {
                                item.addOutput(self.videoOutput)
                                self.player.replaceCurrentItemWithPlayerItem(item)
                                self.videoOutput.requestNotificationOfMediaDataChangeWithAdvanceInterval(ONE_FRAME_DURATION)
                                self.player.play()
                            }
                            
                        }
                        
                    }
                }
            }
            
        }
        
    }
    
    private func stopLoadingAnimationAndHandleError(error: NSError?) {
        guard let error = error else {return}
        let cancelButtonTitle =  NSLocalizedString("OK", comment: "Cancel button title for animation load error")
        if #available(iOS 8.0, *) {
            let alertController = UIAlertController(title: error.localizedDescription, message: error.localizedFailureReason, preferredStyle: .Alert)
            let action = UIAlertAction(title: cancelButtonTitle, style: .Cancel, handler: nil)
            alertController.addAction(action)
            self.presentViewController(alertController, animated: true, completion: nil)
        } else {
            let alertView = UIAlertView(title: error.localizedDescription, message: error.localizedFailureReason, delegate: nil, cancelButtonTitle: cancelButtonTitle)
            alertView.show()
        }
    }
    
    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        if context == &AVPlayerItemStatusContext {
            if let status = AVPlayerStatus(rawValue: change![NSKeyValueChangeNewKey] as! Int) {
                switch status {
                case .Unknown:
                    break
                case .ReadyToPlay:
                    self.playerView.presentationRect = player.currentItem!.presentationSize
                case .Failed:
                    self.stopLoadingAnimationAndHandleError(player.currentItem!.error)
                }
            } else {
                fatalError("Invalid value for NSKeyValueChangeNewKey: \(change![NSKeyValueChangeNewKey])")
            }
        } else {
            super.observeValueForKeyPath(keyPath, ofObject: object, change: change, context: context)
        }
    }
    
    private func addDidPlayToEndTimeNotificationForPlayerItem(item: AVPlayerItem) {
        
        /*
        Setting actionAtItemEnd to None prevents the movie from getting paused at item end. A very simplistic, and not gapless, looped playback.
        */
        player.actionAtItemEnd = .None
        _notificationToken = NSNotificationCenter.defaultCenter().addObserverForName(AVPlayerItemDidPlayToEndTimeNotification, object: item, queue: NSOperationQueue.mainQueue()) {note in
            // Simple item playback rewind.
            self.player.currentItem?.seekToTime(kCMTimeZero)
        }
    }
    
    private func syncTimeLabel() {
        var seconds = CMTimeGetSeconds(player.currentTime())
        if !isfinite(seconds) {
            seconds = 0
        }
        
        var secondsInt = Int32(round(seconds))
        let minutes = secondsInt/60
        secondsInt -= minutes*60
        
        self.currentTime.textColor = UIColor(white: 1.0, alpha: 1.0)
        self.currentTime.textAlignment = .Center
        
        self.currentTime.text = String(format: "%.2i:%.2i", minutes, secondsInt)
    }
    
    private func addTimeObserverToPlayer() {
        /*
        Adds a time observer to the player to periodically refresh the time label to reflect current time.
        */
        if _timeObserver != nil {
            return
        }
        /*
        Use __weak reference to self to ensure that a strong reference cycle is not formed between the view controller, player and notification block.
        */
        _timeObserver = player.addPeriodicTimeObserverForInterval(CMTimeMakeWithSeconds(1, 10), queue: dispatch_get_main_queue()) {[weak self] time in
            self?.syncTimeLabel()
        }
    }
    
    private func removeTimeObserverFromPlayer() {
        if _timeObserver != nil {
            player.removeTimeObserver(_timeObserver!)
            _timeObserver = nil
        }
    }
    
    //MARK: - CADisplayLink Callback
    
    func displayLinkCallback(sender: CADisplayLink) {
        /*
        The callback gets called once every Vsync.
        Using the display link's timestamp and duration we can compute the next time the screen will be refreshed, and copy the pixel buffer for that time
        This pixel buffer can then be processed and later rendered on screen.
        */
        var outputItemTime = kCMTimeInvalid
        
        // Calculate the nextVsync time which is when the screen will be refreshed next.
        let nextVSync = (sender.timestamp + sender.duration)
        
        outputItemTime = self.videoOutput.itemTimeForHostTime(nextVSync)
        
        if self.videoOutput.hasNewPixelBufferForItemTime(outputItemTime) {
            let pixelBuffer = self.videoOutput.copyPixelBufferForItemTime(outputItemTime, itemTimeForDisplay: nil)
            
            self.playerView.displayPixelBuffer(pixelBuffer)
            
        }
    }
    
    //MARK: - AVPlayerItemOutputPullDelegate
    
    func outputMediaDataWillChange(sender: AVPlayerItemOutput) {
        // Restart display link.
        self.displayLink.paused = false
    }
    
    //MARK: - Image Picker Controller Delegate
    
    func imagePickerController(picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String : AnyObject]) {
        if UIDevice.currentDevice().userInterfaceIdiom == .Pad {
            self.popover?.dismissPopoverAnimated(true)
        } else {
            self.dismissViewControllerAnimated(true, completion: nil)
        }
        
        if player.currentItem == nil {
            self.lumaLevelSlider.enabled = true
            self.chromaLevelSlider.enabled = true
            self.playerView.setupGL()
        }
        
        // Time label shows the current time of the item.
        if self.timeView.hidden {
            self.timeView.layer.backgroundColor = UIColor(white: 0.0, alpha: 0.3).CGColor
            self.timeView.layer.cornerRadius = 5.0
            self.timeView.layer.borderColor = UIColor(white: 1.0, alpha: 0.15).CGColor
            self.timeView.layer.borderWidth = 1.0
            self.timeView.hidden = false
            self.currentTime.hidden = false
        }
        
        self.setupPlaybackForURL(info[UIImagePickerControllerReferenceURL] as! NSURL)
        
        picker.delegate = nil
    }
    
    func imagePickerControllerDidCancel(picker: UIImagePickerController) {
        self.dismissViewControllerAnimated(true, completion: nil)
        
        // Make sure our playback is resumed from any interruption.
        if let item = player.currentItem {
            self.addDidPlayToEndTimeNotificationForPlayerItem(item)
        }
        
        self.videoOutput.requestNotificationOfMediaDataChangeWithAdvanceInterval(ONE_FRAME_DURATION)
        player.play()
        
        picker.delegate = nil
    }
    
    //MARK: - Popover Controller Delegate
    
    func popoverControllerDidDismissPopover(popoverController: UIPopoverController) {
        // Make sure our playback is resumed from any interruption.
        if let item = player.currentItem {
            self.addDidPlayToEndTimeNotificationForPlayerItem(item)
        }
        self.videoOutput.requestNotificationOfMediaDataChangeWithAdvanceInterval(ONE_FRAME_DURATION)
        player.play()
        
        self.popover?.delegate = nil
    }
    
    //MARK: - Gesture recognizer delegate
    
    func gestureRecognizer(gestureRecognizer: UIGestureRecognizer, shouldReceiveTouch touch: UITouch) -> Bool {
        // Ignore touch on toolbar.
        return touch.view === self.view
    }
    
}