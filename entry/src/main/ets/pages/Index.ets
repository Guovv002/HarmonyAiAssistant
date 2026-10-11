import { common } from '@kit.AbilityKit';
import { ChatMessage, Conversation, ModelSettings, buildContext, completionUrl, defaultSettings,
  newConversation, newMessage, validateSettings } from '../model/Assistant';
import { ChatService } from '../services/ChatService';
import { AssistantStore } from '../services/AssistantStore';
import { SpeechService } from '../services/SpeechService';

@Entry
@Component
struct Index {
  @State screen: string = 'chat';
  @State status: string = 'idle';
  @State mode: string = 'study';
  @State input: string = '';
  @State transcript: string = '';
  @State notice: string = '';
  @State messages: ChatMessage[] = [];
  @State conversations: Conversation[] = [];
  @State baseUrl: string = defaultSettings().baseUrl;
  @State model: string = defaultSettings().model;
  @State apiKey: string = '';
  @State autoSpeak: boolean = true;
  @State initialized: boolean = false;
  @State testing: boolean = false;
  @State testResult: string = '';
  @State elapsed: number = 0;
  private active: Conversation = newConversation();
  private chat: ChatService = new ChatService();
  private store: AssistantStore = new AssistantStore();
  private speech: SpeechService = new SpeechService();
  private scroller: Scroller = new Scroller();
  private generation: number = 0;
  private disposed: boolean = false;
  private recordTimer: number = -1;
  private backgroundHandler: () => void = () => { this.stopCurrent(); };

  aboutToAppear(): void {
    this.disposed = false;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.eventHub.on('assistantBackground', this.backgroundHandler);
    this.initialize(context);
  }

  private async initialize(context: common.UIAbilityContext): Promise<void> {
    try {
      await this.store.open(context);
      if (this.disposed) { return; }
      const settings = this.store.loadSettings();
      this.baseUrl = settings.baseUrl;
      this.model = settings.model;
      this.autoSpeak = settings.autoSpeak;
      try { this.conversations = this.store.loadConversations(); }
      catch (error) { this.notice = (error as Error).message; }
      this.initialized = true;
    } catch (_) {
      if (!this.disposed) { this.notice = '本地存储初始化失败，请重新打开应用。'; }
    }
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.stopCurrent();
    this.speech.destroy();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.eventHub.off('assistantBackground', this.backgroundHandler);
  }

  onPageHide(): void { this.stopCurrent(); }

  onBackPress(): boolean {
    if (this.screen !== 'chat') { this.stopCurrent(); this.screen = 'chat'; return true; }
    if (this.status !== 'idle') { this.stopCurrent(); return true; }
    return false;
  }

  private settings(): ModelSettings {
    return { baseUrl: this.baseUrl.trim(), model: this.model.trim(), autoSpeak: this.autoSpeak };
  }

  private configured(): boolean {
    try { validateSettings(this.settings(), this.apiKey); return true; }
    catch (error) { this.notice = (error as Error).message; this.screen = 'settings'; return false; }
  }

  private persist(): void {
    if (!this.initialized || this.messages.length === 0) { return; }
    this.active.messages = this.messages.slice(-60);
    this.active.updatedAt = Date.now();
    this.active.mode = this.mode;
    const first = this.messages.find((message: ChatMessage) => message.role === 'user');
    this.active.title = first ? first.content.slice(0, 22) : '新的对话';
    const updated: Conversation = { id: this.active.id, title: this.active.title, mode: this.active.mode,
      updatedAt: this.active.updatedAt, messages: this.active.messages.slice() };
    this.conversations = [updated].concat(this.conversations.filter((item: Conversation) => item.id !== updated.id))
      .slice(0, 20);
    try { this.store.saveConversations(this.conversations); }
    catch (_) { this.notice = '保存历史记录失败，本次对话仍可继续。'; }
  }

  private markPending(status: string): void {
    this.messages = this.messages.map((message: ChatMessage): ChatMessage => {
      return { id: message.id, role: message.role, content: message.content, createdAt: message.createdAt,
        status: message.status === 'pending' ? status : message.status };
    });
  }

  private scrollToEnd(): void {
    setTimeout(() => {
      if (!this.disposed && this.screen === 'chat' && this.messages.length > 0) { this.scroller.scrollEdge(Edge.Bottom); }
    }, 80);
  }

  private async send(text: string, retry: boolean = false): Promise<void> {
    const question = text.trim();
    if (!question || !this.initialized || (this.status !== 'idle' && this.status !== 'speaking')) { return; }
    if (question.length > 4000) { this.notice = '单次问题请控制在 4000 字以内。'; return; }
    if (!this.configured()) { return; }
    this.stopCurrent();
    this.notice = '';
    this.input = '';
    this.transcript = '';
    if (retry && this.messages.length > 0) { this.messages = this.messages.slice(0, -1); }
    this.messages = this.messages.concat([newMessage('user', question, 'pending')]);
    this.status = 'thinking';
    const generation = ++this.generation;
    this.persist();
    this.scrollToEnd();
    try {
      const answer = await this.chat.complete(this.settings(), this.apiKey, buildContext(this.messages, this.mode));
      if (generation !== this.generation || this.disposed) { return; }
      this.markPending('complete');
      this.messages = this.messages.concat([newMessage('assistant', answer)]);
      this.status = 'idle';
      this.persist();
      this.scrollToEnd();
      if (this.autoSpeak) { this.play(answer); }
    } catch (error) {
      if (generation !== this.generation || this.disposed) { return; }
      this.markPending('failed');
      this.status = 'idle';
      this.notice = (error as Error).message;
      this.persist();
    }
  }

  private play(text: string): void {
    this.stopCurrent();
    this.status = 'speaking';
    const generation = ++this.generation;
    this.speech.speak(text, {
      onDone: () => { if (generation === this.generation) { this.status = 'idle'; } },
      onError: (message: string) => {
        if (generation === this.generation) { this.status = 'idle'; this.notice = message; }
      }
    });
  }

  private stopCurrent(): void {
    this.generation++;
    this.chat.cancel();
    this.speech.cancelListening();
    this.speech.stopSpeaking();
    clearInterval(this.recordTimer);
    if (this.status === 'thinking') { this.markPending('canceled'); this.persist(); }
    this.status = 'idle';
    this.testing = false;
    this.elapsed = 0;
  }

  private voiceAction(): void {
    if (this.status === 'listening') {
      this.status = 'recognizing';
      clearInterval(this.recordTimer);
      this.speech.finishListening();
      return;
    }
    if (this.status !== 'idle') { this.stopCurrent(); return; }
    if (!this.initialized || !this.configured()) { return; }
    this.notice = '';
    this.transcript = '';
    this.elapsed = 0;
    this.status = 'preparing';
    const generation = ++this.generation;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.speech.start(context, {
      onReady: () => {
        if (generation !== this.generation) { return; }
        this.status = 'listening';
        this.recordTimer = setInterval(() => { this.elapsed++; }, 1000);
      },
      onPartial: (text: string) => { if (generation === this.generation) { this.transcript = text; } },
      onComplete: (text: string) => {
        if (generation !== this.generation) { return; }
        clearInterval(this.recordTimer);
        this.status = 'idle';
        this.send(text);
      },
      onError: (message: string) => {
        if (generation !== this.generation) { return; }
        clearInterval(this.recordTimer);
        this.status = 'idle';
        this.notice = message;
      }
    });
  }

  private startNew(mode: string = this.mode): void {
    this.stopCurrent();
    this.active = newConversation(mode);
    this.mode = mode;
    this.messages = [];
    this.input = '';
    this.transcript = '';
    this.notice = '';
    this.screen = 'chat';
  }

  private selectMode(mode: string): void {
    if (mode === this.mode) { return; }
    if (this.messages.length === 0) { this.mode = mode; this.active.mode = mode; return; }
    this.getUIContext().showAlertDialog({ title: '切换助手模式', message: '切换模式会新建对话，当前对话保留在历史记录中。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '新建对话', action: () => { this.startNew(mode); } } });
  }

  private openScreen(screen: string): void {
    this.stopCurrent();
    this.screen = screen;
    this.testResult = '';
  }

  private async saveSettings(): Promise<void> {
    try {
      completionUrl(this.baseUrl);
      if (!this.model.trim() || this.model.length > 128) { throw new Error('请填写正确的模型名称。'); }
      await this.store.saveSettings(this.settings());
      this.notice = '';
      this.getUIContext().getPromptAction().showToast({ message: '设置已保存，API Key 仅本次运行使用' });
      this.screen = 'chat';
    } catch (error) { this.notice = (error as Error).message || '设置保存失败。'; }
  }

  private async testConnection(): Promise<void> {
    if (!this.configured() || this.testing) { return; }
    this.testing = true;
    this.testResult = '';
    const generation = ++this.generation;
    try {
      await this.chat.complete(this.settings(), this.apiKey, [{ role: 'user', content: '请只回答：连接成功。' }]);
      if (generation === this.generation) { this.testResult = '连接成功，可以开始对话了。'; }
    } catch (error) {
      if (generation === this.generation) { this.testResult = (error as Error).message; }
    } finally { if (generation === this.generation) { this.testing = false; } }
  }

  private restore(item: Conversation): void {
    this.stopCurrent();
    this.active = { id: item.id, title: item.title, mode: item.mode, updatedAt: item.updatedAt,
      messages: item.messages.slice() };
    this.messages = item.messages.slice();
    this.mode = item.mode;
    this.transcript = '';
    this.notice = '';
    this.screen = 'chat';
    this.scrollToEnd();
  }

  private deleteHistory(id: string): void {
    this.getUIContext().showAlertDialog({ title: '删除这段对话？', message: '删除后无法恢复。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', fontColor: '#B64D40', action: () => {
        const retained = this.conversations.filter((item: Conversation) => item.id !== id);
        try {
          this.store.saveConversations(retained);
          this.conversations = retained;
          if (this.active.id === id) { this.startNew(); this.screen = 'history'; }
        } catch (_) { this.notice = '删除失败，请重试。'; }
      } } });
  }

  private statusText(): string {
    if (!this.initialized) { return '正在准备…'; }
    if (this.status === 'preparing') { return '正在开启麦克风…'; }
    if (this.status === 'listening') { return `正在聆听 · ${this.elapsed}s`; }
    if (this.status === 'recognizing') { return '正在识别，轻点可取消'; }
    if (this.status === 'thinking') { return '正在思考，轻点可取消'; }
    if (this.status === 'speaking') { return '正在播报，轻点可停止'; }
    return '轻点麦克风，开始对话';
  }

  private canType(): boolean { return this.status === 'idle' || this.status === 'speaking'; }

  @Builder
  iconButton(icon: Resource, label: string, action: () => void) {
    Button({ type: ButtonType.Normal }) { Image(icon).width(21).height(21) }
      .width(42).height(42).borderRadius(15).backgroundColor('#FFFFFF')
      .accessibilityText(label).onClick(action)
  }

  @Builder
  header() {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text('和声').fontSize(25).fontWeight(FontWeight.Bold).fontColor('#233B31')
        Text('HARMONY VOICE AI').fontSize(9).letterSpacing(2).fontColor('#829187')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      this.iconButton($r('app.media.ic_plus'), '新建对话', () => { this.startNew(); })
      this.iconButton($r('app.media.ic_history'), '对话历史', () => { this.openScreen('history'); })
      this.iconButton($r('app.media.ic_settings'), '模型设置', () => { this.openScreen('settings'); })
    }.width('100%').padding({ left: 24, right: 24, top: 14, bottom: 18 })
  }

  @Builder
  noticeBar() {
    if (this.notice) {
      Row({ space: 8 }) {
        Text(this.notice).fontSize(12).fontColor('#92553E').layoutWeight(1).maxLines(4)
        Button('×').width(26).height(26).fontSize(20).fontColor('#92553E').backgroundColor(Color.Transparent)
          .accessibilityText('关闭提示').onClick(() => { this.notice = ''; })
      }.padding(12).margin({ left: 24, right: 24, bottom: 10 }).borderRadius(12).backgroundColor('#FFF0E6')
    }
  }

  @Builder
  modePicker() {
    Row({ space: 5 }) {
      Button('学习助手', { type: ButtonType.Normal }).layoutWeight(1).height(37).borderRadius(12)
        .fontSize(13).fontWeight(this.mode === 'study' ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.mode === 'study' ? '#FFFFFF' : '#79877D')
        .backgroundColor(this.mode === 'study' ? '#345E49' : Color.Transparent)
        .onClick(() => { this.selectMode('study'); })
      Button('通用对话', { type: ButtonType.Normal }).layoutWeight(1).height(37).borderRadius(12)
        .fontSize(13).fontWeight(this.mode === 'general' ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.mode === 'general' ? '#FFFFFF' : '#79877D')
        .backgroundColor(this.mode === 'general' ? '#345E49' : Color.Transparent)
        .onClick(() => { this.selectMode('general'); })
    }.padding(5).backgroundColor('#EBEFE8').borderRadius(17).margin({ left: 24, right: 24 })
  }

  @Builder
  suggestion(title: string, subtitle: string, question: string) {
    Button({ type: ButtonType.Normal }) {
      Row() {
        Column({ space: 5 }) {
          Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#334D3F')
          Text(subtitle).fontSize(11).fontColor('#8B968D')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Text('↗').fontSize(19).fontColor('#6E8B75')
      }.width('100%').padding(15)
    }.width('100%').backgroundColor('#FFFFFF').borderRadius(16).onClick(() => { this.send(question); })
  }

  @Builder
  welcome() {
    Column({ space: 0 }) {
      Row({ space: 5 }) {
        Row().width(5).height(5).backgroundColor('#6F9473').borderRadius(3)
        Text('随时倾听，陪你探索').fontSize(11).fontColor('#849687')
      }.margin({ top: 25, bottom: 17 })
      Stack({ alignContent: Alignment.Center }) {
        Row().width(156).height(156).backgroundColor('#EDF2DD').borderRadius(78)
        Row().width(128).height(128).backgroundColor('#DFECC6').borderRadius(64)
        Row().width(100).height(100).backgroundColor('#C5DEA3').borderRadius(50)
          .shadow({ radius: 16, color: '#1A638442', offsetY: 8 })
        Row({ space: 6 }) {
          ForEach([16, 30, 44, 30, 16], (height: number) => {
            Row().width(6).height(height).borderRadius(3).backgroundColor('#345E49')
          }, (height: number, index: number) => `${index}`)
        }.height(50).alignItems(VerticalAlign.Center)
      }.width('100%').height(158)
      Text('今天，想聊点什么？').fontSize(24).fontWeight(FontWeight.Bold).fontColor('#233B31')
        .margin({ top: 22, bottom: 10 })
      Text(this.mode === 'study' ? '把难懂的知识，聊成听得懂的答案。' : '一个问题，一个灵感，从开口开始。')
        .fontSize(13).fontColor('#8A968B').margin({ bottom: 26 })
      Column({ space: 10 }) {
        if (this.mode === 'study') {
          this.suggestion('把知识讲简单', '从一个熟悉的例子开始', '请用生活中的例子解释大语言模型是什么。')
          this.suggestion('一起制定学习计划', '拆成每天都能完成的小目标', '我是鸿蒙开发初学者，请帮我制定一周的 ArkTS 学习计划。')
        } else {
          this.suggestion('寻找一点灵感', '让想法再向前一步', '帮我想三个适合大学生开发的 AI 应用创意。')
          this.suggestion('整理今天的安排', '让忙碌变得更有条理', '请教我如何安排一天的学习、运动和休息时间。')
        }
      }.width('100%').padding({ left: 24, right: 24 })
    }.width('100%').padding({ bottom: 16 })
  }

  @Builder
  messageCard(message: ChatMessage) {
    Column({ space: 7 }) {
      Text(message.role === 'user' ? '你' : '和声 AI').fontSize(10).fontColor('#88958B')
      Text(message.content).fontSize(15).lineHeight(24)
        .fontColor(message.role === 'user' ? '#FFFFFF' : '#2C4436').copyOption(CopyOptions.LocalDevice)
        .padding(16).backgroundColor(message.role === 'user' ? '#345E49' : '#FFFFFF')
        .borderRadius(message.role === 'user' ? { topLeft: 18, topRight: 5, bottomLeft: 18, bottomRight: 18 } :
          { topLeft: 5, topRight: 18, bottomLeft: 18, bottomRight: 18 })
      if (message.role === 'assistant') {
        Button('朗读', { type: ButtonType.Normal }).height(28).fontSize(11).fontColor('#5E7E65')
          .backgroundColor('#EAF0E4').borderRadius(9).enabled(this.canType())
          .accessibilityText('朗读这条回复').onClick(() => { this.play(message.content); })
      } else if (message.status === 'failed' || message.status === 'canceled') {
        Row({ space: 8 }) {
          Text(message.status === 'failed' ? '发送失败' : '已取消').fontSize(11).fontColor('#9B735B')
          if (message.id === this.messages[this.messages.length - 1].id) {
            Button('重试').height(26).fontSize(11).fontColor('#345E49').backgroundColor('#EAF0E4')
              .enabled(this.canType()).onClick(() => { this.send(message.content, true); })
          }
        }
      }
    }.width('88%').alignItems(message.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
      .margin({ left: message.role === 'user' ? '12%' : 0, bottom: 18 })
  }

  @Builder
  chatBody() {
    Scroll(this.scroller) {
      if (this.messages.length === 0) { this.welcome(); }
      else {
        Column() {
          Text(this.mode === 'study' ? '学习助手 · 记得我们聊过的内容' : '通用对话 · 继续刚才的话题')
            .fontSize(11).fontColor('#8A968B').margin({ top: 20, bottom: 24 })
          ForEach(this.messages, (message: ChatMessage) => { this.messageCard(message); }, (message: ChatMessage) => message.id)
          if (this.status === 'thinking') {
            Row({ space: 10 }) {
              LoadingProgress().width(19).height(19).color('#638969')
              Text('和声正在思考…').fontSize(13).fontColor('#638969')
            }.width('100%').padding({ bottom: 18 })
          }
        }.width('100%').padding({ left: 24, right: 24, bottom: 10 }).alignItems(HorizontalAlign.Start)
      }
    }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
  }

  @Builder
  composer() {
    Column({ space: 10 }) {
      if (this.transcript && (this.status === 'listening' || this.status === 'recognizing')) {
        Text(this.transcript).fontSize(14).fontColor('#345E49').maxLines(3).width('100%')
          .padding(12).backgroundColor('#EDF3E4').borderRadius(12)
      }
      Row({ space: 14 }) {
        Button({ type: ButtonType.Circle }) {
          if (this.status !== 'idle') { Row().width(18).height(18).borderRadius(4).backgroundColor('#233B31'); }
          else { Image($r('app.media.ic_mic')).width(27).height(27); }
        }.width(58).height(58).backgroundColor(this.status === 'listening' ? '#D3ECAF' : '#DFECC6')
          .accessibilityText(this.status === 'idle' ? '开始语音输入' : this.status === 'listening' ? '结束录音并发送' : '停止')
          .enabled(this.initialized).onClick(() => { this.voiceAction(); })
        Column({ space: 5 }) {
          Text(this.statusText()).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#345E49')
          Text(this.status === 'listening' ? '说完后再轻点一次 · 最长 55 秒' : '语音与文字，都可以')
            .fontSize(11).fontColor('#8B988C')
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')
      Row({ space: 10 }) {
        TextInput({ placeholder: '也可以打字问我…', text: this.input }).layoutWeight(1).height(46)
          .fontSize(14).fontColor('#233B31').placeholderColor('#9AA69A').backgroundColor('#F1F3ED')
          .borderRadius(15).maxLength(4000).enterKeyType(EnterKeyType.Send).enabled(this.canType())
          .onChange((value: string) => { this.input = value; }).onSubmit(() => { this.send(this.input); })
        Button({ type: ButtonType.Normal }) { Image($r('app.media.ic_send')).width(22).height(22) }
          .width(46).height(46).borderRadius(15).backgroundColor('#345E49')
          .enabled(this.initialized && this.canType() && this.input.trim().length > 0)
          .opacity(this.input.trim().length > 0 ? 1 : 0.4).accessibilityText('发送问题').onClick(() => { this.send(this.input); })
      }.width('100%')
      Text('AI 生成内容，请结合实际核实').fontSize(9).fontColor('#A1ABA0')
    }.width('100%').padding({ left: 24, right: 24, top: 14, bottom: 14 }).backgroundColor('#FAFBF6')
  }

  @Builder
  subHeader(title: string, subtitle: string) {
    Row({ space: 12 }) {
      this.iconButton($r('app.media.ic_back'), '返回对话', () => { this.stopCurrent(); this.screen = 'chat'; })
      Column({ space: 4 }) {
        Text(title).fontSize(23).fontWeight(FontWeight.Bold).fontColor('#233B31')
        Text(subtitle).fontSize(11).fontColor('#849187')
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').padding({ left: 24, right: 24, top: 18, bottom: 22 })
  }

  @Builder
  settingsPage() {
    this.subHeader('连接你的 AI', '选择服务，开始一段有记忆的对话')
    this.noticeBar()
    Scroll() {
      Column({ space: 18 }) {
        Column({ space: 12 }) {
          Text('快速填写').fontSize(12).fontColor('#839183').width('100%')
          Row({ space: 10 }) {
            Button('通义千问', { type: ButtonType.Normal }).layoutWeight(1).height(40).borderRadius(12)
              .fontSize(13).fontColor('#345E49').backgroundColor('#E9F0DC').enabled(!this.testing)
              .onClick(() => { this.baseUrl = defaultSettings().baseUrl; this.model = 'qwen-plus'; this.testResult = ''; })
            Button('DeepSeek', { type: ButtonType.Normal }).layoutWeight(1).height(40).borderRadius(12)
              .fontSize(13).fontColor('#345E49').backgroundColor('#E9F0DC').enabled(!this.testing)
              .onClick(() => { this.baseUrl = 'https://api.deepseek.com'; this.model = 'deepseek-flash'; this.testResult = ''; })
          }
          Text('支持兼容 Chat Completions 的云端服务，也可以手动填写。').fontSize(11).lineHeight(18)
            .fontColor('#89968A').width('100%')
        }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
        Column({ space: 10 }) {
          Text('服务地址 / Base URL').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#345E49').width('100%')
          TextInput({ text: this.baseUrl, placeholder: 'https://…/v1' }).fontSize(13).height(46)
            .maxLength(2048).backgroundColor('#F1F4EC').enabled(!this.testing)
            .onChange((value: string) => { this.baseUrl = value; this.testResult = ''; })
          Text('模型名称').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#345E49').width('100%').margin({ top: 8 })
          TextInput({ text: this.model, placeholder: '填写服务商提供的模型名称' }).fontSize(13).height(46)
            .maxLength(128).backgroundColor('#F1F4EC').enabled(!this.testing)
            .onChange((value: string) => { this.model = value; this.testResult = ''; })
          Text('API Key').fontSize(13).fontWeight(FontWeight.Medium).fontColor('#345E49').width('100%').margin({ top: 8 })
          TextInput({ text: this.apiKey, placeholder: '填写你的 API Key' }).type(InputType.Password).fontSize(13).height(46)
            .maxLength(4096).backgroundColor('#F1F4EC').enabled(!this.testing)
            .onChange((value: string) => { this.apiKey = value; this.testResult = ''; })
          Text('密钥仅在本次运行中使用，重新打开应用后需要再次填写。').fontSize(11).lineHeight(18)
            .fontColor('#89968A').width('100%')
        }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
        Row() {
          Column({ space: 5 }) {
            Text('自动朗读回复').fontSize(14).fontColor('#345E49')
            Text('收到答案后，用声音告诉你').fontSize(11).fontColor('#89968A')
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.autoSpeak }).selectedColor('#638969').enabled(!this.testing)
            .onChange((value: boolean) => { this.autoSpeak = value; })
        }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(18)
        Text('语音在设备上转成文字。问题和最近的对话会发送到你配置的云端服务；历史记录保存在本机。')
          .fontSize(11).lineHeight(19).fontColor('#89968A').width('100%')
        if (this.testResult) { Text(this.testResult).fontSize(13).fontColor('#52745B').width('100%'); }
        Row({ space: 10 }) {
          Button(this.testing ? '正在测试…' : '测试连接', { type: ButtonType.Normal }).layoutWeight(1).height(48)
            .borderRadius(15).fontSize(14).fontColor('#345E49').backgroundColor('#E6EDD9')
            .enabled(this.initialized && !this.testing).onClick(() => { this.testConnection(); })
          Button('保存设置', { type: ButtonType.Normal }).layoutWeight(1).height(48).borderRadius(15)
            .fontSize(14).fontColor('#FFFFFF').backgroundColor('#345E49').enabled(this.initialized && !this.testing)
            .onClick(() => { this.saveSettings(); })
        }
      }.width('100%').padding({ left: 24, right: 24, bottom: 28 })
    }.layoutWeight(1).scrollBar(BarState.Off)
  }

  @Builder
  historyPage() {
    this.subHeader('聊过的，都记得', '保留最近 20 段对话 · 可继续追问')
    this.noticeBar()
    if (this.conversations.length === 0) {
      Column({ space: 14 }) {
        Image($r('app.media.ic_history')).width(45).height(45).opacity(0.5)
        Text('还没有对话记录').fontSize(18).fontColor('#345E49')
        Text('开始聊天后，你的对话会出现在这里。').fontSize(12).fontColor('#89968A')
        Button('开始对话').fontSize(14).backgroundColor('#345E49').onClick(() => { this.screen = 'chat'; })
      }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
    } else {
      Scroll() {
        Column({ space: 12 }) {
          ForEach(this.conversations, (item: Conversation) => {
            Row({ space: 12 }) {
              Column({ space: 8 }) {
                Text(item.title).fontSize(15).fontWeight(FontWeight.Medium).fontColor('#345E49').maxLines(1)
                Text(`${item.mode === 'study' ? '学习助手' : '通用对话'} · ${new Date(item.updatedAt).toLocaleDateString()} · ${item.messages.filter((message: ChatMessage) => message.role === 'assistant').length} 轮`)
                  .fontSize(11).fontColor('#89968A')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding({ top: 6, bottom: 6 })
                .onClick(() => { this.restore(item); })
              Button('删除', { type: ButtonType.Normal }).height(30).fontSize(11).fontColor('#9B735B')
                .backgroundColor('#FBF2EA').borderRadius(9).onClick(() => { this.deleteHistory(item.id); })
            }.width('100%').padding(18).backgroundColor('#FFFFFF').borderRadius(17)
          }, (item: Conversation) => item.id)
        }.width('100%').padding({ left: 24, right: 24, bottom: 24 })
      }.layoutWeight(1).width('100%').scrollBar(BarState.Off)
    }
  }

  build() {
    Column() {
      if (this.screen === 'settings') { this.settingsPage(); }
      else if (this.screen === 'history') { this.historyPage(); }
      else {
        this.header()
        this.noticeBar()
        this.modePicker()
        this.chatBody()
        this.composer()
      }
    }.width('100%').height('100%').backgroundColor('#F6F8F0')
  }
}
