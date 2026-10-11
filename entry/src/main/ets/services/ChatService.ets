import { http } from '@kit.NetworkKit';
import { ApiMessage, CompletionRequest, ModelSettings, completionUrl, httpError,
  parseCompletion, validateSettings } from '../model/Assistant';

export class ChatService {
  private request: http.HttpRequest | undefined = undefined;
  private generation: number = 0;

  cancel(): void {
    this.generation++;
    this.request?.destroy();
    this.request = undefined;
  }

  async complete(settings: ModelSettings, apiKey: string, messages: ApiMessage[]): Promise<string> {
    validateSettings(settings, apiKey);
    this.cancel();
    const generation = this.generation;
    const request = http.createHttp();
    this.request = request;
    const body: CompletionRequest = { model: settings.model.trim(), messages: messages,
      stream: false, max_tokens: 1024 };
    try {
      const response = await request.request(completionUrl(settings.baseUrl), {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${apiKey.trim()}` },
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 60000,
        maxLimit: 1024 * 1024
      });
      if (generation !== this.generation) { throw new Error('请求已取消。'); }
      if (response.responseCode !== 200) { throw new Error(httpError(response.responseCode)); }
      return parseCompletion(response.result as string);
    } catch (error) {
      if (generation !== this.generation) { throw new Error('请求已取消。'); }
      const message = (error as Error).message;
      if (message && (message.startsWith('认证') || message.startsWith('接口') || message.startsWith('请求') ||
        message.startsWith('模型') || message.startsWith('服务'))) { throw new Error(message); }
      throw new Error('连接失败或请求超时，请检查网络与服务地址后重试。');
    } finally {
      request.destroy();
      if (generation === this.generation) { this.request = undefined; }
    }
  }
}
