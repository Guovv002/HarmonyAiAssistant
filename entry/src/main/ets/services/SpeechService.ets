import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { speechRecognizer, textToSpeech } from '@kit.CoreSpeechKit';
import { PcmBuffer, spokenText } from '../model/Assistant';

export interface VoiceCallbacks {
  onReady: () => void;
  onPartial: (text: string) => void;
  onComplete: (text: string) => void;
  onError: (message: string) => void;
}

export interface PlaybackCallbacks {
  onDone: () => void;
  onError: (message: string) => void;
}

export class SpeechService {
  private recognizer: speechRecognizer.SpeechRecognitionEngine | undefined = undefined;
  private speaker: textToSpeech.TextToSpeechEngine | undefined = undefined;
  private capturer: audio.AudioCapturer | undefined = undefined;
  private cleanup: Promise<void> = Promise.resolve();
  private frames: PcmBuffer = new PcmBuffer();
  private voiceGeneration: number = 0;
  private playbackGeneration: number = 0;
  private sessionId: string = '';
  private frameTimer: number = -1;
  private limitTimer: number = -1;
  private finishTimer: number = -1;
  private finishing: boolean = false;
  private captureStopped: boolean = false;
  private finishSent: boolean = false;
  private finalized: string = '';
  private partial: string = '';
  private callbacks: VoiceCallbacks | undefined = undefined;

  async start(context: common.UIAbilityContext, callbacks: VoiceCallbacks): Promise<void> {
    this.cancelListening();
    this.stopSpeaking();
    const generation = this.voiceGeneration;
    this.callbacks = callbacks;
    try {
      await this.cleanup;
      if (generation !== this.voiceGeneration) { return; }
      const permission = await abilityAccessCtrl.createAtManager()
        .requestPermissionsFromUser(context, ['ohos.permission.MICROPHONE']);
      if (generation !== this.voiceGeneration) { return; }
      if (permission.authResults.length === 0 || permission.authResults[0] !== 0) {
        throw new Error('需要麦克风权限才能使用语音，请在系统设置中允许，或使用文字输入。');
      }
      if (!this.recognizer) {
        const engine = await speechRecognizer.createEngine({ language: 'zh-CN', online: 1 });
        if (generation !== this.voiceGeneration) { engine.shutdown(); return; }
        this.recognizer = engine;
      }
      const capturer = await audio.createAudioCapturer({
        streamInfo: { samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1, sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION, capturerFlags: 0 }
      });
      if (generation !== this.voiceGeneration) { await capturer.release(); return; }
      this.capturer = capturer;
      this.sessionId = `voice${Date.now()}`;
      const listener: speechRecognizer.RecognitionListener = {
        onStart: (sessionId: string, _message: string) => {
          if (generation !== this.voiceGeneration || sessionId !== this.sessionId) { return; }
          capturer.start().then(() => {
            if (generation !== this.voiceGeneration) { return; }
            clearTimeout(this.limitTimer);
            callbacks.onReady();
            this.limitTimer = setTimeout(() => { this.finishListening(); }, 55000);
          }).catch(() => { this.fail(generation, '麦克风启动失败，请检查设备或权限。'); });
        },
        onEvent: (_sessionId: string, _code: number, _message: string) => {},
        onResult: (sessionId: string, result: speechRecognizer.SpeechRecognitionResult) => {
          if (generation !== this.voiceGeneration || sessionId !== this.sessionId) { return; }
          if (result.isFinal) { this.finalized += result.result; this.partial = ''; }
          else { this.partial = result.result; }
          callbacks.onPartial(this.finalized + this.partial);
          if (result.isLast) { this.completeListening(generation); }
        },
        onComplete: (sessionId: string, _message: string) => {
          if (sessionId === this.sessionId) { this.completeListening(generation); }
        },
        onError: (sessionId: string, code: number, _message: string) => {
          if (sessionId === this.sessionId) {
            this.fail(generation, `语音识别失败（${code}），请检查设备语音能力后重试，或使用文字输入。`);
          }
        }
      };
      this.recognizer.setListener(listener);
      capturer.on('readData', (buffer: ArrayBuffer) => {
        if (generation !== this.voiceGeneration || this.finishing) { return; }
        try { this.frames.push(new Uint8Array(buffer)); }
        catch (_) { this.fail(generation, '音频处理速度不足，请重试。'); }
      });
      this.frameTimer = setInterval(() => { this.pump(generation); }, 20);
      // Watch for engines that never send onStart, even when microphone permission was granted.
      this.limitTimer = setTimeout(() => { this.fail(generation, '语音引擎启动超时，请使用支持语音能力的鸿蒙真机。'); }, 10000);
      this.recognizer.startListening({ sessionId: this.sessionId,
        audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 } });
    } catch (error) {
      const message = (error as Error).message;
      this.fail(generation, message && message.startsWith('需要') ? message :
        '当前设备无法启动中文语音识别，请检查系统语音能力，或使用文字输入。');
    }
  }

  private pump(generation: number): void {
    if (generation !== this.voiceGeneration) { return; }
    try {
      const frame = this.frames.take(this.finishing && this.captureStopped);
      if (frame) { this.recognizer?.writeAudio(this.sessionId, frame); }
      else if (this.finishing && this.captureStopped && !this.finishSent) {
        this.finishSent = true;
        this.recognizer?.finish(this.sessionId);
      }
    } catch (_) { this.fail(generation, '语音处理失败，请重试或使用文字输入。'); }
  }

  finishListening(): void {
    if (!this.sessionId || this.finishing) { return; }
    this.finishing = true;
    clearTimeout(this.limitTimer);
    const generation = this.voiceGeneration;
    this.releaseCapturer();
    this.cleanup.then(() => {
      if (generation === this.voiceGeneration) { this.captureStopped = true; }
    });
    this.finishTimer = setTimeout(() => { this.fail(generation, '没有收到完整识别结果，请重新录音。'); }, 10000);
  }

  private completeListening(generation: number): void {
    if (generation !== this.voiceGeneration) { return; }
    const text = (this.finalized + this.partial).trim();
    const callbacks = this.callbacks;
    this.cancelListening();
    if (text) { callbacks?.onComplete(text); }
    else { callbacks?.onError('没有听清楚，请靠近麦克风再试一次。'); }
  }

  private fail(generation: number, message: string): void {
    if (generation !== this.voiceGeneration) { return; }
    const callbacks = this.callbacks;
    this.cancelListening();
    callbacks?.onError(message);
  }

  private releaseCapturer(): void {
    const capturer = this.capturer;
    this.capturer = undefined;
    if (!capturer) { return; }
    try { capturer.off('readData'); } catch (_) {}
    this.cleanup = this.cleanup.then(async () => {
      try { await capturer.stop(); } catch (_) {}
      try { await capturer.release(); } catch (_) {}
    });
  }

  cancelListening(): void {
    this.voiceGeneration++;
    clearInterval(this.frameTimer);
    clearTimeout(this.limitTimer);
    clearTimeout(this.finishTimer);
    const sessionId = this.sessionId;
    this.sessionId = '';
    if (sessionId) { try { this.recognizer?.cancel(sessionId); } catch (_) {} }
    this.releaseCapturer();
    this.frames.clear();
    this.finalized = '';
    this.partial = '';
    this.finishing = false;
    this.captureStopped = false;
    this.finishSent = false;
    this.callbacks = undefined;
  }

  async speak(text: string, callbacks: PlaybackCallbacks): Promise<void> {
    this.stopSpeaking();
    const generation = this.playbackGeneration;
    try {
      if (!this.speaker) {
        const engine = await textToSpeech.createEngine({ language: 'zh-CN', person: 13, online: 1 });
        if (generation !== this.playbackGeneration) { engine.shutdown(); return; }
        this.speaker = engine;
      }
      const requestId = `speak${Date.now()}`;
      this.speaker.setListener({
        onStart: (_id: string, _response: textToSpeech.StartResponse) => {},
        onComplete: (id: string, response: textToSpeech.CompleteResponse) => {
          if (generation === this.playbackGeneration && id === requestId && response.type === 1) { callbacks.onDone(); }
        },
        onStop: (id: string, _response: textToSpeech.StopResponse) => {
          if (generation === this.playbackGeneration && id === requestId) { callbacks.onDone(); }
        },
        onError: (id: string, _code: number, _message: string) => {
          if (generation === this.playbackGeneration && id === requestId) {
            callbacks.onError('语音播报暂不可用，你可以直接阅读回复。');
          }
        }
      });
      const content = spokenText(text);
      if (!content) { callbacks.onDone(); return; }
      this.speaker.speak(content, { requestId: requestId });
    } catch (_) {
      if (generation === this.playbackGeneration) { callbacks.onError('当前设备无法播报语音，你可以直接阅读回复。'); }
    }
  }

  stopSpeaking(): void {
    this.playbackGeneration++;
    try { this.speaker?.stop(); } catch (_) {}
  }

  destroy(): void {
    this.cancelListening();
    this.stopSpeaking();
    this.recognizer?.shutdown();
    this.speaker?.shutdown();
    this.recognizer = undefined;
    this.speaker = undefined;
  }
}
