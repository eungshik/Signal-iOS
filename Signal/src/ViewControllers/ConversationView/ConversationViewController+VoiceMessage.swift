//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

extension ConversationViewController {
    @objc
    func checkPermissionsAndStartRecordingVoiceMessage() {
        AssertIsOnMainThread()

        // Cancel any ongoing audio playback.
        cvAudioPlayer.stopAll()

        let voiceMessageModel = VoiceMessageModel(thread: thread)
        viewState.currentVoiceMessageModel = voiceMessageModel

        // Delay showing the voice memo UI for N ms to avoid a jarring transition
        // when you just tap and don't hold.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            guard self.viewState.currentVoiceMessageModel === voiceMessageModel else { return }
            self.configureScrollDownButtons()
            self.inputToolbar?.showVoiceMemoUI()
        }

        ows_askForMicrophonePermissions { [weak self] granted in
            guard let self = self else { return }
            guard self.viewState.currentVoiceMessageModel === voiceMessageModel else { return }

            guard granted else {
                self.cancelRecordingVoiceMessage()
                self.ows_showNoMicrophonePermissionActionSheet()
                return
            }

            self.startRecordingVoiceMessage()
        }
    }

    private func startRecordingVoiceMessage() {
        AssertIsOnMainThread()

        guard let voiceMessageModel = viewState.currentVoiceMessageModel else {
            return owsFailDebug("Unexpectedly missing voice message model")
        }

        ImpactHapticFeedback.impactOccured(style: .light)

        do {
            try voiceMessageModel.startRecording()
        } catch {
            owsFailDebug("Failed to start recording voice message \(error)")
            cancelRecordingVoiceMessage()
        }
    }

    @objc
    func cancelRecordingVoiceMessage() {
        AssertIsOnMainThread()

        defer { viewState.currentVoiceMessageModel = nil }
        guard let voiceMessageModel = viewState.currentVoiceMessageModel else { return }

        voiceMessageModel.stopRecordingAsync()

        NotificationHapticFeedback().notificationOccurred(.warning)

        clearVoiceMessageDraft()
        viewState.currentVoiceMessageModel = nil
        inputToolbar?.hideVoiceMemoUI(true)
        configureScrollDownButtons()
    }

    private static let minimumVoiceMessageDuration: TimeInterval = 1

    @objc(finishRecordingVoiceMessageAndSendImmediately:)
    func finishRecordingVoiceMessage(sendImmediately: Bool = false) {
        AssertIsOnMainThread()

        defer { viewState.currentVoiceMessageModel = nil }
        guard let voiceMessageModel = viewState.currentVoiceMessageModel else { return }

        voiceMessageModel.stopRecording()

        guard let duration = voiceMessageModel.duration, duration >= Self.minimumVoiceMessageDuration else {
            inputToolbar?.showVoiceMemoTooltip()
            cancelRecordingVoiceMessage()
            return
        }

        ImpactHapticFeedback.impactOccured(style: .medium)

        if sendImmediately {
            sendVoiceMessageModel(voiceMessageModel)
        } else {
            databaseStorage.asyncWrite { voiceMessageModel.saveDraft(transaction: $0) } completion: {
                self.inputToolbar?.showVoiceMemoDraft(voiceMessageModel)
                self.configureScrollDownButtons()
            }
        }
    }

    @objc
    func sendVoiceMessageModel(_ voiceMessageModel: VoiceMessageModel) {
        inputToolbar?.hideVoiceMemoUI(true)
        configureScrollDownButtons()

        var attachment: SignalAttachment?
        databaseStorage.asyncWrite { transaction in
            do {
                attachment = try voiceMessageModel.consumeForSending(transaction: transaction)
            } catch {
                owsFailDebug("Failed to send prepare voice message for sending \(error)")
            }
        } completion: {
            guard let attachment = attachment else { return }
            self.tryToSendAttachments([attachment], messageBody: nil)
        }
    }

    func clearVoiceMessageDraft() {
        databaseStorage.asyncWrite { [thread] in VoiceMessageModel.clearDraft(for: thread, transaction: $0) }
    }
}
