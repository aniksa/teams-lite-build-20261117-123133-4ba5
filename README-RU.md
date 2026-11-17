# Teams Lite Native v3.10.3 Files — Universal2

База: v3.9 Notifications (уведомления, бейдж в Dock, работа в фоне, ⌃⌥⌘T, стандартные меню).

Что нового в v3.10:
- mute/unmute из любого приложения, как в Discord:
  - ` (физическая клавиша слева от 1; на русской раскладке это ё) без модификаторов,
    активна ТОЛЬКО пока страница держит микрофон (идёт звонок), иначе ` нельзя было бы набрать нигде;
  - запасной ⌃⌥M, работает всегда (на случай, если системе не нравится хоткей без модификаторов);
  - настраивается в Config.muteHotkeys, пустой массив отключает;
- UA берёт версию у установленного Safari (запасная Config.safariVersionFallback), а не зашитую 18.6;
- Web Inspector для WKWebView (Safari → Develop → Teams Lite), Config.inspectable.

Как работает mute: нативный хоткей вызывает window.__tlToggleMute() в странице Teams:
1) клик по кнопке микрофона (селекторы в NotificationShim), 2) запасной путь: встроенный шорткат Teams ⌘⇧M.
Результат пишется в системный лог: log stream --predicate 'process == "TeamsLite"' --info
  [TL] mute via: click:<селектор> | shortcut
  [TL] call state: true/false
  [TL] RegisterEventHotKey key=... status=0   (status != 0 — хоткей не зарегистрирован)

Окно по-прежнему одно; для mute никаких окон и HUD.

Инварианты НЕ изменены:
- bundle ID local.teamslite.native
- sandbox; entitlements: network client, camera, microphone + с v3.10.3 files.user-selected.read-only (выбор файла для аттача)
- configuration.websiteDataStore = .default()
- Teams Lite.app, CFBundleExecutable TeamsLite
- codesign с TeamsLite.entitlements, strip -x после lipo и до подписи
- внешние ссылки принудительно в Safari через /usr/bin/open -b com.apple.Safari

Ограничение: хоткеи Carbon перехватывают клавишу системно (в отличие от Discord, который слушает пассивно
и просит Input Monitoring). Пассивное прослушивание в sandbox потребует менять разрешения, поэтому не делалось.


## v3.10.1: исправление и диагностика (вечная загрузка после v3.10)

- Исправлен баг shim: подменённый navigator.permissions.query возвращал голый объект без addEventListener
  (настоящий PermissionStatus — EventTarget); теперь остаётся настоящий объект, подменяется только state.
- Если процесс страницы умер, она перезагружается (раньше оставалось пустое окно).
- Логи навигации (только схема и хост, без путей и параметров):
  log stream --predicate 'process == "TeamsLite"' --info
  [TL] nav scheme=... host=... click=...
  [TL] non-web scheme: msteams       <- так видно, кто запускает другое приложение
  [TL] openExternal host=...         <- открытие в Safari
  [TL] window.open host=...
  [TL] didFinish host=... | didFail code=... | didFailProvisional code=...
  [TL] web content process terminated
  [TL] user agent: ...

Переключатели без пересборки (приложение должно быть закрыто, ⌘Q):
  open -n -a "/Applications/MiTeams Lite.app" --args -TLNoShim YES   # без shim уведомлений
  open -n -a "/Applications/MiTeams Lite.app" --args -TLUA 18.6      # старый UA как в v3.8


## v3.10.2: зависание после логина (universal link уводит навигацию в другое приложение)

Причина по логу: после выбора аккаунта страница логина делает cross-site переход на teams.cloud.microsoft.
WebKit просит LaunchServices открыть его как universal link (_kLSOpenOptionRequiresUniversalLinksKey=1),
находится приложение, заявившее домен (Safari Web App «Teams (PWA)»), оно запускается, а навигация в Lite
обрывается (policyAction=2, didFailProvisional code=102) и окно остаётся на странице логина.
К UA, shim и версии сборки это не относится: воспроизводится и на августовской сборке.

Исправление: такой переход (https, GET, не клик пользователя, цель teams.cloud.microsoft / teams.microsoft.com,
текущая страница на другом хосте) отменяется и тут же выполняется программным load(): API-загрузки
WebKit app link не пробует. Не чаще раза в 10 секунд, чтобы не зациклиться. POST не трогается
(тело в WKNavigationAction недоступно); метод пишется в лог: method=...
Отключить исправление для проверки: open -n -a "<путь>/Teams Lite.app" --args -TLNoAppLinkFix YES

Лог только нужных строк (вместо тысяч системных):
  log show --last 5m --style compact --predicate 'process == "TeamsLite" AND (eventMessage CONTAINS "[TL]" OR eventMessage CONTAINS "UniversalLinks" OR eventMessage CONTAINS "LAUNCH:")' | pbcopy
  (то же в реальном времени: заменить `log show --last 5m` на `log stream`)
Ключевые строки:
  [TL] nav ... method=GET type=-1 from=login.microsoftonline.com
  [TL] reissue cross-site nav as programmatic load from=... to=teams.cloud.microsoft
  [TL] didFailProvisional code=102   <- исправление не сработало


## v3.10.3: не открывался выбор файла (аттач с локального диска)

Симптом: «Upload from this device» и перетаскивание файла в чат ничего не делали (аттач из облака работал).
Причины в коде:
1) WKWebView на macOS сам диалог выбора файла не показывает: нужен WKUIDelegate.runOpenPanelWith,
   его не было, и выбор молча считался отменой;
2) в песочнице не было entitlement com.apple.security.files.user-selected.read-only, без него выбранные/
   перетащенные файлы нельзя прочитать.
Исправление: добавлен runOpenPanelWith (NSOpenPanel, листом к окну; multiple/directories берутся из запроса страницы)
и entitlement read-only (ЭТО ЕДИНСТВЕННОЕ ИЗМЕНЕНИЕ ИНВАРИАНТА entitlements; write не нужен, сохранение не затрагивается).
Лог: [TL] openPanel multiple=... dirs=...  и  [TL] openPanel result=ok|cancel count=N
Если перетаскивание всё ещё не работает при рабочем диалоге, смотреть консоль инспектора на drop-событие.
