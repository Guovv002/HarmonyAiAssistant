export interface ChatMessage {
  id: string;
  role: string;
  content: string;
  createdAt: number;
  status: string;
}

export interface Conversation {
  id: string;
  title: string;
  mode: string;
  updatedAt: number;
  messages: ChatMessage[];
}

export interface ModelSettings {
  baseUrl: string;
  model: string;
  autoSpeak: boolean;
}

export interface ApiMessage {
  role: string;
  content: string;
}

export interface CompletionRequest {
  model: string;
  messages: ApiMessage[];
  stream: boolean;
  max_tokens: number;
}

export interface CompletionChoice {
  message: ApiMessage;
  finish_reason: string;
}

export interface CompletionResponse {
  choices?: CompletionChoice[];
}

export const GENERAL_PROMPT: string = '你是「和声」，一位友好、可靠的中文 AI 语音助手。结合上下文直接回答用户的问题。默认用简洁自然的中文，适合朗读，通常控制在 200 字以内。需要详细解释时可以适当展开。不要使用复杂 Markdown 表格。不能获取实时信息、操作设备或执行任务时，明确说明能力边界，不要编造执行结果。';
export const STUDY_PROMPT: string = GENERAL_PROMPT + '你现在是学习辅导助手。先判断学生的目标与已有基础，优先用直观例子和分步骤解释帮助理解。解题时说明思路与关键步骤，提供一个小练习或检查理解的问题。继续追问时承接之前的概念和例子。不要编造资料来源。';

export function defaultSettings(): ModelSettings {
  return { baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1', model: 'qwen-plus', autoSpeak: true };
}

export function newConversation(mode: string = 'study'): Conversation {
  const now = Date.now();
  return { id: `chat${now}${Math.floor(Math.random() * 100000)}`, title: '新的对话', mode: mode,
    updatedAt: now, messages: [] };
}

export function newMessage(role: string, content: string, status: string = 'complete'): ChatMessage {
  const now = Date.now();
  return { id: `msg${now}${Math.floor(Math.random() * 100000)}`, role: role,
    content: content, createdAt: now, status: status };
}

export function completionUrl(baseUrl: string): string {
  const clean = baseUrl.trim().replace(/\/+$/, '');
  if (!/^https:\/\/[a-zA-Z0-9.-]+(?::\d+)?(?:\/[a-zA-Z0-9_./%-]*)?$/.test(clean)) {
    throw new Error('请填写有效的 HTTPS 服务地址，不要包含密钥、查询参数或账号信息。');
  }
  return clean.endsWith('/chat/completions') ? clean : `${clean}/chat/completions`;
}

export function validateSettings(settings: ModelSettings, apiKey: string): void {
  completionUrl(settings.baseUrl);
  if (settings.baseUrl.length > 2048 || !settings.model.trim() || settings.model.length > 128) {
    throw new Error('请填写正确的服务地址和模型名称。');
  }
  if (!apiKey.trim() || /[\r\n]/.test(apiKey) || apiKey.length > 4096) {
    throw new Error('请在设置中填写有效的 API Key。');
  }
}

// Keep complete user/assistant pairs, then the current question. Failed turns never become context.
// The latest 12 turns and a character budget keep requests bounded without splitting a turn.
export function buildContext(messages: ChatMessage[], mode: string): ApiMessage[] {
  const pairs: ApiMessage[][] = [];
  let pending: ChatMessage | undefined = undefined;
  for (let i = 0; i < messages.length; i++) {
    const message = messages[i];
    if (message.role === 'user') {
      pending = message.status === 'complete' || message.status === 'pending' ? message : undefined;
    } else if (message.role === 'assistant' && message.status === 'complete' && pending) {
      pairs.push([{ role: 'user', content: pending.content }, { role: 'assistant', content: message.content }]);
      pending = undefined;
    }
  }
  const retained: ApiMessage[][] = [];
  let length = pending ? pending.content.length : 0;
  for (let i = pairs.length - 1; i >= 0 && retained.length < 12; i--) {
    const pairLength = pairs[i][0].content.length + pairs[i][1].content.length;
    if (length + pairLength > 24000) { break; }
    retained.unshift(pairs[i]);
    length += pairLength;
  }
  const context: ApiMessage[] = [{ role: 'system', content: mode === 'study' ? STUDY_PROMPT : GENERAL_PROMPT }];
  retained.forEach((pair: ApiMessage[]) => { context.push(pair[0], pair[1]); });
  if (pending) { context.push({ role: 'user', content: pending.content }); }
  return context;
}

export function parseCompletion(body: string): string {
  let response: CompletionResponse;
  try { response = JSON.parse(body) as CompletionResponse; } catch (_) {
    throw new Error('服务返回了无效的 JSON，请检查服务地址是否为对话接口。');
  }
  if (!response || !Array.isArray(response.choices) || response.choices.length === 0 ||
    !response.choices[0].message || typeof response.choices[0].message.content !== 'string' ||
    !response.choices[0].message.content.trim()) {
    throw new Error('模型未返回文本回复，请检查模型是否支持 Chat Completions。');
  }
  const choice = response.choices[0];
  if (choice.finish_reason === 'length') {
    return choice.message.content.trim().slice(0, 6000) + '\n（回复达到长度限制，可以让我继续。）';
  }
  return choice.message.content.trim().slice(0, 6000);
}

export function httpError(status: number): string {
  if (status === 401 || status === 403) { return '认证失败，请检查 API Key、服务地域和模型访问权限。'; }
  if (status === 404) { return '接口或模型不存在，请检查服务地址和模型名称。'; }
  if (status === 429) { return '请求过于频繁或额度不足，请稍后重试并检查账户额度。'; }
  if (status >= 500) { return '模型服务暂时不可用，请稍后重试。'; }
  return `请求失败（HTTP ${status}），请检查模型配置。`;
}

export function spokenText(text: string): string {
  return text.replace(/```[\s\S]*?```/g, '，代码内容请查看屏幕，')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/https?:\/\/\S+/g, '链接请查看屏幕')
    .replace(/[*#`>_]/g, '').trim();
}

// AudioCapturer callbacks have varying sizes; the ASR requires exactly 640/1280-byte PCM frames.
export class PcmBuffer {
  private bytes: Uint8Array = new Uint8Array(0);

  size(): number { return this.bytes.length; }

  push(data: Uint8Array): void {
    if (this.bytes.length + data.length > 64000) {
      throw new Error('音频处理速度不足，请结束本次录音后重试。');
    }
    const merged = new Uint8Array(this.bytes.length + data.length);
    merged.set(this.bytes);
    merged.set(data, this.bytes.length);
    this.bytes = merged;
  }

  take(pad: boolean = false): Uint8Array | undefined {
    if (this.bytes.length === 0 || (this.bytes.length < 640 && !pad)) { return undefined; }
    const frame = new Uint8Array(640);
    frame.set(this.bytes.subarray(0, 640));
    this.bytes = this.bytes.slice(Math.min(640, this.bytes.length));
    return frame;
  }

  clear(): void { this.bytes = new Uint8Array(0); }
}
