import SwiftUI
import GoogleSignIn

@main struct SmailApp: App {
    @State private var auth = GoogleAuth()
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var systemLanguages = Locale.preferredLanguages
    var body: some Scene {
        WindowGroup {
            RootView(auth: auth)
                .environment(\.locale, Locale(identifier: (AppLanguage(rawValue: language) ?? .system).resolvedIdentifier(preferredLanguages: systemLanguages)))
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { systemLanguages = Locale.preferredLanguages }
                }
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
    }
}

enum Palette {
    static let paper = Color(red: 0.97, green: 0.96, blue: 0.92)
    static let ink = Color(red: 0.13, green: 0.20, blue: 0.19)
    static let green = Color(red: 0.16, green: 0.42, blue: 0.33)
    static let coral = Color(red: 0.72, green: 0.32, blue: 0.22)
}

struct RootView: View {
    @Bindable var auth: GoogleAuth
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system.rawValue
    @State private var store: BatchStore?
    @State private var setupError: String?
    @State private var settings = false
    @State private var demo = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.paper.ignoresSafeArea()
                if let store { DeckView(store: store, demo: demo) }
                else { welcome }
            }
            .foregroundStyle(Palette.ink)
            .navigationTitle("Smail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Image(systemName: "envelope.badge.fill").font(.title3).foregroundStyle(Palette.green)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("设置").accessibilityIdentifier("settings")
                }
            }
            .sheet(isPresented: $settings) { settingsView }
            .safeAreaInset(edge: .bottom) {
                if let setupError { ErrorMessage(setupError).font(.footnote).foregroundStyle(.red).padding().background(.regularMaterial) }
            }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--reset-language") { language = AppLanguage.system.rawValue }
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") { startDemo(); return }
                #endif
                await auth.restore(); attach()
            }
            .onChange(of: auth.account) { _, _ in attach() }
            .onChange(of: phase) { _, value in if value == .active, let store { Task { await store.flush() } } }
        }
        .tint(Palette.green)
        .preferredColorScheme(.light)
    }

    private var welcome: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 30).fill(Palette.green.opacity(0.12)).frame(width: 180, height: 210).rotationEffect(.degrees(-12))
                RoundedRectangle(cornerRadius: 30).fill(.white).frame(width: 180, height: 210).rotationEffect(.degrees(7)).shadow(color: .black.opacity(0.06), radius: 20, y: 10)
                Image(systemName: "envelope.open.fill").font(.system(size: 65)).foregroundStyle(Palette.green)
            }.accessibilityHidden(true)
            VStack(spacing: 12) {
                Text("小小一划，\n给重要的事留点空间。").font(.system(size: 31, weight: .bold, design: .rounded)).multilineTextAlignment(.center)
                Text("每次十封。左划没用，右划有用。\n分类标签直接同步到 Gmail。").foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer()
            if let error = auth.error { ErrorMessage(error).font(.footnote).foregroundStyle(Palette.coral) }
            Button { Task { await auth.signIn() } } label: {
                HStack { if auth.busy { ProgressView().tint(.white) }; Text("连接 Google 账号").fontWeight(.semibold) }.frame(maxWidth: .infinity).padding(18)
            }.buttonStyle(.plain).background(Palette.green, in: Capsule()).foregroundStyle(.white).disabled(auth.busy)
                .accessibilityIdentifier("connect")
            Text("只读取邮件、修改分类标签。\n原邮件和已读状态保持不变。").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            #if DEBUG
            Button("先体验十封演示邮件") { startDemo() }.font(.footnote).accessibilityIdentifier("demo")
            #endif
        }.padding(28)
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("语言") {
                    Picker("语言", selection: $language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }.pickerStyle(.menu).accessibilityIdentifier("language-picker")
                }
                Section("Google 账号") {
                    if demo { Text("演示模式 · 不连接 Gmail") }
                    else if let email = auth.email { Text(verbatim: email) }
                    else { Text("尚未连接") }
                    if demo {
                        Button("退出演示") { demo = false; store?.stop(); store = nil; settings = false; attach() }
                    } else {
                        Button(LocalizedStringKey(auth.account == nil ? "连接 Google" : "重新授权")) {
                            settings = false
                            Task { await auth.signIn() }
                        }.disabled(auth.busy || store?.syncing == true)
                        if auth.account != nil {
                            Button("退出登录（保留本机分类进度）") {
                                store?.stop(); store = nil; auth.signOut(); settings = false
                            }.disabled(store?.syncing == true)
                            Button("撤销 Smail 的 Google 授权", role: .destructive) {
                                Task {
                                    let old = auth.account
                                    await auth.disconnect()
                                    if auth.account == nil, let old {
                                        do { try BatchDisk().remove(old) } catch { setupError = "授权已撤销，但本机缓存清理失败。" }
                                        settings = false
                                    }
                                }
                            }.disabled(auth.busy || store?.syncing == true || !(store?.batch.pending.isEmpty ?? true))
                        }
                    }
                    if let error = auth.error { ErrorMessage(error).foregroundStyle(.red) }
                }
                Section("分类方式") {
                    Label("右划 → Smail/Useful", systemImage: "arrow.right")
                    Label("左划 → Smail/NotUseful", systemImage: "arrow.left")
                    Text("每批取收件箱最新的十封未分类邮件，包含已读和未读，按收件时间倒序。带有 Smail 分类标签的邮件不会重复出现。撤销会恢复上一封的分类标签。")
                }
                Section("你的邮件，由你掌控") {
                    Text("Smail 直接连接 Google，没有后台服务器。邮件不上传到其他服务，不用于 AI 分析。")
                    Text("只创建和修改 Smail 的两个自定义标签。不删除、归档、发送邮件，不修改已读状态。Google 授权页面所列 gmail.modify 权限较宽，Smail 在程序内限定上述操作。")
                    Text("批次与待同步操作保存在受 iOS 文件保护的本机存储中。正文保留 HTML 排版，脚本始终禁用；外部图片由你选择加载，可能让发件人知道邮件已被打开。")
                    Text("测试期间 Google 可能每七天要求重新授权；本机进度会保留。")
                }.font(.footnote)
                Section {
                    Text("Smail \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                }
            }.navigationTitle("设置").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
        }
        // Recreate only the settings navigation chrome when its locale changes.
        // The account, in-progress batch, and pending writes remain in RootView.
        .id(language)
        .environment(\.locale, Locale(identifier: (AppLanguage(rawValue: language) ?? .system).resolvedIdentifier()))
    }

    private func attach() {
        guard !demo else { return }
        if let account = auth.account, store?.batch.account == account { return }
        store?.stop(); store = nil; setupError = nil
        guard let account = auth.account else { return }
        do {
            let client = GmailClient { try await auth.token(for: account) }
            let next = try BatchStore(account: account, service: client)
            store = next
            Task { await next.flush() }
        } catch { setupError = "本地批次无法读取：\(error.localizedDescription)" }
    }
    private func startDemo() {
        #if DEBUG
        do {
            store?.stop()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("smail-demo-" + UUID().uuidString)
            store = try BatchStore(account: "demo", service: DemoService(), disk: BatchDisk(root: root))
            demo = true
            if let store { Task { await store.load() } }
        } catch { setupError = error.localizedDescription }
        #endif
    }
}

struct DeckView: View {
    @Bindable var store: BatchStore
    let demo: Bool
    @State private var drag: CGSize = .zero
    @State private var dismissing = false
    @State private var cardWidth: CGFloat = 400
    @State private var detail: Mail?
    @State private var haptic = 0

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text(LocalizedStringKey(demo ? "演示 · 十封小练习" : "INBOX · 未分类 · 最新优先")).font(.caption.weight(.bold)).tracking(0.5)
                    .lineLimit(2).minimumScaleFactor(0.8)
                Spacer()
                Text("\(store.batch.decisions.count) / \(store.batch.total)").font(.system(.subheadline, design: .monospaced)).accessibilityIdentifier("progress")
                Button { Task { await store.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(store.loading || store.syncing || dismissing || !store.batch.pending.isEmpty)
                    .accessibilityLabel("重新取最新十封").accessibilityIdentifier("refresh-batch")
            }.foregroundStyle(.secondary)
            if store.loading {
                Spacer(); ProgressView("正在准备十封邮件…"); Spacer()
            } else if let mail = store.current {
                ZStack {
                    if store.batch.mails.count > 1 {
                        card(store.batch.mails[1])
                            .scaleEffect(dismissing ? 1 : 0.95)
                            .offset(y: dismissing ? 0 : 12)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                card(mail)
                    .overlay(alignment: drag.width >= 0 ? .topLeading : .topTrailing) {
                        if abs(drag.width) > 35 {
                            Text(LocalizedStringKey(drag.width > 0 ? "有用 ✓" : "没用 ×")).font(.title.bold()).padding(16)
                                .foregroundStyle(drag.width > 0 ? Palette.green : Palette.coral)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(20)
                        }
                    }
                    .rotationEffect(.degrees(Double(min(max(drag.width / 24, -18), 18))))
                    .offset(x: drag.width, y: abs(drag.width) * 0.06)
                    .highPriorityGesture(DragGesture(minimumDistance: 20).onChanged { value in
                        guard !dismissing else { return }
                        if abs(value.translation.width) > abs(value.translation.height) { drag = value.translation }
                    }.onEnded { value in
                        guard !dismissing else { return }
                        let x = value.translation.width
                        if abs(x) > 95 && abs(x) > abs(value.translation.height) {
                            choose(x > 0 ? .useful : .notUseful)
                        } else {
                            withAnimation(.spring(response: 0.3)) { drag = .zero }
                        }
                    })
                    .allowsHitTesting(!dismissing)
                    .accessibilityIdentifier("mail-card")
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardWidth = $0 }
                HStack(spacing: 28) {
                    action(.notUseful, icon: "xmark", color: Palette.coral)
                    Button { store.undo(); haptic += 1 } label: { Image(systemName: "arrow.uturn.backward").font(.title3).frame(width: 48, height: 48).background(.white, in: Circle()) }
                        .disabled(!store.canUndo || dismissing).accessibilityLabel("撤销上一封").accessibilityIdentifier("undo")
                    action(.useful, icon: "checkmark", color: Palette.green)
                }
                Text("左划没用 · 右划有用 · 点卡片阅读全文").font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer()
                Image(systemName: store.batch.started ? "checkmark.seal" : "rectangle.stack").font(.system(size: 64)).foregroundStyle(Palette.green)
                Text(LocalizedStringKey(store.batch.started ? (store.batch.total == 0 ? "收件箱，暂时理好了。" : "十封之间，轻一点。") : "给收件箱一分钟。")).font(.title2.bold()).multilineTextAlignment(.center)
                if store.batch.started && store.batch.total > 0 {
                    Text("有用 \(store.batch.decisions.filter { $0.choice == .useful }.count) 封  ·  没用 \(store.batch.decisions.filter { $0.choice == .notUseful }.count) 封").foregroundStyle(.secondary)
                    Button("撤销上一封") { store.undo() }.disabled(!store.canUndo).accessibilityIdentifier("undo")
                } else { Text("每次最多十封，随时可以停下。") .foregroundStyle(.secondary) }
                Button { Task { await store.load() } } label: {
                    Text(LocalizedStringKey(store.batch.started ? "再来十封" : "开始十封")).fontWeight(.semibold).padding(.horizontal, 40).padding(.vertical, 17)
                }.buttonStyle(.plain).background(Palette.green, in: Capsule()).foregroundStyle(.white)
                    .disabled(!store.batch.pending.isEmpty).accessibilityIdentifier("next-batch")
                Spacer()
            }
            status
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
        .sensoryFeedback(.impact(weight: .light), trigger: haptic)
        .sheet(item: $detail) { mail in
            MailReader(mail: mail) { try await store.detail(for: mail) }
        }
    }
    private func card(_ mail: Mail) -> some View {
        Button { detail = mail } label: {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(String(mail.from.prefix(1)).uppercased()).font(.title2.bold()).frame(width: 50, height: 50).background(Palette.paper, in: RoundedRectangle(cornerRadius: 17))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mail.from).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(mail.date, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                Divider()
                MailSubject(subject: mail.subject).font(.system(.title2, design: .rounded, weight: .bold)).lineLimit(4)
                Text(mail.snippet).font(.body).lineSpacing(6).foregroundStyle(.secondary).lineLimit(7)
                Spacer(minLength: 0)
                HStack { Text("阅读全文").font(.caption.weight(.semibold)); Spacer(); Image(systemName: "arrow.up.right") }.foregroundStyle(Palette.green)
            }.padding(25).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.white, in: RoundedRectangle(cornerRadius: 30))
                .shadow(color: Palette.ink.opacity(0.07), radius: 18, y: 9)
                .overlay(RoundedRectangle(cornerRadius: 30).stroke(Palette.ink.opacity(0.05)))
        }.buttonStyle(.plain)
    }
    private func action(_ choice: Choice, icon: String, color: Color) -> some View {
        Button { choose(choice) } label: {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.title2.bold()).frame(width: 68, height: 68).background(color.opacity(0.12), in: Circle())
                Text(LocalizedStringKey(choice.title)).font(.caption.weight(.semibold))
            }.foregroundStyle(color)
        }.disabled(dismissing).accessibilityIdentifier(choice.rawValue)
    }
    private func choose(_ choice: Choice) {
        guard !dismissing, store.current != nil else { return }
        haptic += 1
        // Keep the outgoing message mounted until it has completely left the viewport.
        // This also prevents a quick second tap from classifying the next message.
        let distance = max(cardWidth * 1.8, 720)
        withAnimation(.easeIn(duration: 0.45), completionCriteria: .logicallyComplete) {
            dismissing = true
            drag = CGSize(width: choice == .useful ? distance : -distance, height: 0)
        } completion: {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                store.choose(choice)
                drag = .zero
                dismissing = false
            }
        }
    }
    @ViewBuilder private var status: some View {
        if let error = store.error {
            VStack(spacing: 8) {
                ErrorMessage(error).font(.caption).foregroundStyle(Palette.coral).multilineTextAlignment(.center)
                Button("重试") { Task { if store.batch.pending.isEmpty { await store.load() } else { await store.flush() } } }.font(.footnote.bold())
            }.padding(12).frame(maxWidth: .infinity).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
        } else if !store.batch.pending.isEmpty {
            HStack { ProgressView(); Text("\(store.batch.pending.count) 项待同步，进度已保存在本机") }.font(.caption).foregroundStyle(.secondary)
        } else {
            Label(LocalizedStringKey(demo ? "演示模式，不会修改真实邮件" : "只改标签 · 原邮件保持不变"), systemImage: "lock.shield").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
