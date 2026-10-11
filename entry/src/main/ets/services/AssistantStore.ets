import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { Conversation, ModelSettings, defaultSettings } from '../model/Assistant';

export class AssistantStore {
  private prefs: preferences.Preferences | undefined = undefined;
  private historyPath: string = '';

  async open(context: common.UIAbilityContext): Promise<void> {
    try {
      this.prefs = await preferences.getPreferences(context, { name: 'assistant_settings' });
      this.historyPath = `${context.filesDir}/conversations.json`;
    } catch (_) { throw new Error('本地存储初始化失败。'); }
  }

  loadSettings(): ModelSettings {
    const defaults = defaultSettings();
    if (!this.prefs) { return defaults; }
    try {
      return {
        baseUrl: this.prefs.getSync('baseUrl', defaults.baseUrl) as string,
        model: this.prefs.getSync('model', defaults.model) as string,
        autoSpeak: this.prefs.getSync('autoSpeak', true) as boolean
      };
    } catch (_) { throw new Error('设置读取失败。'); }
  }

  async saveSettings(settings: ModelSettings): Promise<void> {
    if (!this.prefs) { throw new Error('本地设置尚未初始化。'); }
    try {
      this.prefs.putSync('baseUrl', settings.baseUrl);
      this.prefs.putSync('model', settings.model);
      this.prefs.putSync('autoSpeak', settings.autoSpeak);
      await this.prefs.flush();
    } catch (_) { throw new Error('设置保存失败，请重试。'); }
  }

  loadConversations(): Conversation[] {
    try {
      if (!fileIo.accessSync(this.historyPath)) { return []; }
      const saved = JSON.parse(fileIo.readTextSync(this.historyPath)) as Conversation[];
      if (!Array.isArray(saved)) { throw new Error('历史记录格式异常。'); }
      saved.forEach((item: Conversation) => {
        if (!item || typeof item.id !== 'string' || typeof item.title !== 'string' ||
          typeof item.updatedAt !== 'number' || (item.mode !== 'study' && item.mode !== 'general') ||
          !Array.isArray(item.messages)) { throw new Error('历史记录格式异常。'); }
        item.messages.forEach((message) => {
          if (!message || typeof message.id !== 'string' || typeof message.content !== 'string' ||
            typeof message.createdAt !== 'number' || (message.role !== 'user' && message.role !== 'assistant') ||
            !['pending', 'complete', 'failed', 'canceled'].includes(message.status)) {
            throw new Error('历史记录格式异常。');
          }
          if (message.status === 'pending') { message.status = 'canceled'; }
        });
        item.messages = item.messages.slice(-60);
      });
      return saved.slice(0, 20);
    } catch (_) {
      try { fileIo.copyFileSync(this.historyPath, `${this.historyPath}.corrupt${Date.now()}`); }
      catch (_) { throw new Error('历史记录读取失败，本次对话仍可使用。'); }
      throw new Error('历史记录异常，已保留备份，本次对话仍可使用。');
    }
  }

  saveConversations(conversations: Conversation[]): void {
    if (!this.historyPath) { throw new Error('历史记录存储尚未初始化。'); }
    const tempPath = `${this.historyPath}.tmp`;
    try {
      const file = fileIo.openSync(tempPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      try { fileIo.writeSync(file.fd, JSON.stringify(conversations)); } finally { fileIo.closeSync(file); }
      fileIo.renameSync(tempPath, this.historyPath);
    } catch (_) { throw new Error('历史记录保存失败。'); }
  }
}
