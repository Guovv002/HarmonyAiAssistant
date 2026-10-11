const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const studio = process.env.DEVECO_STUDIO_ROOT || 'D:/DevEco Studio';
const tsPath = path.join(studio, 'tools/hvigor/hvigor/node_modules/typescript');
if (!fs.existsSync(tsPath)) throw new Error('Set DEVECO_STUDIO_ROOT to your DevEco Studio installation.');
const ts = require(tsPath);
const root = path.resolve(__dirname, '../entry/src/main/ets');

function load(relative, dependencies = {}, timers = {}) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
  }}).outputText;
  const module = { exports: {} };
  const mockRequire = name => {
    if (!(name in dependencies)) throw new Error(`Unexpected import ${name}`);
    return dependencies[name];
  };
  new Function('require', 'module', 'exports', 'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval', compiled)(
    mockRequire, module, module.exports, timers.setTimeout || setTimeout, timers.clearTimeout || clearTimeout,
    timers.setInterval || setInterval, timers.clearInterval || clearInterval);
  return module.exports;
}

const model = load('model/Assistant.ets');
const message = (role, content, status = 'complete') => model.newMessage(role, content, status);

test('three rounds of follow-ups retain earlier facts and skip failed/canceled turns', () => {
  const history = [message('user', '我的名字是小林'), message('assistant', '你好，小林'),
    message('user', '我正在学习鸿蒙'), message('assistant', '我们可以学习 ArkTS'),
    message('user', '给我一个练习'), message('assistant', '创建一个计数器'),
    message('user', '失败的问题', 'failed'), message('user', '取消的问题', 'canceled'),
    message('user', '我叫什么名字，正在学什么？', 'pending')];
  const context = model.buildContext(history, 'study');
  assert.equal(context.length, 8);
  assert.match(context[0].content, /学习辅导/);
  assert.equal(context[1].content, '我的名字是小林');
  assert.equal(context.at(-1).content, '我叫什么名字，正在学什么？');
  assert(!JSON.stringify(context).includes('失败的问题'));
  assert(!JSON.stringify(context).includes('取消的问题'));
});

test('context window preserves complete pairs, newest question and a bounded budget', () => {
  const history = [];
  for (let i = 0; i < 20; i++) history.push(message('user', `q${i}`), message('assistant', `a${i}`));
  history.push(message('user', 'next', 'pending'));
  const context = model.buildContext(history, 'general');
  assert.equal(context.length, 26);
  assert.equal(context[1].content, 'q8');
  assert.equal(context.at(-1).content, 'next');
  const large = [];
  for (let i = 0; i < 10; i++) large.push(message('user', '问'.repeat(4000)), message('assistant', '答'.repeat(6000)));
  large.push(message('user', '下一问', 'pending'));
  const bounded = model.buildContext(large, 'general').slice(1);
  assert(bounded.reduce((size, item) => size + item.content.length, 0) <= 24000);
  assert.equal(bounded.length % 2, 1);
});

test('service URL accepts base/full endpoint and blocks insecure or credential-bearing URLs', () => {
  assert.equal(model.completionUrl(' https://api.deepseek.com/ '), 'https://api.deepseek.com/chat/completions');
  assert.equal(model.completionUrl('https://example.com/v1/chat/completions/'), 'https://example.com/v1/chat/completions');
  for (const url of ['http://example.com', 'https://user:password@example.com', 'https://example.com?key=secret', 'file:///x']) {
    assert.throws(() => model.completionUrl(url));
  }
  assert.throws(() => model.validateSettings(model.defaultSettings(), 'abc\r\nInjected: value'));
});

test('malformed/empty model replies fail clearly and truncated replies can be continued', () => {
  for (const body of ['<html>', 'null', '{}', '{"choices":[]}', '{"choices":[{"message":{"content":null}}]}']) {
    assert.throws(() => model.parseCompletion(body));
  }
  assert.equal(model.parseCompletion('{"choices":[{"message":{"content":"  你好  "},"finish_reason":"stop"}]}'), '你好');
  assert.match(model.parseCompletion('{"choices":[{"message":{"content":"答案"},"finish_reason":"length"}]}'), /继续/);
  assert.match(model.httpError(401), /认证/);
  assert.match(model.httpError(429), /额度/);
  assert.match(model.httpError(503), /暂时不可用/);
});

test('irregular PCM buffers become exact 20 ms frames, retaining bytes and padding only the final frame', () => {
  const buffer = new model.PcmBuffer();
  const input = Uint8Array.from({ length: 1500 }, (_, index) => index % 256);
  buffer.push(input.subarray(0, 217));
  assert.equal(buffer.take(), undefined);
  buffer.push(input.subarray(217));
  const frames = [buffer.take(), buffer.take()];
  assert.equal(buffer.take(), undefined);
  frames.push(buffer.take(true));
  assert(frames.every(frame => frame.length === 640));
  const output = Buffer.concat(frames.map(frame => Buffer.from(frame)));
  assert.deepEqual(output.subarray(0, 1500), Buffer.from(input));
  assert(output.subarray(1500).every(byte => byte === 0));
  assert.equal(buffer.size(), 0);
  assert.throws(() => buffer.push(new Uint8Array(64001)), /速度/);
});

function chatFixture(response, pending = false) {
  let options, url, reject;
  const request = { request: (endpoint, config) => {
    url = endpoint; options = config;
    return pending ? new Promise((_, fail) => { reject = fail; }) : Promise.resolve(response);
  }, destroy: () => { if (reject) { const fail = reject; reject = undefined; fail(new Error('destroyed')); } } };
  const { ChatService } = load('services/ChatService.ets', {
    '../model/Assistant': model, '@kit.NetworkKit': { http: {
      createHttp: () => request, RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 'STRING' }
    }}
  });
  return { service: new ChatService(), request: () => ({ url, options }) };
}

test('cloud request uses configured endpoint, Bearer auth, bounded timeout and multi-turn messages', async () => {
  const fixture = chatFixture({ responseCode: 200, result: '{"choices":[{"message":{"content":"你好"}}]}' });
  const input = [{ role: 'system', content: 'prompt' }, { role: 'user', content: 'hello' }];
  assert.equal(await fixture.service.complete(model.defaultSettings(), 'test-only-key', input), '你好');
  const { url, options } = fixture.request();
  assert(url.endsWith('/chat/completions'));
  assert.equal(options.header.Authorization, 'Bearer test-only-key');
  assert.equal(options.readTimeout, 60000);
  assert.deepEqual(JSON.parse(options.extraData).messages, input);
  assert(!options.extraData.includes('test-only-key'));
});

test('HTTP auth failure is explained and cancellation invalidates a pending request', async () => {
  const unauthorized = chatFixture({ responseCode: 401, result: 'secret server error' });
  await assert.rejects(unauthorized.service.complete(model.defaultSettings(), 'key', []), /认证失败/);
  const pending = chatFixture(null, true);
  const promise = pending.service.complete(model.defaultSettings(), 'key', []);
  pending.service.cancel();
  await assert.rejects(promise, /取消/);
});

const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function speechFixture(granted = true) {
  let id = 0, listener, pcm, playback;
  const scheduled = new Map();
  const timers = {
    setTimeout: (fn, delay) => { scheduled.set(++id, { fn, delay, interval: false }); return id; },
    setInterval: (fn, delay) => { scheduled.set(++id, { fn, delay, interval: true }); return id; },
    clearTimeout: key => scheduled.delete(key), clearInterval: key => scheduled.delete(key)
  };
  const captured = { stopped: 0, released: 0, frames: [], finish: 0, engines: 0 };
  const recognizer = {
    setListener: value => { listener = value; }, startListening: params => { captured.session = params.sessionId; listener.onStart(params.sessionId, 'ok'); },
    writeAudio: (_, bytes) => captured.frames.push(bytes), finish: () => { captured.finish++; },
    cancel: () => {}, shutdown: () => {}
  };
  const capturer = { on: (_, value) => { pcm = value; }, off: () => {}, start: async () => {},
    stop: async () => { captured.stopped++; }, release: async () => { captured.released++; } };
  const speaker = { setListener: value => { playback = value; }, speak: (_, params) => { captured.requestId = params.requestId; },
    stop: () => {}, shutdown: () => {} };
  const { SpeechService } = load('services/SpeechService.ets', {
    '../model/Assistant': model,
    '@kit.AbilityKit': { abilityAccessCtrl: { createAtManager: () => ({ requestPermissionsFromUser: async () => ({ authResults: [granted ? 0 : -1] }) }) } },
    '@kit.AudioKit': { audio: { createAudioCapturer: async () => capturer, AudioSamplingRate: { SAMPLE_RATE_16000: 16000 },
      AudioChannel: { CHANNEL_1: 1 }, AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 },
      AudioEncodingType: { ENCODING_TYPE_RAW: 0 }, SourceType: { SOURCE_TYPE_VOICE_RECOGNITION: 1 } } },
    '@kit.CoreSpeechKit': { speechRecognizer: { createEngine: async () => { captured.engines++; return recognizer; } },
      textToSpeech: { createEngine: async () => speaker } }
  }, timers);
  return { service: new SpeechService(), captured, scheduled,
    input: bytes => pcm(bytes.buffer), listener: () => listener, playback: () => playback,
    tick: delay => { for (const [key, timer] of [...scheduled]) if (timer.delay === delay) {
      if (!timer.interval) scheduled.delete(key); timer.fn();
    }} };
}

test('ASR drains and pads PCM before finish, clears startup timeout, and delivers final text once', async () => {
  const fixture = speechFixture();
  const results = [], errors = [];
  await fixture.service.start({}, { onReady: () => {}, onPartial: () => {}, onComplete: text => results.push(text), onError: text => errors.push(text) });
  await flush();
  assert(![...fixture.scheduled.values()].some(timer => timer.delay === 10000));
  fixture.input(new Uint8Array(1440));
  fixture.tick(20); fixture.tick(20);
  fixture.service.finishListening();
  await flush();
  fixture.tick(20); fixture.tick(20);
  assert.equal(fixture.captured.frames.length, 3);
  assert(fixture.captured.frames.every(frame => frame.length === 640));
  assert.equal(fixture.captured.finish, 1);
  const session = fixture.captured.session;
  fixture.listener().onResult(session, { isFinal: true, isLast: true, result: '你好' });
  fixture.listener().onComplete(session, 'done');
  await flush();
  assert.deepEqual(results, ['你好']);
  assert.deepEqual(errors, []);
  assert.equal(fixture.captured.released, 1);
  assert.equal(fixture.scheduled.size, 0);
});

test('permission denial opens no engine; late ASR callbacks after cancellation cannot send a question', async () => {
  const denied = speechFixture(false), errors = [];
  await denied.service.start({}, { onReady: () => {}, onPartial: () => {}, onComplete: () => {}, onError: text => errors.push(text) });
  assert.equal(denied.captured.engines, 0);
  assert.match(errors[0], /麦克风权限/);
  const fixture = speechFixture(), results = [];
  await fixture.service.start({}, { onReady: () => {}, onPartial: () => {}, onComplete: text => results.push(text), onError: () => {} });
  await flush();
  const session = fixture.captured.session;
  fixture.service.cancelListening();
  fixture.listener().onResult(session, { isFinal: true, isLast: true, result: 'late' });
  await flush();
  assert.deepEqual(results, []);
  assert.equal(fixture.captured.released, 1);
});

test('TTS waits for playback completion, and ignores callbacks after stop', async () => {
  const fixture = speechFixture();
  let done = 0;
  await fixture.service.speak('你好', { onDone: () => { done++; }, onError: () => {} });
  fixture.playback().onComplete(fixture.captured.requestId, { type: 0 });
  assert.equal(done, 0);
  fixture.playback().onComplete(fixture.captured.requestId, { type: 1 });
  assert.equal(done, 1);
  fixture.service.stopSpeaking();
  fixture.playback().onComplete(fixture.captured.requestId, { type: 1 });
  assert.equal(done, 1);
});

function storeFixture() {
  const files = new Map(), prefs = new Map();
  let failWrite = false, closed = 0;
  const io = {
    accessSync: name => files.has(name), readTextSync: name => files.get(name),
    copyFileSync: (from, to) => files.set(to, files.get(from)),
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    openSync: name => ({ fd: name }),
    writeSync: (name, text) => { if (failWrite) throw new Error('disk full'); files.set(name, text); },
    closeSync: () => { closed++; },
    renameSync: (from, to) => { files.set(to, files.get(from)); files.delete(from); }
  };
  const { AssistantStore } = load('services/AssistantStore.ets', {
    '../model/Assistant': model, '@kit.CoreFileKit': { fileIo: io },
    '@kit.ArkData': { preferences: { getPreferences: async () => ({
      getSync: (key, fallback) => prefs.has(key) ? prefs.get(key) : fallback,
      putSync: (key, value) => prefs.set(key, value), flush: async () => {}
    }) } }
  });
  return { store: new AssistantStore(), files, prefs, fail: () => { failWrite = true; }, closed: () => closed };
}

test('stored history survives restart, pending turns become canceled and keys are never persisted', async () => {
  const fixture = storeFixture();
  await fixture.store.open({ filesDir: '/sandbox' });
  const conversation = model.newConversation();
  conversation.messages = [message('user', '我的名字是小林'), message('assistant', '你好'), message('user', '未完成的问题', 'pending')];
  fixture.store.saveConversations([conversation]);
  assert.equal(fixture.store.loadConversations()[0].messages.at(-1).status, 'canceled');
  const settings = { ...model.defaultSettings(), apiKey: 'should-not-be-written' };
  await fixture.store.saveSettings(settings);
  assert.deepEqual([...fixture.prefs.keys()].sort(), ['autoSpeak', 'baseUrl', 'model']);
  assert(!JSON.stringify([...fixture.files.values()]).includes('should-not-be-written'));
});

test('failed history writes preserve prior file; corrupted history is backed up before later saves', async () => {
  const fixture = storeFixture();
  await fixture.store.open({ filesDir: '/sandbox' });
  fixture.store.saveConversations([model.newConversation()]);
  const original = fixture.files.get('/sandbox/conversations.json');
  fixture.fail();
  assert.throws(() => fixture.store.saveConversations([]), /保存失败/);
  assert.equal(fixture.files.get('/sandbox/conversations.json'), original);
  assert.equal(fixture.closed(), 2);
  const corrupt = storeFixture();
  await corrupt.store.open({ filesDir: '/sandbox' });
  corrupt.files.set('/sandbox/conversations.json', 'invalid json');
  assert.throws(() => corrupt.store.loadConversations(), /保留备份/);
  assert([...corrupt.files.keys()].some(name => name.includes('.corrupt')));
  corrupt.store.saveConversations([]);
  assert([...corrupt.files.entries()].some(([name, value]) => name.includes('.corrupt') && value === 'invalid json'));
});
