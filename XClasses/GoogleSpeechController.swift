//
//  GoogleSpeechController.swift
//  Bookbot
//
//  Created by Adrian on 30/7/17.
//  Copyright © 2017 Adrian DeWitts. All rights reserved.
//

import UIKit
import Speech
import AudioKit
import AssistantKit

class GoogleSpeechController: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let microphone: AKMicrophone
    var response: (_ transcription: String) -> Void = {_ in}

    // MARK: Setup

    override init() {
        AKSettings.audioInputEnabled = true
        AKSettings.sampleRate = 32000
        AKSettings.numberOfChannels = 1
        SpeechController.authoriseSpeech()
        microphone = AKMicrophone()

        // Use front microphone or default
        if Device.isDevice, var device: AKDevice = AudioKit.inputDevices?.first {
            for d in AudioKit.inputDevices! {
                if d.deviceID.contains("Front") {
                    device = d
                }
            }
            try? microphone.setDevice(device)
        }

        super.init()
    }

    func start(context: [String] = [], response: @escaping (_ transcription: String) -> Void) {
        self.response = response
        configureRecogniser(context: context)
        microphone.avAudioNode.installTap(onBus: 0, bufferSize: 1024, format: AudioKit.format) { buffer, time in
            //self.speechRecognition.append(buffer)
        }

        AudioKit.start()
    }

    /// Stops audio input and speech recognition
    func stop() {
        AudioKit.stop()
        microphone.avAudioNode.removeTap(onBus: 0)
        //speechRecognition.endAudio()
    }

    // TODO: Respond with human readable errors for authorisations

    class func authoriseMicrophone() {
        _ = AKMicrophone()
    }

    func configureRecogniser(context: [String])
    {

    }
}
