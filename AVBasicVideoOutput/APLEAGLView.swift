//
//  APLEAGLView.swift
//  AVBasicVideoOutput
//
//  Created by 開発 on 2015/10/3.
//  Copyright © 2015 Apple. All rights reserved.
//
/*
    Copyright (C) 2015 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information

    Abstract:
    This class contains an UIView backed by a CAEAGLLayer. It handles rendering input textures to the view. The object loads, compiles and links the fragment and vertex shader to be used during rendering.
 */

import UIKit
import OpenGLES.ES2

import QuartzCore
import AVFoundation

// Uniform index.
let UNIFORM_Y = 0
let UNIFORM_UV = 1
let UNIFORM_LUMA_THRESHOLD = 2
let UNIFORM_CHROMA_THRESHOLD = 3
let UNIFORM_ROTATION_ANGLE = 4
let UNIFORM_COLOR_CONVERSION_MATRIX = 5
let NUM_UNIFORMS = 6
var uniforms: [GLint] = Array(count: NUM_UNIFORMS, repeatedValue: 0)

// Attribute index.
let ATTRIB_VERTEX = 0
let ATTRIB_TEXCOORD = 1
let NUM_ATTRIBUTES = 2

// Color Conversion Constants (YUV to RGB) including adjustment from 16-235/16-240 (video range)

// BT.601, which is the standard for SDTV.
private var kColorConversion601: [GLfloat] = [
    1.164,  1.164, 1.164,
    0.0, -0.392, 2.017,
    1.596, -0.813,   0.0,
]

// BT.709, which is the standard for HDTV.
private var kColorConversion709: [GLfloat] = [
    1.164,  1.164, 1.164,
    0.0, -0.213, 2.112,
    1.793, -0.533,   0.0,
]

@objc(APLEAGLView)
class APLEAGLView: UIView {
    
    var preferredRotation: GLfloat = 0.0
    var presentationRect: CGSize = CGSize()
    var chromaThreshold: GLfloat = 0.0
    var lumaThreshold: GLfloat = 0.0
    
    // The pixel dimensions of the CAEAGLLayer.
    private var _backingWidth: GLint = 0
    private var _backingHeight: GLint = 0
    
    private var _context: EAGLContext?
    private var _lumaTexture: CVOpenGLESTextureRef?
    private var _chromaTexture: CVOpenGLESTextureRef?
    private var _videoTextureCache: CVOpenGLESTextureCacheRef?
    
    private var _frameBufferHandle: GLuint = 0
    private var _colorBufferHandle: GLuint = 0
    
    private var _preferredConversion: UnsafePointer<GLfloat> = nil
    
    private var program: GLuint = 0
    
    override class func layerClass() -> AnyClass {
        return CAEAGLLayer.self
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        // Use 2x scale factor on Retina displays.
        self.contentScaleFactor = UIScreen.mainScreen().scale
        
        // Get and configure the layer.
        let eaglLayer = self.layer as! CAEAGLLayer
        
        eaglLayer.opaque = true
        eaglLayer.drawableProperties = [kEAGLDrawablePropertyRetainedBacking : false,
            kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8]
        
        // Set the context into which the frames will be drawn.
        _context = EAGLContext(API: EAGLRenderingAPI.OpenGLES2)
        
        if _context == nil || !EAGLContext.setCurrentContext(_context) || !self.loadShaders() {
            return nil
        }
        
        // Set the default conversion to BT.709, which is the standard for HDTV.
        kColorConversion709.withUnsafeBufferPointer {
            //### Expecting this `baseAddress` is stable for global variables.
            _preferredConversion = $0.baseAddress
        }
    }
    
    //MARK: - OpenGL setup
    
    func setupGL() {
        EAGLContext.setCurrentContext(_context)
        self.setupBuffers()
        self.loadShaders()
        
        glUseProgram(self.program)
        
        // 0 and 1 are the texture IDs of _lumaTexture and _chromaTexture respectively.
        glUniform1i(uniforms[UNIFORM_Y], 0)
        glUniform1i(uniforms[UNIFORM_UV], 1)
        glUniform1f(uniforms[UNIFORM_LUMA_THRESHOLD], self.lumaThreshold)
        glUniform1f(uniforms[UNIFORM_CHROMA_THRESHOLD], self.chromaThreshold)
        glUniform1f(uniforms[UNIFORM_ROTATION_ANGLE], self.preferredRotation)
        glUniformMatrix3fv(uniforms[UNIFORM_COLOR_CONVERSION_MATRIX], 1, false, _preferredConversion)
        
        // Create CVOpenGLESTextureCacheRef for optimal CVPixelBufferRef to GLES texture conversion.
        if _videoTextureCache == nil {
            let  err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, _context!, nil, &_videoTextureCache)
            if err != noErr {
                NSLog("Error at CVOpenGLESTextureCacheCreate \(err)")
                return
            }
        }
    }
    
    //MARK: - Utilities
    
    private func setupBuffers() {
        glDisable(GL_DEPTH_TEST.ui)
        
        glEnableVertexAttribArray(ATTRIB_VERTEX.ui)
        glVertexAttribPointer(ATTRIB_VERTEX.ui, 2, GL_FLOAT.ui, false, 2 * sizeof(GLfloat).i, nil)
        
        glEnableVertexAttribArray(ATTRIB_TEXCOORD.ui)
        glVertexAttribPointer(ATTRIB_TEXCOORD.ui, 2, GL_FLOAT.ui, false, 2 * sizeof(GLfloat).i, nil)
        
        glGenFramebuffers(1, &_frameBufferHandle)
        glBindFramebuffer(GL_FRAMEBUFFER.ui, _frameBufferHandle)
        
        glGenRenderbuffers(1, &_colorBufferHandle)
        glBindRenderbuffer(GL_RENDERBUFFER.ui, _colorBufferHandle)
        
        _context?.renderbufferStorage(GL_RENDERBUFFER.l, fromDrawable: self.layer as! CAEAGLLayer)
        glGetRenderbufferParameteriv(GL_RENDERBUFFER.ui, GL_RENDERBUFFER_WIDTH.ui, &_backingWidth)
        glGetRenderbufferParameteriv(GL_RENDERBUFFER.ui, GL_RENDERBUFFER_HEIGHT.ui, &_backingHeight)
        
        glFramebufferRenderbuffer(GL_FRAMEBUFFER.ui, GL_COLOR_ATTACHMENT0.ui, GL_RENDERBUFFER.ui, _colorBufferHandle)
        if glCheckFramebufferStatus(GL_FRAMEBUFFER.ui) != GL_FRAMEBUFFER_COMPLETE.ui {
            NSLog("Failed to make complete framebuffer object %x", glCheckFramebufferStatus(GL_FRAMEBUFFER.ui))
        }
    }
    
    private func cleanUpTextures() {
        _lumaTexture = nil
        
        _chromaTexture = nil
        
        // Periodic texture cache flush every frame
        if _videoTextureCache != nil {
            CVOpenGLESTextureCacheFlush(_videoTextureCache!, 0)
        }
    }
    
    deinit {
        self.cleanUpTextures()
        
    }
    
    //MARK: - OpenGLES drawing
    
    func displayPixelBuffer(pixelBuffer: CVPixelBufferRef?) {
        var err: CVReturn = noErr
        if let buffer = pixelBuffer {
            let frameWidth = CVPixelBufferGetWidth(buffer)
            let frameHeight = CVPixelBufferGetHeight(buffer)
            
            if _videoTextureCache == nil {
                NSLog("No video texture cache")
                return
            }
            
            self.cleanUpTextures()
            
            
            /*
            Use the color attachment of the pixel buffer to determine the appropriate color conversion matrix.
            */
            let colorAttachments = CVBufferGetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue() as? NSString
            
            if colorAttachments == kCVImageBufferYCbCrMatrix_ITU_R_601_4 {
                kColorConversion601.withUnsafeBufferPointer {
                    //### Expecting this `baseAddress` is stable for global variables.
                    _preferredConversion = $0.baseAddress
                }
            } else {
                kColorConversion709.withUnsafeBufferPointer {
                    //### Expecting this `baseAddress` is stable for global variables.
                    _preferredConversion = $0.baseAddress
                }
            }
            
            /*
            CVOpenGLESTextureCacheCreateTextureFromImage will create GLES texture optimally from CVPixelBufferRef.
            */
            
            /*
            Create Y and UV textures from the pixel buffer. These textures will be drawn on the frame buffer Y-plane.
            */
            glActiveTexture(GL_TEXTURE0.ui)
            err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                _videoTextureCache!,
                buffer,
                nil,
                GL_TEXTURE_2D.ui,
                GL_RED_EXT,
                frameWidth.i,
                frameHeight.i,
                GL_RED_EXT.ui,
                GL_UNSIGNED_BYTE.ui,
                0,
                &_lumaTexture)
            if err != 0 {
                NSLog("Error at CVOpenGLESTextureCacheCreateTextureFromImage \(err)")
            }
            
            glBindTexture(CVOpenGLESTextureGetTarget(_lumaTexture!), CVOpenGLESTextureGetName(_lumaTexture!))
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MIN_FILTER.ui, GL_LINEAR)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MAG_FILTER.ui, GL_LINEAR)
            glTexParameterf(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_S.ui, GL_CLAMP_TO_EDGE.f)
            glTexParameterf(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_T.ui, GL_CLAMP_TO_EDGE.f)
            
            // UV-plane.
            glActiveTexture(GL_TEXTURE1.ui)
            err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                _videoTextureCache!,
                buffer,
                nil,
                GL_TEXTURE_2D.ui,
                GL_RG_EXT,
                frameWidth.i / 2,
                frameHeight.i / 2,
                GL_RG_EXT.ui,
                GL_UNSIGNED_BYTE.ui,
                1,
                &_chromaTexture)
            if err != 0 {
                NSLog("Error at CVOpenGLESTextureCacheCreateTextureFromImage \(err)")
            }
            
            glBindTexture(CVOpenGLESTextureGetTarget(_chromaTexture!), CVOpenGLESTextureGetName(_chromaTexture!))
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MIN_FILTER.ui, GL_LINEAR)
            glTexParameteri(GL_TEXTURE_2D.ui, GL_TEXTURE_MAG_FILTER.ui, GL_LINEAR)
            glTexParameterf(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_S.ui, GL_CLAMP_TO_EDGE.f)
            glTexParameterf(GL_TEXTURE_2D.ui, GL_TEXTURE_WRAP_T.ui, GL_CLAMP_TO_EDGE.f)
            
            glBindFramebuffer(GL_FRAMEBUFFER.ui, _frameBufferHandle)
            
            // Set the view port to the entire view.
            glViewport(0, 0, _backingWidth, _backingHeight)
        }
        
        glClearColor(0.0, 0.0, 0.0, 1.0)
        glClear(GL_COLOR_BUFFER_BIT.ui)
        
        // Use shader program.
        glUseProgram(self.program)
        glUniform1f(uniforms[UNIFORM_LUMA_THRESHOLD], self.lumaThreshold)
        glUniform1f(uniforms[UNIFORM_CHROMA_THRESHOLD], self.chromaThreshold)
        glUniform1f(uniforms[UNIFORM_ROTATION_ANGLE], self.preferredRotation)
        glUniformMatrix3fv(uniforms[UNIFORM_COLOR_CONVERSION_MATRIX], 1, false, _preferredConversion)
        
        // Set up the quad vertices with respect to the orientation and aspect ratio of the video.
        let vertexSamplingRect = AVMakeRectWithAspectRatioInsideRect(self.presentationRect, self.layer.bounds)
        
        // Compute normalized quad coordinates to draw the frame into.
        var normalizedSamplingSize = CGSizeMake(0.0, 0.0)
        let cropScaleAmount = CGSizeMake(vertexSamplingRect.size.width/self.layer.bounds.size.width, vertexSamplingRect.size.height/self.layer.bounds.size.height)
        
        // Normalize the quad vertices.
        if cropScaleAmount.width > cropScaleAmount.height {
            normalizedSamplingSize.width = 1.0
            normalizedSamplingSize.height = cropScaleAmount.height/cropScaleAmount.width
        } else {
            normalizedSamplingSize.width = 1.0
            normalizedSamplingSize.height = cropScaleAmount.width/cropScaleAmount.height
        }
        
        /*
        The quad vertex data defines the region of 2D plane onto which we draw our pixel buffers.
        Vertex data formed using (-1,-1) and (1,1) as the bottom left and top right coordinates respectively, covers the entire screen.
        */
        let quadVertexData: [GLfloat] = [
            -1 * normalizedSamplingSize.width.f, -1 * normalizedSamplingSize.height.f,
            normalizedSamplingSize.width.f, -1 * normalizedSamplingSize.height.f,
            -1 * normalizedSamplingSize.width.f, normalizedSamplingSize.height.f,
            normalizedSamplingSize.width.f, normalizedSamplingSize.height.f,
        ]
        
        // Update attribute values.
        glVertexAttribPointer(ATTRIB_VERTEX.ui, 2, GL_FLOAT.ui, 0, 0, quadVertexData)
        glEnableVertexAttribArray(ATTRIB_VERTEX.ui)
        
        /*
        The texture vertices are set up such that we flip the texture vertically. This is so that our top left origin buffers match OpenGL's bottom left texture coordinate system.
        */
        let textureSamplingRect = CGRectMake(0, 0, 1, 1)
        let quadTextureData: [GLfloat] = [
            CGRectGetMinX(textureSamplingRect).f, CGRectGetMaxY(textureSamplingRect).f,
            CGRectGetMaxX(textureSamplingRect).f, CGRectGetMaxY(textureSamplingRect).f,
            CGRectGetMinX(textureSamplingRect).f, CGRectGetMinY(textureSamplingRect).f,
            CGRectGetMaxX(textureSamplingRect).f, CGRectGetMinY(textureSamplingRect).f
        ]
        
        glVertexAttribPointer(ATTRIB_TEXCOORD.ui, 2, GL_FLOAT.ui, 0, 0, quadTextureData)
        glEnableVertexAttribArray(ATTRIB_TEXCOORD.ui)
        
        glDrawArrays(GL_TRIANGLE_STRIP.ui, 0, 4)
        
        glBindRenderbuffer(GL_RENDERBUFFER.ui, _colorBufferHandle)
        _context?.presentRenderbuffer(GL_RENDERBUFFER.l)
    }
    
    //MARK: -  OpenGL ES 2 shader compilation
    
    private func loadShaders() -> Bool {
        var vertShader: GLuint = 0
        var fragShader: GLuint = 0
        
        // Create the shader program.
        self.program = glCreateProgram()
        
        // Create and compile the vertex shader.
        let vertShaderURL = NSBundle.mainBundle().URLForResource("Shader", withExtension: "vsh")!
        guard self.compileShader(&vertShader, type: GL_VERTEX_SHADER.ui, URL: vertShaderURL) else {
            NSLog("Failed to compile vertex shader")
            return false
        }
        
        // Create and compile fragment shader.
        let fragShaderURL = NSBundle.mainBundle().URLForResource("Shader", withExtension: "fsh")!
        guard self.compileShader(&fragShader, type: GL_FRAGMENT_SHADER.ui, URL: fragShaderURL) else {
            NSLog("Failed to compile fragment shader")
            return false
        }
        
        // Attach vertex shader to program.
        glAttachShader(self.program, vertShader)
        
        // Attach fragment shader to program.
        glAttachShader(self.program, fragShader)
        
        // Bind attribute locations. This needs to be done prior to linking.
        glBindAttribLocation(self.program, ATTRIB_VERTEX.ui, "position")
        glBindAttribLocation(self.program, ATTRIB_TEXCOORD.ui, "texCoord")
        
        // Link the program.
        if !self.linkProgram(self.program) {
            NSLog("Failed to link program: \(self.program)")
            
            if vertShader != 0 {
                glDeleteShader(vertShader)
                vertShader = 0
            }
            if fragShader != 0 {
                glDeleteShader(fragShader)
                fragShader = 0
            }
            if self.program != 0 {
                glDeleteProgram(self.program)
                self.program = 0
            }
            
            return true
        }
        
        // Get uniform locations.
        uniforms[UNIFORM_Y] = glGetUniformLocation(self.program, "SamplerY")
        uniforms[UNIFORM_UV] = glGetUniformLocation(self.program, "SamplerUV")
        uniforms[UNIFORM_LUMA_THRESHOLD] = glGetUniformLocation(self.program, "lumaThreshold")
        uniforms[UNIFORM_CHROMA_THRESHOLD] = glGetUniformLocation(self.program, "chromaThreshold")
        uniforms[UNIFORM_ROTATION_ANGLE] = glGetUniformLocation(self.program, "preferredRotation")
        uniforms[UNIFORM_COLOR_CONVERSION_MATRIX] = glGetUniformLocation(self.program, "colorConversionMatrix")
        
        // Release vertex and fragment shaders.
        if vertShader != 0 {
            glDetachShader(self.program, vertShader)
            glDeleteShader(vertShader)
        }
        if fragShader != 0 {
            glDetachShader(self.program, fragShader)
            glDeleteShader(fragShader)
        }
        
        return true
    }
    
    func compileShader(shader: UnsafeMutablePointer<GLuint>, type: GLenum, URL: NSURL) -> Bool {
        let sourceString: String
        do {
            sourceString = try String(contentsOfURL: URL, encoding: NSUTF8StringEncoding)
        } catch let error as NSError {
            NSLog("Failed to load vertex shader: %@", error.localizedDescription)
            return false
        }
        
        var status: GLint = 0
        sourceString.withCString {(_source: UnsafePointer<GLchar>)->Void in
            
            shader.memory = glCreateShader(type)
            var source = _source
            glShaderSource(shader.memory, 1, &source, nil)
            glCompileShader(shader.memory)
        }
        
        #if DEBUG
            var logLength: GLint = 0
            glGetShaderiv(shader.memory, GL_INFO_LOG_LENGTH.ui, &logLength)
            if logLength > 0 {
                let log = UnsafeMutablePointer<GLchar>.alloc(Int(logLength))
                glGetShaderInfoLog(shader.memory, logLength, &logLength, log)
                NSLog("Shader compile log:\n%s", log)
                log.dealloc(Int(logLength))
            }
        #endif
        
        glGetShaderiv(shader.memory, GL_COMPILE_STATUS.ui, &status)
        if status == 0 {
            glDeleteShader(shader.memory)
            return false
        }
        
        return true
    }
    
    private func linkProgram(prog: GLuint) -> Bool {
        var status: GLint = 0
        glLinkProgram(prog)
        
        #if DEBUG
            var logLength: GLint = 0
            glGetProgramiv(prog, GL_INFO_LOG_LENGTH.ui, &logLength)
            if logLength > 0 {
                let log = UnsafeMutablePointer<GLchar>.alloc(Int(logLength))
                glGetProgramInfoLog(prog, logLength, &logLength, log)
                NSLog("Program link log:\n%s", log)
                log.dealloc(Int(logLength))
            }
        #endif
        
        glGetProgramiv(prog, GL_LINK_STATUS.ui, &status)
        if status == 0 {
            return false
        }
        
        return true
    }
    
    private func validateProgram(prog: GLuint) -> Bool {
        var logLength: GLint = 0
        var status: GLint = 0
        
        glValidateProgram(prog)
        glGetProgramiv(prog, GL_INFO_LOG_LENGTH.ui, &logLength)
        if logLength > 0 {
            let log = UnsafeMutablePointer<GLchar>.alloc(logLength.l)
            glGetProgramInfoLog(prog, logLength, &logLength, log)
            NSLog("Program validate log:\n\(String.fromCString(log))")
            log.dealloc(logLength.l)
        }
        
        glGetProgramiv(prog, GL_VALIDATE_STATUS.ui, &status)
        if status == 0 {
            return false
        }
        
        return true
    }
    
}