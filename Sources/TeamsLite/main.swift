import AppKit
import WebKit
import UserNotifications
import Carbon.HIToolbox

private enum TeamsPolicy {
    // Current canonical Teams web entry point.
    static let homeURL = URL(string: "https://teams.cloud.microsoft/")!

    static let trustedHosts: Set<String> = [
        "teams.cloud.microsoft",
        "teams.microsoft.com",
        "login.microsoftonline.com",
        "login.live.com",
        "login.windows.net",
        "account.microsoft.com",
        "teams.public.onecdn.static.microsoft"
    ]

    static let trustedSuffixes: [String] = [
        ".microsoft.com",
        ".microsoftonline.com",
        ".microsoft365.com",
        ".office.com",
        ".office365.com",
        ".live.com",
        ".windows.net",
        ".msauth.net",
        ".msftauth.net",
        ".sharepoint.com",
        ".onecdn.static.microsoft",
        ".cdn.office.net"
    ]

    static func isTrustedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        if trustedHosts.contains(host) { return true }
        return trustedSuffixes.contains { host.hasSuffix($0) }
    }

    // Хосты самого Teams (не логин, не CDN).
    static func isTeamsAppHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "teams.cloud.microsoft" || host == "teams.microsoft.com"
    }

    static func isTrustedHTTPS(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        return isTrustedHost(url.host)
    }

    static func isThirdPartyCookieProbe(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.lastPathComponent == "report-third-party-cookies.html"
            && isTrustedHost(url.host)
    }

    // Domains which are Microsoft-owned/content destinations and should stay
    // inside the lightweight wrapper when the user clicks them.
    static func isInternalMicrosoftURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }

        if host == "teams.cloud.microsoft" || host == "teams.microsoft.com" {
            return true
        }

        let internalSuffixes = [
            ".sharepoint.com",
            ".office.com",
            ".office365.com",
            ".microsoft365.com",
            ".microsoft.com",
            ".msftauth.net",
            ".msauth.net"
        ]
        return internalSuffixes.contains { host.hasSuffix($0) }
    }

    // Explicit interactive identity/account pages are better left to Safari
    // when the user clicks them directly. Teams' own redirects are not treated
    // as external merely because they pass through these hosts.
    static func isInteractiveAuthURL(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "login.microsoftonline.com"
            || host == "login.live.com"
            || host == "account.microsoft.com"
            || host == "login.windows.net"
    }
}

private enum Config {
    // true: закрытие окна (⌘W / красная кнопка) только прячет его, приложение остаётся
    // жить и показывает уведомления. false: поведение v3.8 (закрыл окно — вышел).
    static let keepRunningInBackground = true

    // Глобальный хоткей «показать/спрятать Teams Lite». nil — отключить.
    static let toggleHotkey: (keyCode: Int, modifiers: Int)? =
        (kVK_ANSI_T, controlKey | optionKey | cmdKey)   // ⌃⌥⌘T

    // Notification-shim ставится только в главный фрейм (дешевле).
    // Если уведомления не приходят — поставить true.
    static let shimInSubframes = false

    // Mute/unmute из любого приложения, как в Discord.
    // ` (физическая клавиша слева от 1, на русской раскладке это ё) без модификаторов
    // перехватывается системно, поэтому она активна ТОЛЬКО пока идёт звонок (иначе ` не набрать нигде).
    // Запасной ⌃⌥M работает всегда. Пустой массив отключает mute-хоткеи.
    static let muteHotkeys: [(keyCode: Int, modifiers: Int, onlyDuringCalls: Bool)] = [
        (kVK_ANSI_Grave, 0, true),
        (kVK_ANSI_M, controlKey | optionKey, false)
    ]

    // Safari Web Inspector для WKWebView (Safari → Develop → Teams Lite): нужен, чтобы
    // найти реальный селектор кнопки mute, если Teams поменяет разметку.
    static let inspectable = true

    // Если версию установленного Safari прочитать не удалось.
    static let safariVersionFallback = "27.2"
}

// Переключатели для поиска причин без пересборки: открыть с аргументами, например
//   open -n -a "/Applications/MiTeams Lite.app" --args -TLNoShim YES
//   open -n -a "/Applications/MiTeams Lite.app" --args -TLUA 18.6
private enum DebugFlags {
    static var noShim: Bool { UserDefaults.standard.bool(forKey: "TLNoShim") }
    static var uaVersion: String? { UserDefaults.standard.string(forKey: "TLUA") }
    static var noAppLinkFix: Bool { UserDefaults.standard.bool(forKey: "TLNoAppLinkFix") }
}

// Версия UA берётся у установленного Safari, чтобы не отставать от движка WebKit.
private enum SafariVersion {
    static func current() -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
           let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           version.range(of: "^[0-9]+(\\.[0-9]+){0,2}$", options: .regularExpression) != nil {
            return version
        }
        return Config.safariVersionFallback
    }
}

// Подменяет window.Notification внутри страницы Teams и пересылает показ в нативное
// уведомление macOS. Без таймеров и опроса: один документ-старт скрипт.
private enum NotificationShim {
    static let source = #"""
(function () {
  try {
    var host = location.hostname || '';
    if (!/(^|\.)(microsoft\.com|cloud\.microsoft|microsoft365\.com|office\.com|office365\.com|sharepoint\.com|microsoftonline\.com|live\.com)$/.test(host)) { return; }
    if (window.__tlShim) { return; }
    window.__tlShim = true;

    var post = function (m) {
      try { window.webkit.messageHandlers.tlNotify.postMessage(m); } catch (e) {}
    };
    var seq = 0;
    var live = {};

    function TLNotification(title, options) {
      if (!(this instanceof TLNotification)) {
        throw new TypeError("Failed to construct 'Notification': Please use the 'new' operator.");
      }
      options = options || {};
      this.title = String(title);
      this.body = options.body ? String(options.body) : '';
      this.tag = options.tag ? String(options.tag) : '';
      this.icon = options.icon || '';
      this.data = options.data;
      this.silent = !!options.silent;
      this.requireInteraction = !!options.requireInteraction;
      this.timestamp = Date.now();
      this.onclick = null; this.onclose = null; this.onshow = null; this.onerror = null;
      this._l = {};
      this._id = 'tl' + (++seq) + '-' + Date.now().toString(36);
      live[this._id] = this;
      post({ type: 'show', id: this._id, title: this.title, body: this.body, tag: this.tag, silent: this.silent });
      var self = this;
      setTimeout(function () { self._emit('show'); }, 0);
    }
    TLNotification.prototype._emit = function (type) {
      var ev = { type: type, target: this, currentTarget: this, preventDefault: function () {} };
      var h = this['on' + type];
      if (typeof h === 'function') { try { h.call(this, ev); } catch (e) {} }
      var ls = this._l[type] || [];
      for (var i = 0; i < ls.length; i++) { try { ls[i].call(this, ev); } catch (e) {} }
    };
    TLNotification.prototype.addEventListener = function (type, fn) {
      (this._l[type] = this._l[type] || []).push(fn);
    };
    TLNotification.prototype.removeEventListener = function (type, fn) {
      var ls = this._l[type] || [];
      var i = ls.indexOf(fn);
      if (i >= 0) { ls.splice(i, 1); }
    };
    TLNotification.prototype.dispatchEvent = function (ev) { this._emit(ev && ev.type); return true; };
    TLNotification.prototype.close = function () {
      post({ type: 'close', id: this._id });
      delete live[this._id];
      this._emit('close');
    };
    Object.defineProperty(TLNotification, 'permission', { get: function () { return 'granted'; }, configurable: true });
    TLNotification.maxActions = 2;
    TLNotification.requestPermission = function (cb) {
      if (typeof cb === 'function') { try { cb('granted'); } catch (e) {} }
      return Promise.resolve('granted');
    };
    try {
      Object.defineProperty(window, 'Notification', { value: TLNotification, writable: true, configurable: true });
    } catch (e) { window.Notification = TLNotification; }

    if (window.ServiceWorkerRegistration && ServiceWorkerRegistration.prototype) {
      ServiceWorkerRegistration.prototype.showNotification = function (title, options) {
        new TLNotification(title, options);
        return Promise.resolve();
      };
    }
    if (navigator.permissions && navigator.permissions.query) {
      var origQuery = navigator.permissions.query.bind(navigator.permissions);
      navigator.permissions.query = function (d) {
        var p = origQuery(d);
        if (d && d.name === 'notifications') {
          // Остаётся настоящий PermissionStatus (EventTarget), меняется только state.
          return p.then(function (status) {
            try { Object.defineProperty(status, 'state', { get: function () { return 'granted'; }, configurable: true }); } catch (e) {}
            return status;
          });
        }
        return p;
      };
    }

    // Вызывается нативной стороной при клике по уведомлению.
    window.__tlClick = function (id) {
      var n = live[id];
      if (!n) { return; }
      try { window.focus(); } catch (e) {}
      n._emit('click');
    };

    // Вызывается нативной стороной по глобальному хоткею mute/unmute.
    // 1) нажать кнопку микрофона в панели звонка, 2) запасной путь: встроенный шорткат Teams ⌘⇧M.
    window.__tlToggleMute = function () {
      var selectors = [
        '[data-tid="toggle-mute"]',
        '[data-tid="microphone-button"]',
        'button#microphone-button'
      ];
      for (var i = 0; i < selectors.length; i++) {
        var el = document.querySelector(selectors[i]);
        if (el && !el.disabled) { el.click(); return 'click:' + selectors[i]; }
      }
      var init = { key: 'm', code: 'KeyM', metaKey: true, shiftKey: true, bubbles: true, cancelable: true, composed: true };
      var target = document.activeElement || document.body;
      ['keydown', 'keyup'].forEach(function (t) {
        var e = new KeyboardEvent(t, init);
        try {
          Object.defineProperty(e, 'keyCode', { get: function () { return 77; } });
          Object.defineProperty(e, 'which', { get: function () { return 77; } });
        } catch (x) {}
        target.dispatchEvent(e);
      });
      return 'shortcut';
    };
  } catch (e) {}
})();
"""#
}

final class NotificationBridge: NSObject, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    weak var webView: WKWebView?
    var onActivate: (() -> Void)?
    var windowIsFront: () -> Bool = { false }
    private var idByTag: [String: String] = [:]

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            NSLog("[TL] notification authorization granted=\(granted) error=\(String(describing: error))")
        }
    }

    static func isSafeID(_ id: String) -> Bool {
        id.count <= 64 && id.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let origin = message.frameInfo.securityOrigin
        guard origin.protocol.lowercased() == "https",
              TeamsPolicy.isTrustedHost(origin.host),
              let payload = message.body as? [String: Any],
              let type = payload["type"] as? String,
              let id = payload["id"] as? String,
              NotificationBridge.isSafeID(id) else { return }

        switch type {
        case "show": show(id: id, payload: payload)
        case "close": remove(id: id)
        default: break
        }
    }

    private func show(id: String, payload: [String: Any]) {
        let title = String((payload["title"] as? String ?? "").prefix(200))
        let text = String((payload["body"] as? String ?? "").prefix(1000))
        let tag = String((payload["tag"] as? String ?? "").prefix(200))
        let silent = payload["silent"] as? Bool ?? false

        let center = UNUserNotificationCenter.current()

        // Тот же tag заменяет предыдущее уведомление, как в Web Notifications.
        if !tag.isEmpty {
            if let old = idByTag[tag] {
                center.removeDeliveredNotifications(withIdentifiers: [old])
            }
            idByTag[tag] = id
        }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Teams" : title
        content.body = text
        content.userInfo = ["id": id]
        if !tag.isEmpty { content.threadIdentifier = tag }
        if !silent { content.sound = .default }

        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { NSLog("[TL] notification add failed: \(error)") }
        }
    }

    private func remove(id: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // Приложение «активно», но окно спрятано (⌘W) — баннер всё равно нужен.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(windowIsFront() ? [] : [.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo["id"] as? String
        DispatchQueue.main.async { [weak self] in
            self?.onActivate?()
            if let id, NotificationBridge.isSafeID(id) {
                self?.webView?.evaluateJavaScript(
                    "window.__tlClick && window.__tlClick('\(id)')",
                    completionHandler: nil
                )
            }
        }
        completionHandler()
    }
}

// Глобальные хоткеи через Carbon RegisterEventHotKey: работают в sandbox
// и не требуют разрешений Accessibility / Input Monitoring.
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private let signature: OSType = 0x544C4B31   // 'TLK1'

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        NSLog("[TL] RegisterEventHotKey key=\(keyCode) mods=\(modifiers) status=\(status)")
        guard status == noErr, let registered = ref else { return nil }
        refs[id] = registered
        handlers[id] = action
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers.removeValue(forKey: id)
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                UInt32(kEventParamDirectObject),
                UInt32(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotkeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

final class TeamsWebController: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView!
    let notifications = NotificationBridge()
    private var titleObservation: NSKeyValueObservation?
    private var micObservation: NSKeyValueObservation?
    private var callEndWork: DispatchWorkItem?
    private var inCall = false
    private var appLinkBypassURL: URL?
    private var lastAppLinkReissue = Date.distantPast
    var onCallStateChange: ((Bool) -> Void)?
    private var transientWebViews: [WKWebView] = []

    private func retainTransient(_ webView: WKWebView, timeout: TimeInterval) {
        transientWebViews.append(webView)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self, weak webView] in
            guard let self, let webView else { return }
            self.releaseTransient(webView)
        }
    }

    private func releaseTransient(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        transientWebViews.removeAll { $0 === webView }
    }

    override init() {
        super.init()

        let configuration = WKWebViewConfiguration()

        // IMPORTANT FOR SESSION PRESERVATION:
        // keep the default persistent WebKit data store.
        configuration.websiteDataStore = .default()

        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Мост уведомлений: один маленький скрипт на старте документа, без таймеров.
        configuration.userContentController.add(notifications, name: "tlNotify")
        if DebugFlags.noShim {
            NSLog("[TL] shim disabled by -TLNoShim")
        } else {
            configuration.userContentController.addUserScript(WKUserScript(
                source: NotificationShim.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: !Config.shimInSubframes
            ))
        }

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // Teams Web behaves badly with the default embedded WKWebView UA.
        // Use a Safari-compatible UA instead of pretending to be Chrome.
        // The renderer is still Apple's native WebKit.
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
            "Version/\(DebugFlags.uaVersion ?? SafariVersion.current()) Safari/605.1.15"
        NSLog("[TL] user agent: \(webView.customUserAgent ?? "default")")

        webView.allowsMagnification = true

        notifications.webView = webView
        if #available(macOS 13.3, *) { webView.isInspectable = Config.inspectable }

        // «Идёт звонок» = страница держит микрофон. Нужно, чтобы ` как mute жил только на время звонка.
        micObservation = webView.observe(\.microphoneCaptureState, options: [.new]) { [weak self] _, _ in
            self?.micStateChanged()
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            self?.updateBadge(from: wv.title)
        }
    }

    private func micStateChanged() {
        if webView.microphoneCaptureState != .none {
            callEndWork?.cancel()
            callEndWork = nil
            if !inCall {
                inCall = true
                onCallStateChange?(true)
            }
        } else if inCall && callEndWork == nil {
            // Небольшая задержка: захват может мигнуть при переподключении, а в mute звонок продолжается.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.callEndWork = nil
                if self.webView.microphoneCaptureState == .none {
                    self.inCall = false
                    self.onCallStateChange?(false)
                }
            }
            callEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    func toggleMute() {
        webView.evaluateJavaScript("window.__tlToggleMute && window.__tlToggleMute()") { result, error in
            NSLog("[TL] mute via: \(String(describing: result)) error=\(String(describing: error))")
        }
    }

    // Teams ставит счётчик непрочитанного в начало заголовка: "(3) Chat | ...".
    private func updateBadge(from title: String?) {
        var count = 0
        if let title,
           let match = title.range(of: "^\\s*\\((\\d{1,3})\\)", options: .regularExpression) {
            let digits = title[match].filter { $0.isNumber }
            count = Int(digits) ?? 0
        }
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    func start() {
        webView.load(URLRequest(url: TeamsPolicy.homeURL))
    }

    private func openExternal(_ url: URL) {
        NSLog("[TL] openExternal host=\(url.host ?? "-")")
        // Force Safari by bundle identifier. Using NSWorkspace.open(url)
        // may still hand the URL to the user's default browser.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-b", "com.apple.Safari", url.absoluteString]

        do {
            try task.run()
        } catch {
            NSLog("Failed to force-open Safari: \(error)")
        }
    }

    // Performance-oriented policy:
    // only intercept top-level navigations.
    // Subframes are left to WebKit so Teams auth/content flow is not micromanaged.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Only route top-level user navigation. Subframes/resources are left to
        // WebKit so Teams can load its own Microsoft/CDN dependencies normally.
        if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
            decisionHandler(.allow)
            return
        }

        let isUserClick = navigationAction.navigationType == .linkActivated
        NSLog("[TL] nav scheme=\(url.scheme ?? "-") host=\(url.host ?? "-") click=\(isUserClick) "
              + "method=\(navigationAction.request.httpMethod ?? "-") type=\(navigationAction.navigationType.rawValue) "
              + "from=\(webView.url?.host ?? "-")")

        // Cross-site переход на Teams не от пользователя (редирект после логина): WebKit пробует открыть
        // его как universal link в приложении, заявившем этот домен (например, Safari Web App «Teams (PWA)»).
        // Тогда запускается то приложение, а навигация в Lite обрывается (WebKitErrorDomain 102) и окно
        // зависает на странице логина. Программный load() app link не пробует, поэтому перезапускаем так.
        if !DebugFlags.noAppLinkFix, !isUserClick,
           url.scheme?.lowercased() == "https",
           TeamsPolicy.isTeamsAppHost(url.host),
           (navigationAction.request.httpMethod ?? "GET") == "GET",
           navigationAction.navigationType != .backForward,
           navigationAction.navigationType != .reload {
            if let bypass = appLinkBypassURL, bypass == url {
                appLinkBypassURL = nil   // это наш собственный load(): пропускаем как обычную навигацию
            } else if let current = webView.url?.host, !TeamsPolicy.isTeamsAppHost(current),
                      Date().timeIntervalSince(lastAppLinkReissue) > 10 {
                lastAppLinkReissue = Date()
                appLinkBypassURL = url
                NSLog("[TL] reissue cross-site nav as programmatic load from=\(current) to=\(url.host ?? "-")")
                decisionHandler(.cancel)
                DispatchQueue.main.async { [weak self] in
                    self?.webView.load(URLRequest(url: url))
                }
                return
            }
        }

        if isUserClick {
            // Direct clicks on account/login pages go to Safari. This avoids
            // turning the lightweight wrapper into a second identity browser.
            if TeamsPolicy.isInteractiveAuthURL(url) {
                openExternal(url)
                decisionHandler(.cancel)
                return
            }

            // User-clicked Microsoft content stays inside the wrapper.
            if TeamsPolicy.isInternalMicrosoftURL(url) || TeamsPolicy.isTrustedHTTPS(url) {
                decisionHandler(.allow)
                return
            }

            // Everything else (Jira, Confluence, TestRail, GitHub, etc.)
            // opens in the default browser.
            if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
                openExternal(url)
                decisionHandler(.cancel)
                return
            }
        }

        // Teams/auth service redirects that were not explicit link clicks must
        // remain inside, otherwise sign-in/session refresh can break.
        if TeamsPolicy.isTrustedHTTPS(url) {
            decisionHandler(.allow)
            return
        }

        // Non-user top-level external navigations are still sent to Safari.
        if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
            openExternal(url)
            decisionHandler(.cancel)
            return
        }

        if let scheme = url.scheme?.lowercased(), !["http", "https", "about", "blob", "data"].contains(scheme) {
            NSLog("[TL] non-web scheme: \(scheme)")
        }
        decisionHandler(.allow)
    }

    // Route target=_blank/window.open consistently with normal link clicks.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url else {
            return nil
        }

        NSLog("[TL] window.open host=\(url.host ?? "-")")

        // Teams' third-party cookie capability probe must not become a visible
        // browser tab or replace the main Teams page.
        if TeamsPolicy.isThirdPartyCookieProbe(url) {
            let probe = WKWebView(frame: .zero, configuration: configuration)
            probe.navigationDelegate = self
            probe.uiDelegate = self
            retainTransient(probe, timeout: 5)
            probe.load(URLRequest(url: url))
            return probe
        }

        // Microsoft destinations stay in the current lightweight window.
        // Explicit auth/account links still go to Safari.
        if TeamsPolicy.isInteractiveAuthURL(url) {
            openExternal(url)
            return nil
        }

        if TeamsPolicy.isInternalMicrosoftURL(url) || TeamsPolicy.isTrustedHTTPS(url) {
            self.webView.load(URLRequest(url: url))
            return nil
        }

        if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
            openExternal(url)
        }

        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView {
            NSLog("[TL] didFinish host=\(webView.url?.host ?? "-")")
        } else {
            releaseTransient(webView)
        }
    }

    // Процесс страницы может умереть (память, давление системы): без перезагрузки остаётся пустое окно.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("[TL] web content process terminated")
        if webView === self.webView {
            webView.reload()
        } else {
            releaseTransient(webView)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        NSLog("[TL] didFail code=\((error as NSError).code) domain=\((error as NSError).domain)")
        if webView !== self.webView {
            releaseTransient(webView)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        NSLog("[TL] didFailProvisional code=\((error as NSError).code) domain=\((error as NSError).domain)")
        if webView !== self.webView {
            releaseTransient(webView)
        }
    }

    // <input type=file> / «Upload from this device»: WKWebView на macOS сам диалог не показывает,
    // без этого делегата выбор файла молча считается отменой. Нужен entitlement
    // com.apple.security.files.user-selected.read-only (выбранные файлы читает песочница).
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        NSLog("[TL] openPanel multiple=\(parameters.allowsMultipleSelection) dirs=\(parameters.allowsDirectories)")
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            NSLog("[TL] openPanel result=\(response == .OK ? "ok" : "cancel") count=\(panel.urls.count)")
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    // Let macOS prompt for camera/microphone only for trusted Microsoft origins.
    @available(macOS 12.0, *)
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        if origin.protocol.lowercased() == "https",
           TeamsPolicy.isTrustedHost(origin.host) {
            decisionHandler(.prompt)
        } else {
            decisionHandler(.deny)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var teams: TeamsWebController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        teams = TeamsWebController()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Teams Lite"
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.center()
        window.contentView = teams.webView
        window.makeKeyAndOrderFront(nil)

        teams.notifications.onActivate = { [weak self] in self?.showWindow() }
        teams.notifications.windowIsFront = { [weak self] in
            guard let w = self?.window else { return false }
            return NSApp.isActive && w.isVisible && !w.isMiniaturized
        }

        if let hotkey = Config.toggleHotkey {
            HotkeyCenter.shared.register(
                keyCode: UInt32(hotkey.keyCode),
                modifiers: UInt32(hotkey.modifiers)
            ) { [weak self] in self?.toggleWindow() }
        }

        setupMuteHotkeys()

        teams.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    private var callHotkeyIDs: [UInt32] = []

    private func setupMuteHotkeys() {
        for hotkey in Config.muteHotkeys where !hotkey.onlyDuringCalls {
            HotkeyCenter.shared.register(
                keyCode: UInt32(hotkey.keyCode),
                modifiers: UInt32(hotkey.modifiers)
            ) { [weak self] in self?.teams.toggleMute() }
        }

        teams.onCallStateChange = { [weak self] inCall in
            guard let self else { return }
            NSLog("[TL] call state: \(inCall)")
            if inCall {
                guard self.callHotkeyIDs.isEmpty else { return }
                for hotkey in Config.muteHotkeys where hotkey.onlyDuringCalls {
                    let id = HotkeyCenter.shared.register(
                        keyCode: UInt32(hotkey.keyCode),
                        modifiers: UInt32(hotkey.modifiers)
                    ) { [weak self] in self?.teams.toggleMute() }
                    if let id { self.callHotkeyIDs.append(id) }
                }
            } else {
                self.callHotkeyIDs.forEach { HotkeyCenter.shared.unregister($0) }
                self.callHotkeyIDs.removeAll()
            }
        }
    }

    func showWindow() {
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleWindow() {
        if NSApp.isActive && window.isVisible && !window.isMiniaturized {
            NSApp.hide(nil)
        } else {
            showWindow()
        }
    }

    // Закрытие окна прячет его, чтобы приложение продолжало получать сообщения.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard Config.keepRunningInBackground else { return true }
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Config.keepRunningInBackground
    }

    // Клик по иконке в Dock возвращает спрятанное окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    @objc func reload(_ sender: Any?) {
        teams.webView.reload()
    }

    @objc func zoomIn(_ sender: Any?) {
        teams.webView.pageZoom = min(teams.webView.pageZoom + 0.1, 3.0)
    }

    @objc func zoomOut(_ sender: Any?) {
        teams.webView.pageZoom = max(teams.webView.pageZoom - 0.1, 0.5)
    }

    @objc func zoomReset(_ sender: Any?) {
        teams.webView.pageZoom = 1.0
    }
}

private func makeMainMenu(target: AppDelegate) -> NSMenu {
    let mainMenu = NSMenu()

    func add(
        _ menu: NSMenu,
        _ title: String,
        _ action: Selector?,
        _ key: String,
        _ mods: NSEvent.ModifierFlags = [.command],
        target t: AnyObject? = nil
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        if let t { item.target = t }
    }

    // App
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    add(appMenu, "Hide Teams Lite", #selector(NSApplication.hide(_:)), "h")
    add(appMenu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
    add(appMenu, "Show All", #selector(NSApplication.unhideAllApplications(_:)), "")
    appMenu.addItem(NSMenuItem.separator())
    add(appMenu, "Quit Teams Lite", #selector(NSApplication.terminate(_:)), "q")
    appMenuItem.submenu = appMenu

    // Edit (как в v3.8)
    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu

    // View
    let viewMenuItem = NSMenuItem()
    mainMenu.addItem(viewMenuItem)
    let viewMenu = NSMenu(title: "View")
    add(viewMenu, "Reload", #selector(AppDelegate.reload(_:)), "r", target: target)
    viewMenu.addItem(NSMenuItem.separator())
    add(viewMenu, "Actual Size", #selector(AppDelegate.zoomReset(_:)), "0", target: target)
    add(viewMenu, "Zoom In", #selector(AppDelegate.zoomIn(_:)), "=", target: target)
    add(viewMenu, "Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-", target: target)
    viewMenu.addItem(NSMenuItem.separator())
    add(viewMenu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
    viewMenuItem.submenu = viewMenu

    // Window
    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: "Window")
    add(windowMenu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(windowMenu, "Zoom", #selector(NSWindow.performZoom(_:)), "")
    add(windowMenu, "Close", #selector(NSWindow.performClose(_:)), "w")
    windowMenu.addItem(NSMenuItem.separator())
    add(windowMenu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
    windowMenuItem.submenu = windowMenu
    NSApplication.shared.windowsMenu = windowMenu

    return mainMenu
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = makeMainMenu(target: delegate)
app.run()
