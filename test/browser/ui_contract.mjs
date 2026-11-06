// Dependency-free Chrome DevTools regression against a disposable test-only app.
// No user's Chrome profile, real provider, Keychain or private database is used.
import assert from "node:assert/strict"
import {spawn} from "node:child_process"
import {once} from "node:events"
import {chmod, mkdtemp, writeFile} from "node:fs/promises"
import {tmpdir} from "node:os"
import path from "node:path"

const [browser, root, origin, workspaceId, accountId, unattachedId, mode] = process.argv.slice(2)
// Keep disposable-fixture and bundled-public-artwork evidence outside the app root removed by the BEAM
// fixture. A fresh owner-only directory avoids overwriting any existing files.
const artifacts = await mkdtemp(path.join(tmpdir(), "lovelace-ui-artifacts-"))
await chmod(artifacts, 0o700)
assert.ok(path.relative(root, artifacts).startsWith(`..${path.sep}`), "screenshots survive disposable-root cleanup")
console.log(`UI screenshot directory (disposable fixtures and bundled artwork): ${artifacts}`)
const chrome = spawn(browser, [
  "--headless", "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
  `--user-data-dir=${path.join(root, "chrome")}`, "--no-first-run", "--no-default-browser-check",
  "--disable-background-networking", "--disable-component-update", "--disable-sync",
  "about:blank",
], {stdio: ["ignore", "ignore", "pipe"]})

// Capture closure now: waiting on a new exit listener in finally can hang if
// Chrome was already terminated by a signal (exitCode stays null in that case).
const chromeClosed = new Promise(resolve => chrome.once("close", resolve))
let socket
let nextId = 0
let sessionId
let failStageImages = false
const pending = new Map()
const errors = []
const cspViolations = []
const external = []
const attachmentRequests = []
const youtubeRequests = []
let allowYouTubeFixture = false
const deadline = setTimeout(() => {
  console.error("UI browser suite exceeded its 120-second deadline")
  chrome.kill("SIGKILL")
  process.exit(1)
}, 120_000)

function send(method, params = {}, session = sessionId) {
  const id = ++nextId
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(id)
      reject(new Error(`DevTools timeout: ${method}`))
    }, 10_000)
    pending.set(id, {resolve, reject, timer})
    socket.send(JSON.stringify({id, method, params, ...(session ? {sessionId: session} : {})}))
  })
}

async function evaluate(expression, session = sessionId) {
  const response = await send("Runtime.evaluate", {expression, returnByValue: true, awaitPromise: true}, session)
  assert.equal(response.exceptionDetails, undefined, "browser evaluation must not throw")
  return response.result.value
}

async function waitFor(expression, label, timeout = 8_000, session = sessionId) {
  const end = Date.now() + timeout
  while (Date.now() < end) {
    if (await evaluate(expression, session)) return
    await new Promise(resolve => setTimeout(resolve, 25))
  }
  throw new Error(`Timed out: ${label}`)
}

async function click(selector) {
  const {scrollTop, ...point} = await evaluate(`(() => {
    const element = document.querySelector(${JSON.stringify(selector)});
    if (!element) throw new Error('Missing click target');
    element.scrollIntoView({block: 'center'});
    const rect = element.getBoundingClientRect();
    const x = rect.x + rect.width / 2, y = rect.y + rect.height / 2;
    const hit = document.elementFromPoint(x, y);
    if (element.id === 'home-link' && !element.contains(hit)) throw new Error('Home click intercepted by ' + hit?.tagName + '#' + hit?.id);
    return {x, y, scrollTop: document.querySelector('#workspace-content')?.scrollTop};
  })()`)
  await send("Input.dispatchMouseEvent", {type: "mousePressed", button: "left", clickCount: 1, ...point})
  await send("Input.dispatchMouseEvent", {type: "mouseReleased", button: "left", clickCount: 1, ...point})
  // Return the actual pre-click position, after scrollIntoView, just as MailReader captures it.
  return scrollTop
}

async function key(key, text, modifiers = 0) {
  const enter = key === "Enter" ? {code: "Enter", windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13, text: "\r", unmodifiedText: "\r"} : {}
  await send("Input.dispatchKeyEvent", {type: "keyDown", key, modifiers, ...enter, ...(text ? {text} : {})})
  await send("Input.dispatchKeyEvent", {type: "keyUp", key, modifiers, ...enter})
}

async function media(features = []) {
  await send("Emulation.setEmulatedMedia", {features})
}

async function screenshot(name) {
  assert.deepEqual(await evaluate(`(() => {
    const glass = getComputedStyle(document.querySelector('.workspace-glass'), '::after');
    return [glass.borderTopWidth, glass.borderRightWidth, glass.borderBottomWidth, glass.borderLeftWidth];
  })()`), ['0px', '0px', '0px', '0px'], 'shared static/live stage stays borderless, including forced colors')
  await evaluate("document.fonts.ready.then(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve(true)))))")
  const {data} = await send("Page.captureScreenshot", {format: "png", fromSurface: true, captureBeyondViewport: false})
  const file = path.join(artifacts, `${name}.png`)
  await writeFile(file, Buffer.from(data, "base64"), {flag: "wx", mode: 0o600})
  console.log(`UI screenshot: ${file}`)
}

async function bundledBackground(selector) {
  await waitFor(`document.querySelector(${JSON.stringify(selector)}) && getComputedStyle(document.querySelector(${JSON.stringify(selector)})).backgroundImage.includes('/images/scenes/')`, 'styled bundled background')
  const background = await evaluate(`getComputedStyle(document.querySelector(${JSON.stringify(selector)})).backgroundImage`)
  assert.match(background, /\/images\/scenes\/[0-9a-f]{64}\.jpg/, 'bundled JPEG replaces the original SVG')
  const url = background.match(/^url\("(.+)"\)$/)?.[1]
  assert.ok(url?.startsWith(`${origin}/images/scenes/`), 'bundled imagery is same-origin')
  assert.equal(await evaluate(`(async () => {
    const image = new Image(); image.src = ${JSON.stringify(url)};
    await image.decode(); return image.naturalWidth > 0 && image.naturalHeight > 0;
  })()`), true, 'the actual bundled default decodes in Chrome')
  return background
}

async function verifyEmptyInstallation() {
  const initial = await bundledBackground('#owner-stage-background')
  assert.equal(await evaluate("!!document.querySelector('#owner-stage-background img')"), false, 'no generated image exists')
  await screenshot('bundled-default-unlock')
  await send('Page.reload')
  await waitFor("!!document.querySelector('#owner-unlock-form')", 'unlock after reload')
  assert.equal(await bundledBackground('#owner-stage-background'), initial)
  await send('Emulation.setScriptExecutionDisabled', {value: true})
  await send('Page.reload')
  await waitFor("!!document.querySelector('#owner-unlock-form')", 'unlock without JavaScript')
  assert.equal(await bundledBackground('#owner-stage-background'), initial, 'default imagery works without JavaScript')
  await send('Emulation.setScriptExecutionDisabled', {value: false})
  await send('Page.reload')
  await waitFor("!!document.querySelector('#owner-unlock-form')", 'unlock before login')
  await evaluate(`document.querySelector('#owner-unlock-form input[type=password]').value = 'synthetic browser owner password'; document.querySelector('#owner-unlock-form').requestSubmit()`)
  await waitFor("!!document.querySelector('#home-overview') && window.liveSocket?.getSocket().isConnected()", 'empty installation Home')
  await media([{name: 'prefers-reduced-motion', value: 'reduce'}])
  await click('#workspace-pane')
  await focused()
  assert.equal(await bundledBackground('#workspace-background'), initial, 'static and live default choices agree')
  assert.equal(await evaluate("!!document.querySelector('#workspace-background img')"), false)
  await screenshot('home-empty-desktop')
  await click('#calendar-agenda .calendar-empty a')
  await waitFor("!!document.querySelector('#calendar-connections') && document.querySelector('#connections-calendar')?.getAttribute('aria-current') === 'page'", 'Calendar setup goes directly to its Connections provider')
  await click('#home-link')
  await waitFor("!!document.querySelector('#home-readouts')", 'empty Home after Calendar setup')
  await send('Emulation.setDeviceMetricsOverride', {width: 390, height: 844, deviceScaleFactor: 1, mobile: false})
  assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth && document.querySelector('#home-readouts').scrollWidth <= document.querySelector('#home-readouts').clientWidth"), true, 'empty Home has no narrow overflow')
  await screenshot('home-empty-narrow')
  await send('Emulation.setDeviceMetricsOverride', {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false})
  await key('Escape')
  await landscape()
  await screenshot('bundled-default-scenery')
  await key('a', 'a')
  await focused()
  await click('#show-scenes')
  await waitFor("!!document.querySelector('#scene-gemini-setup') && document.querySelector('#scenes-panel')?.getAttribute('aria-busy') === 'false'", 'unconfigured Scenes shows Gemini setup')
  assert.equal(await evaluate("!!document.querySelector('#scene-direction-form, .scene-toolbar, #scene-generation-settings, #scenes-empty, #scene-gallery, #scene-attempt-history, #scene-generation-modal')"), false, 'unconfigured Scenes mounts only its setup card')
  assert.equal(await evaluate("document.querySelector('#scene-gemini-setup a').getAttribute('href')"), '/connections/gemini', 'setup opens the Gemini provider')
  assert.equal(await bundledBackground('#workspace-background'), initial)
  await screenshot('bundled-default-empty-scenes')
  await click('#home-link')
  await waitFor("location.pathname === '/' && !!document.querySelector('#home-overview')", 'Home navigation before reload')
  await send('Page.reload')
  await waitFor("!!document.querySelector('#home-overview') && window.liveSocket?.getSocket().isConnected()", 'empty Home reload')
  assert.equal(await bundledBackground('#workspace-background'), initial, 'reload retains the installation default')
  assert.equal(await evaluate("document.querySelector('#workspace-content').inert"), true, 'ordinary reload keeps the entrance gate')
  await media([])
  await send('Page.navigate', {url: origin + '/auth/github/callback'})
  await waitFor("location.pathname === '/connections/github' && !!document.querySelector('#github-connections') && window.liveSocket?.getSocket().isConnected()", 'local OAuth error returns to its provider without a provider request')
  await focused()
  await screenshot('unlocked-oauth-return')
  await key('Escape')
  await landscape()
  await key('a', 'a')
  await focused()
  await send('Page.reload')
  await waitFor("!!document.querySelector('#github-connections') && window.liveSocket?.getSocket().isConnected()", 'provider reload after return')
  assert.equal(await evaluate("document.querySelector('#workspace-content').inert"), true, 'return activation is consumed, not persisted across reloads')
  assert.deepEqual(cspViolations, [])
  assert.deepEqual(errors, [])
  assert.deepEqual(external, [])
  console.log('PASS bundled default without generated scenes: static/no-JS/live, image decoding, empty gallery and stable reload/navigation/wake')
}

async function verifyYouTube() {
  await media([{name: 'prefers-reduced-motion', value: 'reduce'}])
  await send('Page.navigate', {url: origin + '/connections/youtube'})
  const consentReady = `!!document.querySelector('#youtube-authorize-${unattachedId} button:not([disabled])') &&
    !!document.querySelector('#youtube-authorize-${unattachedId} select:not([disabled])')`
  await waitFor(consentReady, 'direct YouTube connection observes stored Google client settings')
  assert.equal(await evaluate("!!document.querySelector('#youtube-connections > .calendar-warning')"), false)
  await click('#workspace-pane')
  await focused()
  await screenshot('youtube-connections-ready')
  await click('#connections-gmail')
  await waitFor("!!document.querySelector('#gmail-connections-heading')", 'Gmail connection navigation')
  await click('#connections-youtube')
  await waitFor(consentReady, 'YouTube navigation continues the shared Google diagnostic')
  assert.equal(await evaluate("!!document.querySelector('#youtube-connections > .calendar-warning')"), false)
  console.log('PASS YouTube consent enables after stored-settings diagnostics on direct entry and provider navigation')
  await click(`#youtube-nav-${accountId}`)
  await waitFor("!!document.querySelector('#youtube-videos a')", 'account YouTube uploads')
  assert.equal(await evaluate("!!document.querySelector('#youtube-feed iframe, #youtube-feed img')"), false)
  assert.equal(youtubeRequests.length, 0, 'opening the feed never contacts YouTube')
  const priorRead = await evaluate("document.querySelector('#youtube-feed-status time').dateTime")
  await click('#youtube-refresh')
  await waitFor(`!!document.querySelector('#youtube-feed-status time') && document.querySelector('#youtube-feed-status time').dateTime !== ${JSON.stringify(priorRead)} && !document.querySelector('#youtube-feed-status').textContent.includes('Updating')`, 'browser Refresh publishes a new observation through Oban')
  await screenshot('youtube-feed-desktop')
  await click('#youtube-videos a')
  await waitFor("!!document.querySelector('#youtube-player-load')", 'selected feed video deep link')
  const watchPath = await evaluate('location.pathname')
  assert.equal(await evaluate("!!document.querySelector('iframe')"), false, 'watch route is click-to-load')
  allowYouTubeFixture = true
  await click('#youtube-player-load')
  await waitFor("!!document.querySelector('#youtube-player iframe')", 'fresh click creates player')
  await waitFor("document.querySelector('#youtube-player iframe')?.contentWindow != null", 'iframe browsing context')
  assert.deepEqual(await evaluate(`(() => {
    const frame = document.querySelector('#youtube-player iframe');
    return {src:frame.getAttribute('src'), referrer:frame.referrerPolicy};
  })()`), {src:'https://www.youtube-nocookie.com/embed/aaaaaaaaaaa?autoplay=0&rel=0', referrer:'strict-origin-when-cross-origin'})
  await screenshot('youtube-click-loaded-player')
  // Browser-owned input inside a cross-origin iframe never bubbles to LOVELACE.
  // Keep scenery focused while it owns input, then verify native Tab exits safely.
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '0.02'")
  await click('#youtube-player iframe')
  await waitFor("document.activeElement.tagName === 'IFRAME'", 'cross-origin player focus')
  await key('Escape')
  await new Promise(resolve => setTimeout(resolve, 1400))
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), 'true', 'visible player focus suspends visual idle')
  assert.equal(await evaluate("!!document.querySelector('iframe')"), true, 'player keeps its own Escape handling')
  await key('Tab')
  await waitFor("document.activeElement.matches('[data-youtube-unload]')", 'Tab exits player to Unload')
  await landscape()
  assert.equal(await evaluate("!!document.querySelector('iframe')"), false, 'ordinary idle resumes after leaving the player')
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '3'")
  await key('a', 'a')
  await focused()
  await click('#youtube-player-load')
  await waitFor("!!document.querySelector('#youtube-player iframe')", 'player before parent Escape')
  await key('Escape')
  await landscape()
  assert.equal(await evaluate("!!document.querySelector('iframe')"), false, 'Escape unloads before scenery')
  await key('a', 'a')
  await focused()
  await click('#youtube-player-load')
  await waitFor("!!document.querySelector('#youtube-player iframe')", 'explicit reload player')
  await send('Page.reload')
  await waitFor("!!document.querySelector('#youtube-player-load') && window.liveSocket?.getSocket().isConnected()", 'watch deep link reload')
  await click('#workspace-pane')
  await focused()
  assert.equal(await evaluate('location.pathname'), watchPath)
  assert.equal(await evaluate("!!document.querySelector('iframe')"), false, 'reload never reuses player consent')
  await click('#youtube-watch a')
  await waitFor("!!document.querySelector('#youtube-videos a')", 'back to uploads')
  await evaluate('history.back()')
  await waitFor("!!document.querySelector('#youtube-player-load')", 'browser Back restores watch destination')
  assert.equal(await evaluate("!!document.querySelector('iframe')"), false, 'Back needs a fresh click')
  if (await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed') !== 'true'")) await key('a', 'a')
  await focused()
  await click('#youtube-player-load')
  await waitFor("!!document.querySelector('#youtube-player iframe')", 'player before account leave')
  await click('#home-link')
  await home()
  assert.equal(await evaluate("!!document.querySelector('iframe')"), false, 'leaving account removes player')
  allowYouTubeFixture = false
  assert.ok(youtubeRequests.length >= 1, 'synthetic official embed was intercepted, never fetched')
  await media([])
}

async function verifyGitHubDiscovery() {
  await send('Page.navigate', {url: origin + '/connections/github'})
  await waitFor("!!document.querySelector('[id^=github-discover-] button') && window.liveSocket?.getSocket().isConnected()", 'GitHub account access controls')
  await click('#workspace-pane')
  await focused()
  const connectionId = await evaluate("document.querySelector('[id^=github-discover-] input[name=connection_id]').value")
  await click(`#github-discover-${connectionId} button`)
  await waitFor(`location.pathname === '/connections/github' &&
    ['pending', 'running'].includes(document.querySelector('#github-discovery-status-${connectionId}')?.dataset.state)`, 'durable account discovery accepted before provider completion')
  const operation = await evaluate(`(() => {
    const status = document.querySelector('#github-discovery-status-${connectionId}');
    return {id: status.dataset.operationId, job: status.dataset.jobId};
  })()`)
  assert.match(operation.id, /^[0-9a-f-]{36}$/)
  assert.match(operation.job, /^[1-9][0-9]*$/)
  await send('Page.reload')
  await waitFor(`document.querySelector('#github-discovery-status-${connectionId}')?.dataset.operationId === '${operation.id}' &&
    window.liveSocket?.getSocket().isConnected()`, 'discovery remains observable after request and view exit')
  await waitFor(`document.querySelector('#github-discovery-status-${connectionId}')?.dataset.state === 'succeeded'`, 'durable discovery publishes successful account access')
  assert.equal(await evaluate(`document.querySelector('#github-discovery-status-${connectionId}').dataset.jobId`), operation.job)
  assert.match(await evaluate(`document.querySelector('#github-discovery-status-${connectionId}').textContent`), /Account access refreshed/)
  await click('#workspace-pane')
  await focused()
  await evaluate(`document.querySelectorAll('#github-connections button[phx-click="github:refresh"]').forEach(button => button.click())`)
  await click('#home-link')
  await home()
  await waitFor("Array.from(document.querySelectorAll('#github-readouts .github-home-metric:first-child .github-home-total')).length === 2 && Array.from(document.querySelectorAll('#github-readouts .github-home-metric:first-child .github-home-total')).every(count => count.textContent.trim() === '1')", 'synthetic owner snapshots repopulate through the protected GitHub queue', 16_000)
  console.log('PASS durable GitHub discovery: accepted job correlation, browser reload and eventual fenced success')
}

async function verifyAccountSwitchFencing() {
  await click('#home-link')
  await home()
  await evaluate('window.accountSwitchSocket = window.liveSocket; true')
  for (const [id, thread] of [[accountId, 13], [unattachedId, 14]]) {
    await click(`#open-home-account-${id}`)
    await waitFor("document.querySelector('#home-inbox #mail-threads')?.getAttribute('aria-busy') === 'false'", 'account inbox before delayed reader switch')
    await click(`#mail-thread-synthetic-thread-${thread}`)
    await waitFor("!!document.querySelector('#mail-loading')", 'provider read is pending before switching account')
    await click('#home-link')
    await home()
  }
  await click(`#open-home-account-${accountId}`)
  await waitFor("document.querySelector('#home-inbox #mail-threads')?.getAttribute('aria-busy') === 'false'", 'A returns after A to B to A')
  assert.equal(await evaluate("document.querySelector('#mail-heading').textContent.trim()"), 'browser@example.test')
  await click('#mail-thread-synthetic-thread-15')
  await readerLoaded()
  assert.equal(await evaluate("document.querySelector('#mail-conversation-heading').textContent.trim()"), 'Synthetic conversation 15')
  assert.equal(await evaluate("window.accountSwitchSocket === window.liveSocket"), true, 'switches preserve the live stage rather than replacing the page')
  assert.equal(await evaluate("document.querySelector('#mail-panel').textContent.includes('Synthetic conversation 14') || document.querySelector('#mail-panel').textContent.includes('Synthetic conversation 13')"), false, 'obsolete A and B readers cannot replace the current result')
  console.log('PASS A to B to A during delayed reads: same LiveSocket, current account and no obsolete conversation publication')
}

async function scenesLoaded(count = 20, active = 1) {
  await waitFor(`document.querySelector('#scenes-panel')?.getAttribute('aria-busy') === 'false' &&
    document.title === 'Scenes · LOVELACE' &&
    document.querySelector('#directory-heading')?.textContent.trim() === 'Scenes' &&
    document.querySelectorAll('#scene-gallery > li.scene-card').length === ${count} &&
    document.querySelectorAll('#scene-gallery > .scene-card[data-active=true]').length === ${active} &&
    Array.from(document.querySelectorAll('#scene-gallery img')).length === ${count} &&
    Array.from(document.querySelectorAll('#scene-gallery img')).every(image => image.dataset.loaded === 'true' && image.naturalWidth > 0)`, `${count} loaded synthetic scene thumbnails with ${active} active on this page`)
  assert.equal(await evaluate("document.querySelector('#directory-heading').textContent.trim()"), "Scenes")
  assert.equal(await evaluate("document.title"), "Scenes · LOVELACE")
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('#center-nav [aria-current=page]'), button => button.id)"), ["show-scenes"])
  assert.equal(await evaluate("!!document.querySelector('#home-overview, #home-inbox, #workspace-list, #workspace-landing, #connections-panel, #gemini-connection, #mail-panel')"), false, "Scenes is an exclusive view, not an overlay on mail or Connections")
  assert.equal(await evaluate("document.querySelectorAll('#scene-gallery > .scene-card[data-active=true]').length"), active)
  assert.equal(await evaluate("/Generation is available|Recent scenery is ready/.test(document.querySelector('#scenes-panel .scene-status').textContent)"), false, 'status omits redundant generation availability and ready copy')
}

async function guidedSceneDirection() {
  await waitFor("!!document.querySelector('#scene-direction-form')", "guided direction loads")
  const before = await sceneManifest()
  const originalPrompt = await evaluate("document.querySelector('#scene-direction-prompt').textContent")
  await click('#scene-prompt-preview summary')
  assert.equal(await evaluate("document.querySelector('#scene-prompt-preview').open"), true)
  await evaluate(`(() => {
    const field = document.querySelector('#scene-direction-subject');
    field.focus();
    field.value = 'landscape';
    field.dispatchEvent(new Event('change', {bubbles: true}));
  })()`)
  await waitFor("!!document.querySelector('#scene-direction-discard') && document.querySelector('#scene-generate').disabled", "draft requires explicit save")
  assert.notEqual(await evaluate("document.querySelector('#scene-direction-prompt').textContent"), originalPrompt)
  assert.equal(await evaluate("document.querySelector('#scene-prompt-preview').open"), true, "live preview preserves expanded disclosure")
  await evaluate(`(() => {
    window.uiSceneRefreshNodes = {
      form: document.querySelector('#scene-direction-form'),
      prompt: document.querySelector('#scene-prompt-preview'),
      refresh: document.querySelector('#scenes-refresh')
    };
  })()`)
  await refreshScenes()
  assert.equal(await evaluate("document.querySelector('#scene-direction-subject').value"), 'landscape', "status refresh preserves unsaved direction")
  assert.equal(await evaluate("document.querySelector('#scene-prompt-preview').open"), true, "credential revalidation preserves the native expanded prompt disclosure")
  assert.equal(await evaluate("document.activeElement.id"), 'scenes-refresh', "status refresh keeps focus on its trigger")
  assert.equal(await evaluate(`Object.entries(window.uiSceneRefreshNodes).every(([key, node]) =>
    node === document.querySelector({form: '#scene-direction-form', prompt: '#scene-prompt-preview', refresh: '#scenes-refresh'}[key]))`), true, "successful credential revalidation never remounts the direction editor or Refresh trigger")
  await evaluate("delete window.uiSceneRefreshNodes")
  await key('Escape')
  await landscape()
  await key('a', 'a')
  await focused()
  assert.equal(await evaluate("document.querySelector('#scene-direction-subject').value"), 'landscape', "scenery wake preserves unsaved direction")
  await click('#scene-direction-discard')
  await waitFor("!document.querySelector('#scene-direction-discard') && !document.querySelector('#scene-generate').disabled", "discard restores active prompt")
  assert.equal(await evaluate("document.querySelector('#scene-direction-prompt').textContent"), originalPrompt)
  await evaluate(`(() => {
    const choices = {subject: 'landscape', setting: 'coast', light: 'dawn', palette: 'sea_glass'};
    for (const [key, value] of Object.entries(choices)) document.querySelector('#scene-direction-' + key).value = value;
    document.querySelector('#scene-direction-palette').dispatchEvent(new Event('change', {bubbles: true}));
  })()`)
  await waitFor("!!document.querySelector('#scene-direction-discard')", "new guided choices update preview")
  const prompt = await evaluate("document.querySelector('#scene-direction-prompt').textContent")
  await evaluate("document.querySelector('#scene-direction-save').focus()")
  await key('Enter')
  await waitFor("!!document.querySelector('#scene-direction-notice') && document.querySelector('#scene-direction-save').disabled && !document.querySelector('#scene-generate').disabled", "keyboard save completes without generating")
  assert.deepEqual(await sceneManifest(), before, "editing and saving never reserves or changes the background")
  await screenshot('scene-direction-desktop')
  await evaluate(`(() => {
    const choices = {model: 'gemini-3-pro-image', aspect_ratio: '4:3', image_size: '2K'};
    for (const [key, value] of Object.entries(choices)) document.querySelector('#scene-generation-' + key).value = value;
    document.querySelector('#scene-generation-image_size').dispatchEvent(new Event('change', {bubbles: true}));
  })()`)
  await click('#scene-generate')
  await sceneModal()
  const confirmedSettings = await evaluate("document.querySelector('#scene-confirmation-settings').textContent")
  assert.match(confirmedSettings, /gemini-3-pro-image/)
  assert.match(confirmedSettings, /4:3/)
  assert.match(confirmedSettings, /2K/)
  assert.match(await evaluate("document.querySelector('#scene-generation-modal').textContent"), /store=true/)
  assert.match(await evaluate("document.querySelector('#scene-generation-modal').textContent"), /deletion/)
  assert.equal(await evaluate("document.querySelector('#scene-confirmation-prompt p').textContent"), prompt, "cost confirmation pins exact previewed prompt")
  await key('Escape')
  await waitFor("!document.querySelector('#scene-generation-modal')", "cancel stays free")
  await click('#scene-prompt-preview summary')
  await evaluate("document.querySelector('#workspace-content').scrollTop = 0")
  return prompt
}

async function sceneManifest() {
  return evaluate(`({
    attempts: Array.from(document.querySelectorAll('#scenes-panel .scene-toolbar > .scene-status time'), time => time.dateTime),
    scenes: Array.from(document.querySelectorAll('#scene-gallery > .scene-card'), card => ({
      id: card.id, active: card.dataset.active, generatedAt: card.querySelector('time')?.dateTime,
      src: card.querySelector('img').getAttribute('src')
    }))
  })`)
}

async function refreshScenes() {
  // Require the real async status round trip, not a pre-response DOM snapshot.
  await evaluate(`(() => {
    window.uiScenesRefreshed = false;
    const observer = new MutationObserver(records => {
      if (records.some(record => record.attributeName === 'aria-busy' && record.oldValue === 'true') &&
          document.querySelector('#scenes-panel')?.getAttribute('aria-busy') === 'false') {
        window.uiScenesRefreshed = true;
        observer.disconnect();
      }
    });
    observer.observe(document.querySelector('#scenes-panel'), {attributes: true, attributeOldValue: true, attributeFilter: ['aria-busy']});
  })()`)
  await click("#scenes-refresh")
  await waitFor("window.uiScenesRefreshed", "read-only scene status refresh completes")
  await scenesLoaded()
}

async function sceneModal() {
  await waitFor("document.querySelector('#scene-generation-modal')?.matches(':modal') && document.activeElement.id === 'scene-generation-cancel'", "native scene confirmation defaults to safe Cancel")
  assert.equal(await evaluate("document.querySelector('#scene-generation-modal').getAttribute('aria-labelledby')"), "scene-generation-modal-title")
  assert.match(await evaluate("document.querySelector('#scene-generation-modal').textContent"), /may incur.*charges/i)
  assert.equal(await evaluate("document.querySelector('#scene-generation-confirm').disabled"), false)
}

async function scenesLayout(width, forced) {
  const layout = await evaluate(`(() => {
    const panel = document.querySelector('#scenes-panel');
    const gallery = document.querySelector('#scene-gallery');
    const pane = document.querySelector('#workspace-content');
    const buttons = Array.from(panel.querySelectorAll('button'), button => button.getBoundingClientRect());
    const nav = Array.from(document.querySelectorAll('#center-nav > a'), link => link.getBoundingClientRect());
    return {pageOverflow: document.documentElement.scrollWidth > innerWidth,
      paneOverflow: pane.scrollWidth > pane.clientWidth + 1,
      panelOverflow: panel.scrollWidth > panel.clientWidth + 1,
      galleryOverflow: gallery.scrollWidth > gallery.clientWidth + 1,
      statusCard: (() => {
        const status = panel.querySelector('.scene-status.connection-card');
        const style = status && getComputedStyle(status);
        return !!status && style.borderTopStyle === 'solid' && parseFloat(style.borderTopWidth) >= 1 &&
          parseFloat(style.paddingTop) >= 20 && status.getBoundingClientRect().width <= panel.clientWidth;
      })(),
      statusPlacement: (() => {
        const status = panel.querySelector('.scene-toolbar > .scene-status').getBoundingClientRect();
        const actions = panel.querySelector('.scene-toolbar > .mail-actions').getBoundingClientRect();
        return {sameRow: Math.abs(status.top - actions.top) <= 1 && status.right <= actions.left,
          stacked: status.bottom <= actions.top};
      })(),
      columns: getComputedStyle(gallery).gridTemplateColumns.split(' ').length,
      disabledCursors: Array.from(panel.querySelectorAll('button:disabled'), button => getComputedStyle(button).cursor),
      usable: buttons.every(rect => rect.height >= 44 && rect.width >= 44 && rect.left >= 0 && rect.right <= innerWidth),
      navFits: nav.every(rect => rect.left >= 0 && rect.right <= innerWidth && rect.height >= 44),
      forced: matchMedia('(forced-colors: active)').matches};
  })()`)
  assert.equal(layout.pageOverflow || layout.paneOverflow || layout.panelOverflow || layout.galleryOverflow, false,
    `Scenes has no horizontal overflow at ${width}px (forced colors: ${forced}): ${JSON.stringify(layout)}`)
  assert.equal(layout.statusCard, true, 'generation status is contained in a padded Gemini-style card')
  assert.equal(width > 640 ? layout.statusPlacement.sameRow : layout.statusPlacement.stacked, true,
    'status sits beside the action buttons on desktop and stacks above them on narrow screens')
  assert.equal(await evaluate("document.querySelector('#scenes-panel').textContent.includes('App-wide scenery · All saved scenes')"), false, 'redundant subheading is removed')
  assert.equal(layout.columns, width <= 640 ? 1 : 2)
  assert.ok(layout.disabledCursors.every(cursor => cursor === 'default'), 'disabled controls never imply work with a waiting/spinner cursor')
  assert.equal(layout.usable && layout.navFits, true, "scene and navigation controls remain usable within the viewport")
  assert.equal(layout.forced, forced)
}

async function focused() {
  await waitFor(`document.querySelector('#main-content')?.dataset.entered === 'true' &&
    getComputedStyle(document.querySelector('#owner-lock-form')).visibility === 'visible'`, "entered focused workspace")
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#workspace-pane')).display`), "none")
  assert.equal(await evaluate(`document.querySelector('#workspace-content').inert`), false)
  assert.equal(await evaluate(`document.querySelector('#workspace-controls').inert`), false)
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#home-link')).visibility`), "visible")
}

async function landscape() {
  await waitFor(`document.querySelector('#workspace-pane')?.getAttribute('aria-pressed') === 'false'`, "landscape mode")
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#owner-lock-form')).visibility`), "hidden")
  assert.equal(await evaluate(`(() => {
    const button = document.querySelector('#owner-lock-form button');
    button.focus({preventScroll: true});
    return document.activeElement === button;
  })()`), false, "hidden Lock must not accept keyboard focus")
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#home-link')).visibility`), "hidden")
  assert.equal(await evaluate(`(() => {
    const button = document.querySelector('#home-link');
    button.focus({preventScroll: true});
    return document.activeElement === button;
  })()`), false, "hidden Home must not accept keyboard focus")
}

async function readerLoaded() {
  await waitFor(`document.querySelector('#mail-conversation')?.getAttribute('aria-busy') === 'false' &&
    document.querySelector('#mail-panel')?.dataset.mailLoaded === 'true' &&
    !!document.querySelector('#mail-message-synthetic-message-3 .mail-message-text')`, "loaded conversation")
  // Let the reader's scheduled focus/scroll handoff settle before measuring or
  // calculating click coordinates for another control.
  await evaluate("new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve(true))))")
  assert.equal(await evaluate("!!document.querySelector('#mail-threads')"), false, "reader replaces the results, not an inline expansion")
}

async function loadingStatus(forced, reduced) {
  await waitFor("!!document.querySelector('#mail-loading')", "real mail loading status")
  const state = await evaluate(`(() => {
    const status = document.querySelector('#mail-status');
    const loading = document.querySelector('#mail-loading');
    const track = loading.querySelector('.status-orbit');
    return {background: getComputedStyle(status).backgroundColor,
      loadingBackground: getComputedStyle(loading).backgroundColor,
      edge: getComputedStyle(status).borderLeftWidth,
      animation: getComputedStyle(track).animationName,
      hidden: track.closest('svg').getAttribute('aria-hidden'), role: status.getAttribute('role'),
      height: status.getBoundingClientRect().height};
  })()`)
  assert.equal(state.background, "rgba(0, 0, 0, 0)", "loading sits directly on the shared glass")
  assert.equal(state.loadingBackground, "rgba(0, 0, 0, 0)")
  assert.equal(state.edge, "0px", "loading does not borrow the warning edge")
  assert.equal(state.animation, forced || reduced ? "none" : "status-orbit", "motion respects user preferences and forced colors")
  assert.equal(state.hidden, "true", "the indeterminate SVG is decorative, not fake percentage progress")
  assert.equal(state.role, "status")
  assert.ok(state.height >= 28)
  return state.height
}

async function pinnedControls(width, forced) {
  const originalScroll = await evaluate("document.querySelector('#workspace-content').scrollTop")
  await evaluate("document.querySelector('#workspace-content').scrollTop = 0")
  const bounds = `(() => {
    const lock = document.querySelector('#owner-lock-form button').getBoundingClientRect();
    const legend = document.querySelector('.workspace-footer').getBoundingClientRect();
    const nav = document.querySelector('#center-nav').getBoundingClientRect();
    const port = document.querySelector('#workspace-content').getBoundingClientRect();
    const working = document.querySelector('.workspace-directory').getBoundingClientRect();
    return {lock: {x: lock.x, y: lock.y}, legend: {x: legend.x, y: legend.y}, nav: nav.y,
      scroll: document.querySelector('#workspace-content').scrollTop,
      visible: lock.top >= 0 && lock.bottom <= innerHeight && legend.top >= 0 && legend.bottom <= innerHeight,
      clear: (port.top >= lock.bottom || working.right <= lock.left) && (port.bottom <= legend.top || working.right <= legend.left),
      hit: !!document.elementFromPoint(lock.x + lock.width / 2, lock.y + lock.height / 2)?.closest('#owner-lock-form')};
  })()`
  const before = await evaluate(bounds)
  await send('Input.dispatchMouseEvent', {type: 'mouseWheel', x: width / 2, y: 500, deltaX: 0, deltaY: 500})
  await waitFor("document.querySelector('#workspace-content').scrollTop > 20", 'real wheel scrolls only the working content')
  const after = await evaluate(bounds)
  assert.deepEqual(after.lock, before.lock, 'Lock stays pinned while the page scrolls')
  assert.deepEqual(after.legend, before.legend, 'Escape legend stays pinned while the page scrolls')
  assert.ok(after.nav < before.nav - 20, 'main navigation scrolls normally, not with the right rail')
  assert.equal(after.visible && after.hit, true, 'pinned Lock stays visible and is not intercepted')
  assert.equal(after.clear, true, 'pinned controls do not cover scrolling working content')
  assert.equal(await evaluate("document.scrollingElement.scrollTop"), 0, 'the outer stage never scrolls')
  await screenshot(`pinned-controls-${width}${forced ? '-forced-colors' : ''}`)
  await evaluate(`document.querySelector('#workspace-content').scrollTop = ${originalScroll}`)
}

async function statusDetails(width, forced, embedded = false) {
  const selector = embedded ? '#workspace-list .status-signal[data-embedded=true]' : '.gmail-connection-card .status-signal:not(.status-signal-text)';
  const trigger = embedded ? `document.querySelector(${JSON.stringify(selector)}).closest('a')` : `document.querySelector(${JSON.stringify(selector)})`
  await key('Tab')
  await evaluate(`${trigger}.scrollIntoView({block: 'center'}); ${trigger}.focus()`)
  const detail = await evaluate(`(() => {
    const signal = document.querySelector(${JSON.stringify(selector)});
    const tooltip = signal.querySelector('.status-tooltip');
    const bounds = tooltip.getBoundingClientRect();
    return {label: signal.getAttribute('aria-label'), state: signal.dataset.state,
      visible: getComputedStyle(tooltip).display, focus: (${trigger}).matches(':focus-visible'),
      withinViewport: bounds.left >= 0 && bounds.right <= innerWidth,
      outline: getComputedStyle(${trigger}).outlineStyle,
      custom: !!signal.querySelector('svg[aria-hidden=true]'),
      animated: !!signal.querySelector('.status-orbit')};
  })()`)
  assert.ok(detail.label.length > 10, 'quiet status retains meaningful accessible detail')
  assert.ok(['ready', 'unknown'].includes(detail.state), 'unobserved accounts are not falsely healthy')
  assert.equal(detail.visible, 'block', 'keyboard focus exposes the status meaning')
  assert.equal(detail.focus, true)
  assert.equal(detail.withinViewport, true, 'status details fit narrow screens')
  assert.notEqual(detail.outline, 'none')
  assert.equal(detail.custom, true)
  assert.equal(detail.animated, false, 'last-known health does not imply ongoing checks')
  await screenshot(`status-${embedded ? 'embedded' : 'detail'}-${width}${forced ? '-forced-colors' : ''}`)
  await key('Escape')
  assert.equal(await evaluate(`getComputedStyle(document.querySelector(${JSON.stringify(selector)}).querySelector('.status-tooltip')).display`), 'none', 'Escape dismisses detail')
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), 'true', 'tooltip dismissal does not enter scenery')
  assert.equal(await evaluate(`document.activeElement === ${trigger}`), true, 'dismissal preserves focus')
  await key('Escape')
  await landscape()
  await key('a', 'a')
  await focused()
  await evaluate("document.querySelector('#directory-heading').focus()")
  await evaluate(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block: 'center'})`)
  const point = await evaluate(`(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return {x: r.x + r.width / 2, y: r.y + r.height / 2}; })()`)
  await send('Input.dispatchMouseEvent', {type: 'mouseMoved', ...point})
  assert.equal(await evaluate(`getComputedStyle(document.querySelector(${JSON.stringify(selector)}).querySelector('.status-tooltip')).display`), 'block', 'hover also exposes details')
  await key('Escape')
  assert.equal(await evaluate(`getComputedStyle(document.querySelector(${JSON.stringify(selector)}).querySelector('.status-tooltip')).display`), 'none', 'Escape dismisses hover-only details with focus elsewhere')
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), 'true', 'hover dismissal preserves the working plane')
  await send('Input.dispatchMouseEvent', {type: 'mouseMoved', x: 1, y: 1})
}

async function readerLayout(width, forced) {
  const dimensions = await evaluate(`(() => {
    const text = document.querySelector('#mail-message-synthetic-message-3 .mail-message-text');
    const conversation = document.querySelector('#mail-conversation');
    const pane = document.querySelector('#workspace-content');
    const back = document.querySelector('#mail-back').getBoundingClientRect();
    const refresh = document.querySelector('#mail-refresh').getBoundingClientRect();
    return {font: getComputedStyle(text).fontSize, width: text.getBoundingClientRect().width,
      textOverflow: text.scrollWidth > text.clientWidth + 1,
      readerOverflow: conversation.scrollWidth > conversation.clientWidth + 1,
      readerBackground: getComputedStyle(conversation).backgroundColor,
      readerShadow: getComputedStyle(conversation).textShadow,
      paneShadow: getComputedStyle(pane).textShadow,
      paneOverflow: pane.scrollWidth > pane.clientWidth + 1,
      pageOverflow: document.documentElement.scrollWidth > innerWidth,
      backHeight: back.height, refreshHeight: refresh.height,
      controlsInPane: back.left >= 0 && refresh.right <= innerWidth,
      forced: matchMedia('(forced-colors: active)').matches};
  })()`)
  assert.equal(dimensions.font, width > 800 ? "18px" : "17px", "reader body type scales for desktop/narrow")
  if (!forced) {
    assert.equal(dimensions.readerBackground, "rgba(0, 0, 0, 0)", "reader uses the normal glass without an opaque fill")
    assert.equal(dimensions.readerShadow, dimensions.paneShadow, "reader inherits the shared glass text treatment")
  }
  // A generous proportional-font range around a 68ch reading measure, not a font-specific pixel snapshot.
  assert.ok(width > 800 ? dimensions.width >= 450 && dimensions.width <= 800 : dimensions.width >= 200 && dimensions.width <= width,
    `bounded reading measure at ${width}px (forced colors: ${forced}): ${JSON.stringify(dimensions)}`)
  assert.equal(dimensions.textOverflow || dimensions.readerOverflow || dimensions.paneOverflow || dimensions.pageOverflow, false,
    `long URL and escaped HTML must wrap at ${width}px (forced colors: ${forced})`)
  assert.ok(dimensions.backHeight >= 44 && dimensions.refreshHeight >= 44 && dimensions.controlsInPane, "reader controls remain usable and within the viewport")
  assert.equal(dimensions.forced, forced)
}

async function calendarItemLayout() {
  const events = await evaluate(`Array.from(document.querySelectorAll('#calendar-agenda .calendar-event'), item => {
    const card = item.getBoundingClientRect();
    const text = item.querySelector('.calendar-event-content').getBoundingClientRect();
    const time = item.querySelector('.calendar-event-time').getBoundingClientRect();
    const link = item.querySelector('.calendar-event-link')?.getBoundingClientRect();
    return {leftAligned: Math.abs(text.left - card.left) < 1,
      timeTopRight: Math.abs(time.top - text.top) < 1 && Math.abs(time.right - card.right) < 1,
      separated: text.right <= time.left,
      linkLeftAligned: !link || Math.abs(link.left - text.left) < 1,
      noOverflow: item.scrollWidth <= item.clientWidth};
  })`)
  assert.ok(events.length > 0, 'Calendar layout checks cover populated event items')
  assert.ok(events.every(event => event.leftAligned && event.timeTopRight && event.separated && event.linkLeftAligned && event.noOverflow),
    `Calendar event text stays left and time stays top-right: ${JSON.stringify(events)}`)
}

async function homeLayout(width, forced = false) {
  await evaluate("document.querySelector('#workspace-content').scrollTop = 0")
  const layout = await evaluate(`(() => {
    const mail = document.querySelector('#home-overview').getBoundingClientRect();
    const agenda = document.querySelector('#calendar-agenda').getBoundingClientRect();
    const readouts = document.querySelector('#home-readouts');
    const pane = document.querySelector('#workspace-content');
    return {sideBySide: agenda.left >= mail.right && Math.abs(agenda.top - mail.top) < 1,
      stacked: agenda.top >= mail.bottom && Math.abs(agenda.left - mail.left) < 1,
      overflow: document.documentElement.scrollWidth > innerWidth || pane.scrollWidth > pane.clientWidth + 1 || readouts.scrollWidth > readouts.clientWidth + 1,
      calendarHeadingVisible: agenda.top >= 0 && agenda.top < innerHeight,
      forced: matchMedia('(forced-colors: active)').matches};
  })()`)
  assert.equal(layout.overflow, false, `Home stays within ${width}px (forced colors: ${forced})`)
  assert.equal(width > 1000 ? layout.sideBySide : layout.stacked, true, `Home composition at ${width}px: ${JSON.stringify(layout)}`)
  if (width >= 1280) {
    assert.equal(layout.calendarHeadingVisible, true, `Calendar starts alongside Gmail: ${JSON.stringify(layout)}`)
  }
  assert.equal(layout.forced, forced)
  await calendarItemLayout()
}

async function connectionsOverview() {
  await waitFor("location.pathname === '/connections' && location.search === '' && !!document.querySelector('#connections-overview')", 'global Connections overview URL')
  assert.equal(await evaluate("document.querySelector('#show-connections').getAttribute('href')"), '/connections')
  assert.equal(await evaluate("!!document.querySelector('#google-connection, #connections-panel, #calendar-connections, #gemini-connection, #connections-subnav, #back-from-connections')"), false, 'overview mounts no provider or workspace return')
  assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth && Array.from(document.querySelectorAll('#connections-overview a')).every(link => link.getBoundingClientRect().height >= 44)"), true, 'overview stays within viewport with usable links')
}

async function openGmailConnections() {
  await click('#show-connections')
  await connectionsOverview()
  await click('#open-connection-gmail')
  await waitFor("!!document.querySelector('#connections-panel') && document.querySelector('#new-gmail-connection')?.disabled === false && location.pathname === '/connections/gmail' && location.search === ''", 'Gmail provider chosen explicitly with available Google client settings')
}

async function verifyNavigationHistory() {
  await evaluate("void (window.navigationSocket = window.liveSocket)")
  await click('#show-workspaces')
  await waitFor("location.pathname === '/workspaces' && !!document.querySelector('#workspace-list')", 'directory URL')
  await click(`#open-${workspaceId}`)
  await waitFor(`location.pathname === '/workspaces/${workspaceId}' && !!document.querySelector('#workspace-landing')`, 'workspace URL')
  await click('#show-connections')
  await connectionsOverview()
  await screenshot('connections-overview-desktop')
  await click('#open-connection-calendar')
  await waitFor("location.pathname === '/connections/calendar' && location.search === '' && !!document.querySelector('#calendar-connections')", 'Calendar URL is global even after workspace entry')
  await click('#show-scenes')
  await scenesLoaded()
  await evaluate('history.back()')
  await waitFor("location.pathname === '/connections/calendar' && !!document.querySelector('#calendar-connections')", 'Back to Calendar provider')
  await evaluate('history.back()')
  await connectionsOverview()
  await evaluate('history.back()')
  await waitFor(`location.pathname === '/workspaces/${workspaceId}' && !!document.querySelector('#workspace-landing')`, 'Back to workspace')
  await evaluate('history.back()')
  await waitFor("location.pathname === '/workspaces' && !!document.querySelector('#workspace-list')", 'Back to directory')
  await evaluate('history.forward()')
  await waitFor(`location.pathname === '/workspaces/${workspaceId}' && !!document.querySelector('#workspace-landing')`, 'Forward to workspace')
  assert.equal(await evaluate('window.navigationSocket === window.liveSocket'), true, 'patch navigation preserves the shared stage and LiveSocket')
  await send('Page.reload')
  await waitFor(`location.pathname === '/workspaces/${workspaceId}' && !!document.querySelector('#workspace-landing') && window.liveSocket?.getSocket().isConnected()`, 'reload retains workspace')
  await media([{name: 'prefers-reduced-motion', value: 'reduce'}])
  await click('#workspace-pane')
  await focused()
  await send('Page.navigate', {url: origin + `/connections/gemini?workspace=${workspaceId}`})
  await waitFor("location.pathname === '/connections/gemini' && location.search === '' && !!document.querySelector('#gemini-connection') && window.liveSocket?.getSocket().isConnected()", 'direct Gemini GET works and removes obsolete workspace query')
  await evaluate('window.navigationBeforeGeminiReload = true')
  await send('Page.reload')
  await waitFor("!window.navigationBeforeGeminiReload && location.pathname === '/connections/gemini' && !!document.querySelector('#gemini-connection') && window.liveSocket?.getSocket().isConnected()", 'Gemini provider reload works through credential boundary')
  await click('#workspace-pane')
  await focused()
  await click('#back-to-connections')
  await connectionsOverview()
  const deep = `/accounts/${accountId}/mail/threads/navigation-thread?q=synthetic&page_token=fixture-page`
  await send('Page.navigate', {url: origin + deep})
  await waitFor("!!document.querySelector('#mail-conversation-heading') && window.liveSocket?.getSocket().isConnected()", 'copied conversation link loads directly')
  await click('#workspace-pane')
  await focused()
  assert.equal(await evaluate('location.pathname + location.search'), deep)
  assert.equal(await evaluate("document.querySelector('#mail-search input').value"), 'synthetic')
  await click('#mail-back')
  await waitFor("document.querySelector('#mail-threads')?.getAttribute('aria-busy') === 'false'", 'direct-reader fallback to results')
  assert.equal(await evaluate('location.pathname + location.search'), `/accounts/${accountId}/mail?q=synthetic&page_token=fixture-page`)
  await screenshot('navigation-deep-link-results')
  await send('Page.navigate', {url: origin + '/accounts/00000000-0000-4000-8000-000000000099/mail'})
  await waitFor("location.pathname === '/workspaces' && !!document.querySelector('#workspace-list') && !!document.querySelector('#flash-error')", 'unavailable account link visibly canonicalizes to Workspaces')
  await click('#workspace-pane')
  await focused()
  await click('#flash-error button[aria-label=close]')
  await waitFor("!document.querySelector('#flash-error')", 'dismiss unavailable-account notice before Lock')
  await click('#owner-lock-form button')
  await waitFor("location.pathname === '/unlock' && !!document.querySelector('#owner-unlock-form')", 'fixture owner explicitly locks')
  await evaluate('window.navigationBeforeUnlock = true')
  await send('Page.navigate', {url: origin + '/connections/calendar'})
  await waitFor("!window.navigationBeforeUnlock && location.pathname === '/unlock' && !!document.querySelector('#owner-unlock-form')", 'protected deep link requires a fresh unlock page')
  await evaluate("document.querySelector('#owner-unlock-form input[type=password]').value = 'synthetic browser owner password'; document.querySelector('#owner-unlock-form').requestSubmit()")
  await waitFor("location.pathname === '/connections/calendar' && !!document.querySelector('#calendar-connections') && window.liveSocket?.getSocket().isConnected()", 'unlock resumes the requested deep page rather than Home')
  await click('#workspace-pane')
  await focused()
  await screenshot('navigation-unlock-return')
  await click('#home-link')
  await home()
  await media([])
  console.log('PASS global Connections overview and provider URLs, obsolete-query cleanup, direct Gemini GET/reload, browser Back/Forward, copied mail links, invalid-account recovery and unlock return')
}

async function verifyThemes() {
  await send('Emulation.setDeviceMetricsOverride', {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false})
  await media([{name: 'prefers-reduced-motion', value: 'reduce'}])
  await click('#show-settings')
  await waitFor("location.pathname === '/settings' && !!document.querySelector('#theme-picker')", 'Settings has a native destination')
  assert.equal(await evaluate("document.querySelector('#show-settings').getAttribute('aria-current')"), 'page')
  assert.equal(await evaluate("!!document.querySelector('#home-overview, #workspace-list, #mail-panel, #scenes-panel, #connections-overview')"), false, 'Settings is an exclusive view')
  const choices = ['charcoal', 'earth', 'sea-glass', 'mist']
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('#theme-picker input[name=theme]'), input => input.value)"), choices)
  const palettes = []
  const scene = await evaluate("getComputedStyle(document.querySelector('#workspace-background')).backgroundImage")
  const image = await evaluate("document.querySelector('#workspace-background img')?.getAttribute('src')")

  async function applied(theme, selector) {
    const state = await evaluate(`(() => {
      const element = document.querySelector(${JSON.stringify(selector)});
      const root = getComputedStyle(document.documentElement);
      const probe = document.createElement('span');
      probe.style.color = 'var(--color-base-content)';
      document.body.append(probe);
      const expected = getComputedStyle(probe).color;
      probe.remove();
      return {theme: document.documentElement.dataset.theme,
        saved: localStorage.getItem('lovelace:theme'),
        actual: getComputedStyle(element).color, expected,
        primary: root.getPropertyValue('--color-primary').trim(),
        base: root.getPropertyValue('--color-base-100').trim(),
        overflow: document.documentElement.scrollWidth > innerWidth,
        background: getComputedStyle(document.querySelector('#workspace-background')).backgroundImage,
        image: document.querySelector('#workspace-background img')?.getAttribute('src')};
    })()`)
    assert.equal(state.theme, theme)
    assert.equal(state.saved, theme)
    assert.equal(state.actual, state.expected, `${selector} inherits ${theme} text tokens`)
    assert.equal(state.overflow, false)
    assert.equal(state.background, scene, 'theme changes never replace bundled scenery')
    assert.equal(state.image, image, 'theme changes never replace selected imagery')
    return `${state.base}|${state.primary}`
  }

  for (const theme of choices) {
    const selector = `#theme-picker input[value="${theme}"]`
    await evaluate(`document.querySelector(${JSON.stringify(selector)}).focus()`)
    await send('Input.dispatchKeyEvent', {type: 'keyDown', key: ' ', code: 'Space', windowsVirtualKeyCode: 32, text: ' '})
    await send('Input.dispatchKeyEvent', {type: 'keyUp', key: ' ', code: 'Space', windowsVirtualKeyCode: 32})
    await waitFor(`document.documentElement.dataset.theme === ${JSON.stringify(theme)} && document.querySelector(${JSON.stringify(selector)}).checked`, `keyboard selects ${theme}`)
    assert.notEqual(await evaluate("getComputedStyle(document.activeElement).outlineStyle"), 'none', 'theme radios retain keyboard focus indication')
    palettes.push(await applied(theme, '#settings-panel'))
    await screenshot(`theme-${theme}-settings`)
    await send('Page.reload')
    await waitFor(`location.pathname === '/settings' && !!document.querySelector('#theme-picker') && window.liveSocket?.getSocket().isConnected()`, 'Settings deep-link reload')
    assert.equal(await evaluate(`document.querySelector(${JSON.stringify(selector)}).checked`), true, 'picker reflects saved theme after reload')
    await click('#workspace-pane')
    await focused()
    await applied(theme, '#settings-panel')
    await click('#home-link')
    await home()
    await applied(theme, '#home-overview')
    const attention = await evaluate(`(() => {
      const color = selector => getComputedStyle(document.querySelector(selector)).color;
      const probe = document.createElement('span');
      document.body.append(probe);
      const token = name => { probe.style.color = 'var(' + name + ')'; return getComputedStyle(probe).color; };
      const rgb = value => value.match(/[\\d.]+/g).slice(0, 3).map(Number);
      const luminance = value => rgb(value).map(v => {
        v /= 255; return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
      }).reduce((sum, v, i) => sum + v * [0.2126, 0.7152, 0.0722][i], 0);
      const hue = value => {
        const [r, g, b] = rgb(value), hi = Math.max(r, g, b), lo = Math.min(r, g, b), delta = hi - lo;
        if (delta < 20) return null;
        return ((hi === r ? (g - b) / delta : hi === g ? (b - r) / delta + 2 : (r - g) / delta + 4) * 60 + 360) % 360;
      };
      const ink = color('.github-home-attention');
      const y = luminance(ink);
      const contrast = ['--color-base-100', '--color-base-200', '--color-base-300'].map(name => {
        const background = luminance(token(name));
        return (Math.max(y, background) + 0.05) / (Math.min(y, background) + 0.05);
      });
      const attentionHue = hue(ink);
      const separation = [color('.github-home-total'), token('--color-warning'), token('--color-error')].map(value => {
        const other = hue(value);
        const difference = Math.abs(attentionHue - other);
        return other === null ? 180 : Math.min(difference, 360 - difference);
      });
      probe.remove();
      return {contrast, separation, attentionHue};
    })()`)
    assert.notEqual(attention.attentionHue, null, `${theme} attention stays chromatic beside neutral accents`)
    assert.ok(attention.contrast.every(ratio => ratio >= 4.5), `${theme} attention text meets AA contrast on all base surfaces`)
    assert.ok(attention.separation.every(degrees => degrees >= 45), `${theme} attention remains distinct from accent, warning and error hues`)
    await screenshot(`theme-${theme}-home`)
    await evaluate("document.querySelector('#github-readouts').scrollIntoView({block: 'center'})")
    await screenshot(`theme-${theme}-github-attention`)
    await click('#show-workspaces')
    await waitFor("!!document.querySelector('#workspace-list')", 'theme on Workspaces')
    await applied(theme, '#workspace-list')
    await screenshot(`theme-${theme}-workspaces`)
    await click('#home-link')
    await home()
    await click(`#open-home-account-${accountId}`)
    await waitFor("document.querySelector('#mail-threads')?.getAttribute('aria-busy') === 'false'", 'theme on loaded inbox')
    await applied(theme, '#mail-panel')
    await screenshot(`theme-${theme}-mail`)
    await click('#show-settings')
    await waitFor("!!document.querySelector('#theme-picker')", 'theme picker remounts')
    assert.equal(await evaluate(`document.querySelector(${JSON.stringify(selector)}).checked`), true, 'patch remount preserves saved selection')
  }
  assert.equal(new Set(palettes).size, 4, 'the four themes have distinct base/accent palettes')

  await evaluate('history.back()')
  await waitFor("!!document.querySelector('#mail-panel')", 'Back restores mail from Settings')
  await evaluate('history.forward()')
  await waitFor("!!document.querySelector('#theme-picker')", 'Forward restores Settings')
  for (const forced of [false, true]) {
    await media([{name: 'prefers-reduced-motion', value: 'reduce'}, ...(forced ? [{name: 'forced-colors', value: 'active'}] : [])])
    await send('Emulation.setDeviceMetricsOverride', {width: 390, height: 844, deviceScaleFactor: 1, mobile: false})
    assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth && document.querySelector('#theme-picker').scrollWidth <= document.querySelector('#theme-picker').clientWidth"), true, 'Settings fits narrow/forced-color surfaces')
    for (const theme of choices) {
      await click(`#theme-picker input[value="${theme}"]`)
      assert.equal(await evaluate(`document.querySelector('#theme-picker input[value="${theme}"]').checked`), true)
      if (forced) {
        assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-background')).display"), 'none')
        await evaluate(`document.querySelector('#theme-picker input[value="${theme}"]').focus()`)
        await send('Input.dispatchKeyEvent', {type: 'keyDown', key: ' ', code: 'Space', windowsVirtualKeyCode: 32, text: ' '})
        await send('Input.dispatchKeyEvent', {type: 'keyUp', key: ' ', code: 'Space', windowsVirtualKeyCode: 32})
        assert.notEqual(await evaluate("getComputedStyle(document.activeElement).outlineStyle"), 'none')
      }
    }
    await screenshot(forced ? 'theme-settings-forced-colors' : 'theme-settings-narrow')
    await click('#home-link')
    await home()
    assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true, 'GitHub attention pairs fit narrow and forced-color Home')
    if (forced) {
      assert.equal(await evaluate("getComputedStyle(document.querySelector('.github-home-attention')).color === getComputedStyle(document.querySelector('.github-home-total')).color"), true, 'forced colors replaces semantic inks with readable system text')
      assert.equal(await evaluate("document.querySelector('.github-home-number .sr-only').textContent.includes('needs attention')"), true, 'non-color attention meaning survives forced colors')
    }
    await evaluate("document.querySelector('#github-readouts').scrollIntoView({block: 'center'})")
    await screenshot(forced ? 'github-attention-forced-colors' : 'github-attention-narrow')
    await click('#show-settings')
    await waitFor("!!document.querySelector('#theme-picker')", 'Settings after GitHub palette inspection')
  }
  await media([{name: 'prefers-reduced-motion', value: 'reduce'}])
  await send('Emulation.setDeviceMetricsOverride', {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false})
  await click('#theme-picker input[value="sea-glass"]')
  await click('#owner-lock-form button')
  await waitFor("!!document.querySelector('#owner-unlock-form')", 'Lock retains theme on static unlock')
  assert.equal(await evaluate("document.documentElement.dataset.theme"), 'sea-glass')
  await send('Page.navigate', {url: origin + '/settings'})
  await waitFor("location.pathname === '/unlock' && !!document.querySelector('#owner-unlock-form')", 'Settings remains protected after Lock')
  await evaluate("document.querySelector('#owner-unlock-form input[type=password]').value = 'synthetic browser owner password'; document.querySelector('#owner-unlock-form').requestSubmit()")
  await waitFor("location.pathname === '/settings' && !!document.querySelector('#theme-picker') && window.liveSocket?.getSocket().isConnected()", 'unlock resumes Settings')
  await click('#workspace-pane')
  await focused()
  console.log('PASS four keyboard-selected themes across Settings/Home/Workspaces/mail, reload/history persistence, unchanged scenery, narrow/forced-color/reduced-motion controls and protected Settings deep link')
}

let homeVisits = 0
async function home() {
  await waitFor(`!!document.querySelector('#home-overview') &&
    document.querySelector('#home-link')?.getAttribute('aria-current') === 'page' &&
    document.title === 'Home · LOVELACE'`, `Home overview and title (visit ${++homeVisits})`)
  assert.equal(await evaluate("document.title"), "Home · LOVELACE")
  assert.equal(await evaluate("document.querySelector('#home-link').closest('nav')?.id"), "center-nav", "Home belongs to the center navigation")
  assert.equal(await evaluate("document.querySelector('#home-link').textContent.trim()"), "Home")
  assert.equal(await evaluate("location.pathname + location.search + location.hash"), "/", "Home has its canonical URL")
  assert.equal(await evaluate("!!document.querySelector('#workspace-list, #home-inbox, #connections-panel, #scenes-panel')"), false)
  const orientation = await evaluate(`(() => {
    const now = new Date();
    const hour = now.getHours();
    const date = document.querySelector('#daily-heading [data-daily-date]');
    return {
      greeting: document.querySelector('#daily-heading [data-daily-greeting]').textContent.trim(),
      expectedGreeting: hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening',
      date: date.textContent,
      expectedDate: new Intl.DateTimeFormat(undefined, {weekday: 'long', month: 'long', day: 'numeric'}).format(now),
      iso: date.getAttribute('datetime'),
      expectedIso: now.getFullYear() + '-' + String(now.getMonth() + 1).padStart(2, '0') + '-' + String(now.getDate()).padStart(2, '0'),
    };
  })()`)
  assert.equal(orientation.greeting, orientation.expectedGreeting, "greeting uses browser-local time")
  assert.equal(orientation.date, orientation.expectedDate, "date uses browser-local calendar")
  assert.equal(orientation.iso, orientation.expectedIso)
}

try {
  const endpoint = await new Promise((resolve, reject) => {
    let buffered = ""
    const timer = setTimeout(() => reject(new Error("Chrome did not start DevTools")), 10_000)
    chrome.once("error", error => { clearTimeout(timer); reject(error) })
    chrome.once("exit", () => { clearTimeout(timer); reject(new Error("Chrome exited before DevTools started")) })
    chrome.stderr.on("data", bytes => {
      buffered = (buffered + bytes.toString()).slice(-16_384)
      const match = buffered.match(/DevTools listening on (ws:\/\/127\.0\.0\.1:\d+\/[^\s]+)/)
      if (match) { clearTimeout(timer); resolve(match[1]) }
    })
  })
  socket = new WebSocket(endpoint)
  await once(socket, "open")
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data)
    const call = pending.get(message.id)
    if (call) {
      clearTimeout(call.timer)
      pending.delete(message.id)
      if (message.error) call.reject(new Error(message.error.message))
      else call.resolve(message.result)
    } else if (message.method === "Runtime.exceptionThrown") {
      errors.push("Uncaught page exception")
    } else if (message.method === "Runtime.bindingCalled" && message.params.name === "uiCspViolation") {
      cspViolations.push("CSP violation")
    } else if (message.method === "Fetch.requestPaused") {
      const {requestId, request} = message.params
      if (/\/attachments\//.test(request.url)) attachmentRequests.push(request.url)
      if (failStageImages && request.url.startsWith(`${origin}/stage/background/`)) {
        send("Fetch.failRequest", {requestId, errorReason: "Failed"}, message.sessionId).catch(() => {})
      } else if (allowYouTubeFixture && /^https:\/\/www\.youtube-nocookie\.com\/embed\/[A-Za-z0-9_-]{11}\?autoplay=0&rel=0$/.test(request.url)) {
        youtubeRequests.push(request.url)
        send("Fetch.fulfillRequest", {requestId, responseCode: 200,
          responseHeaders: [{name: "Content-Type", value: "text/html"}],
          body: Buffer.from("<!doctype html><title>Synthetic official-player boundary</title><p>Locally intercepted player. No YouTube contact.</p>").toString("base64")
        }, message.sessionId).catch(() => {})
      } else if (request.url.startsWith(`${origin}/`) || request.url.startsWith("data:")) {
        send("Fetch.continueRequest", {requestId}, message.sessionId).catch(() => {})
      } else {
        external.push("Off-origin page request blocked")
        send("Fetch.failRequest", {requestId, errorReason: "BlockedByClient"}, message.sessionId).catch(() => {})
      }
    }
  })
  const {targetId} = await send("Target.createTarget", {url: "about:blank"}, null)
  ;({sessionId} = await send("Target.attachToTarget", {targetId, flatten: true}, null))
  await send("Page.enable")
  await send("Runtime.enable")
  await send("Network.enable")
  await send("Network.setCacheDisabled", {cacheDisabled: true})
  await send("Fetch.enable", {patterns: [{urlPattern: "*"}]})
  await send("Runtime.addBinding", {name: "uiCspViolation"})
  await send("Page.addScriptToEvaluateOnNewDocument", {source:
    "document.addEventListener('securitypolicyviolation', () => window.uiCspViolation('CSP violation'));"})
  await send("Emulation.setTimezoneOverride", {timezoneId: "UTC"})
  await send("Emulation.setDeviceMetricsOverride", {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false})
  await send("Page.navigate", {url: `${origin}/unlock`})
  await waitFor("!!document.querySelector('#owner-unlock-form') && getComputedStyle(document.documentElement).getPropertyValue('--workspace-scenery-blur').trim() !== ''", "styled static unlock")
  if (mode === 'bundled-default') {
    await verifyEmptyInstallation()
  } else {
  assert.equal(await evaluate("document.querySelector('#owner-stage [phx-hook], #owner-stage [inert]') === null"), true)
  assert.notEqual(await evaluate("getComputedStyle(document.querySelector('#owner-stage-background')).filter"), "none")
  await waitFor("document.querySelector('[data-static-stage-image]')?.dataset.loaded === 'true'", "static app image-observer registration")
  failStageImages = true
  await send("Page.reload")
  await waitFor("document.querySelector('[data-static-stage-image]')?.dataset.loaded === 'false'", "failed static image keeps fallback")
  assert.equal(await evaluate("getComputedStyle(document.querySelector('[data-static-stage-image]')).opacity"), "0")
  failStageImages = false
  await send("Emulation.setScriptExecutionDisabled", {value: true})
  await send("Page.reload")
  await waitFor("!!document.querySelector('#owner-unlock-form')", "static owner usable without JavaScript")
  assert.equal(await evaluate("document.querySelector('#owner-unlock-form input[type=password]').disabled"), false)
  await send("Emulation.setScriptExecutionDisabled", {value: false})
  await send("Page.reload")
  await waitFor("document.querySelector('[data-static-stage-image]')?.dataset.loaded === 'true'", "restored static observer")
  await evaluate(`document.querySelector('#owner-unlock-form input[type=password]').value = 'synthetic browser owner password'; document.querySelector('#owner-unlock-form').requestSubmit()`)
  await waitFor(`!!document.querySelector('#home-accounts') && window.liveSocket?.getSocket().isConnected()`, "connected Home after unlock")
  await home()
  await landscape()
  await click("#workspace-pane")
  assert.equal(await evaluate("document.querySelector('#main-content').dataset.entered ?? 'false'"), "false")
  assert.equal(await evaluate("document.querySelector('#workspace-content').inert"), true)
  assert.equal(await evaluate("document.querySelector('#workspace-controls').inert"), true)
  await waitFor("document.querySelector('#lovelace-letter-7').style.opacity === '1' && document.querySelector('#main-content').dataset.entered !== 'true'", "completed wordmark before exit")
  await waitFor("Number(document.querySelector('#lovelace-letter-0').style.opacity) < Number(document.querySelector('#lovelace-letter-7').style.opacity)", "left-to-right letter exit")
  await waitFor("parseFloat(document.querySelector('#lovelace-monogram-stroke').style.strokeDashoffset) < 0 && Number(document.querySelector('#lovelace-letter-0').style.opacity) < 1", "opposite-end erase before handoff")
  assert.equal(await evaluate("getComputedStyle(document.querySelector('#owner-lock-form')).visibility"), "hidden")
  assert.equal(await evaluate("getComputedStyle(document.querySelector('#home-link')).visibility"), "hidden")
  await focused()
  await waitFor("document.querySelector('#workspace-background img')?.dataset.loaded === 'true'", "live image hook load")
  assert.equal(await evaluate("document.activeElement.id"), "directory-heading")
  console.log("PASS ordinary entrance, static stage, Home/Lock visibility and gate/focus handoff")

  await verifyGitHubDiscovery()
  await home()
  await verifyNavigationHistory()
  await home()
  await verifyYouTube()
  assert.equal(await evaluate("document.querySelectorAll('#home-accounts > li').length"), 5, "one Home card per connection, not per membership")
  for (const [id, count, recent] of [[accountId, "7", "3"], [unattachedId, "0", "0"]]) {
    assert.equal(await evaluate(`document.querySelectorAll('#home-account-${id}').length`), 1)
    assert.equal(await evaluate(`document.querySelector('#home-count-${id} .home-unread-number').textContent.trim()`), count)
    assert.equal(await evaluate(`document.querySelector('#home-count-${id} .home-unread-recent').textContent.trim()`), recent)
    await waitFor(`document.querySelector('#home-freshness-${id}')?.dataset.warningsOnly === 'true' && document.querySelector('#home-freshness-${id}').textContent.trim() === ''`, "Home omits routine checked statuses")
  }
  const memberships = await evaluate(`document.querySelector('#home-account-${accountId} .home-account-workspaces').textContent`)
  assert.match(memberships, /Browser studio/)
  assert.match(memberships, /Synthetic space 1/)
  assert.match(await evaluate(`document.querySelector('#home-account-${unattachedId}').textContent`), /Not in a workspace/)

  await waitFor("document.querySelector('#calendar-agenda')?.textContent.includes('Synthetic focus time')", "browser-local Calendar cache renders")
  assert.equal(await evaluate("document.querySelectorAll('#calendar-agenda .calendar-account').length"), 1, "Calendar remains opt-in per account")
  assert.equal(await evaluate("!!document.querySelector('#calendar-agenda button[phx-click=\"calendar:refresh\"]')"), false, 'Home Calendar has no Refresh button')
  assert.equal(await evaluate("/\\bchecked\\b/i.test(document.querySelector('#home-readouts').textContent)"), false, 'Home has no checked status copy')
  assert.equal(await evaluate("document.querySelector('#calendar-agenda .calendar-status').getBoundingClientRect().height"), 0, 'healthy Calendar does not reserve a checked-status line')
  assert.match(await evaluate("document.querySelector('#calendar-agenda').textContent"), /All day/)
  assert.equal(await evaluate("document.querySelector('#calendar-agenda a').hostname"), "calendar.google.com")
  assert.equal(await evaluate("document.querySelector('#calendar-agenda a').rel"), "noopener noreferrer")
  assert.equal(await evaluate("document.querySelector('#calendar-agenda').textContent.includes('background polling while LOVELACE is running')"), false)
  await homeLayout(1440)
  await screenshot("calendar-home-desktop")
  for (const width of [1280, 1100, 1000]) {
    await send('Emulation.setDeviceMetricsOverride', {width, height: 800, deviceScaleFactor: 1, mobile: false})
    await homeLayout(width)
    if (width === 1280) await screenshot('home-laptop')
    if (width === 1000) await screenshot('home-stacked-tablet')
  }
  await send('Emulation.setDeviceMetricsOverride', {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false})
  await click("#show-connections")
  await connectionsOverview()
  await click("#open-connection-calendar")
  await waitFor("!!document.querySelector('#calendar-connections') && !document.querySelector('#connections-panel, #gemini-connection')", "exclusive Calendar connection provider")
  await click(`#calendar-connections-selection-${accountId} summary`)
  assert.equal(await evaluate(`document.querySelector('#calendar-connections-select-${accountId} input[value=primary]').checked`), true, "Google-selected default calendar")
  assert.equal(await evaluate(`document.querySelector('#calendar-connections-select-${accountId} input[value="shared@example.test"]').checked`), false, "shared calendar is available but not implicitly selected")
  const optionalConsent = await evaluate(`(() => {
    const form = document.querySelector('#calendar-connections-authorize-${unattachedId}');
    return {method:form.method, action:new URL(form.action).pathname,
      capability:form.querySelector('[name=capability]').value,
      account:form.querySelector('[name=expected_account_id]').value,
      required:form.querySelector('select').required};
  })()`)
  assert.deepEqual(optionalConsent, {method:"post", action:"/oauth/google/start", capability:"calendar", account:unattachedId, required:true})
  await screenshot("calendar-connections-desktop")
  await click("#home-link")
  console.log("PASS optional account-scoped Calendar agenda, all-day/local times, safe links and shared-calendar selection")

  await evaluate("document.querySelector('#show-scenes').focus()")
  await key("Enter")
  await scenesLoaded()
  await waitFor("document.activeElement.id === 'directory-heading'", "keyboard Scenes navigation transfers heading focus")
  const initialScenes = await sceneManifest()
  assert.equal(initialScenes.attempts.length, 1, "fixture exposes its actual last attempt")
  assert.equal(initialScenes.scenes.length, 20, "the first gallery page is bounded to 20 scenes")
  assert.equal(new Set(initialScenes.scenes.map(scene => scene.id)).size, 20)
  assert.ok(initialScenes.scenes.every(scene => Number.isFinite(Date.parse(scene.generatedAt)) && Date.parse(scene.generatedAt) < Date.now() - 86_400_000), "every synthetic scene has an honest generation timestamp older than the cooldown")
  assert.ok(initialScenes.scenes.every((scene, index, scenes) => index === 0 || Date.parse(scenes[index - 1].generatedAt) > Date.parse(scene.generatedAt)), "retained scenes are newest first")
  assert.ok(Date.parse(initialScenes.attempts[0]) > Date.now() - 60_000, 'the failed fixture attempt is recent, not an expired cooldown')
  assert.equal(await evaluate("document.querySelector('#scene-generate').disabled"), false, "manual confirmation remains available immediately after failure, even with startup disabled")
  assert.equal(await evaluate("Array.from(document.querySelectorAll('#scene-gallery > .scene-card')).every(card => { const digest = card.id.slice(6); const image = card.querySelector('img'); const button = card.querySelector('button'); return /^[0-9a-f]{64}$/.test(digest) && image.id === 'scene-preview-' + digest && image.getAttribute('phx-hook') === 'StageBackground' && !!image.alt && button.id === 'use-scene-' + digest && button.disabled === (card.dataset.active === 'true'); })"), true, "digest IDs, loaded hook thumbnails, accessible names and selection availability agree")
  assert.equal(await evaluate("document.querySelector('#scene-generate').textContent.trim()"), 'Generate scene', 'primary label has no ellipsis')
  assert.equal(await evaluate("!!document.querySelector('#scene-generate [aria-hidden=true] .hero-sparkles') && getComputedStyle(document.querySelector('#scene-generate .hero-sparkles')).maskImage !== 'none'"), true, 'primary button renders the local Gemini sparkles icon')
  assert.equal(await evaluate("document.querySelector('#scenes-panel').textContent.includes('API charges') || !!document.querySelector('.scene-policy')"), false, 'no persistent API-charges warning')
  await scenesLayout(1440, false)
  await screenshot("scenes-desktop")
  const savedDirectionPrompt = await guidedSceneDirection()

  assert.equal(await evaluate("document.querySelector('#scenes-panel').dataset.page"), "1")
  assert.equal(await evaluate("document.querySelector('#scene-pagination').getAttribute('aria-label')"), "Scene gallery pages")
  assert.deepEqual(await evaluate("['newer', 'older'].map(direction => { const button = document.querySelector('#scenes-' + direction); return {direction: button.getAttribute('phx-value-direction'), disabled: button.disabled}; })"), [
    {direction: "newer", disabled: true}, {direction: "older", disabled: false},
  ])
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('#scene-gallery button'), button => button.getAttribute('aria-label'))"),
    Array.from({length: 20}, (_, index) => `Use scene ${index + 1} as background`), "scene labels begin at one on the newest page")
  await click("#scenes-older")
  await waitFor("document.querySelector('#scenes-panel')?.dataset.page === '2'", "real older-page response")
  await scenesLoaded(3, 0)
  const olderScenes = await sceneManifest()
  const allScenes = [...initialScenes.scenes, ...olderScenes.scenes]
  assert.equal(new Set(allScenes.map(scene => scene.id)).size, 23, "paging retains all 23 distinct archived scenes, not only the recent fallback window")
  assert.equal(new Set(allScenes.map(scene => scene.src)).size, 23, "every archived fixture has its own served image")
  assert.ok(allScenes.every((scene, index, scenes) => Number.isFinite(Date.parse(scene.generatedAt)) &&
    Date.parse(scene.generatedAt) < Date.now() - 86_400_000 &&
    (index === 0 || Date.parse(scenes[index - 1].generatedAt) > Date.parse(scene.generatedAt))), "generation timestamps remain honest and newest-first across page boundaries")
  assert.deepEqual(olderScenes.attempts, initialScenes.attempts, "paging does not reserve generation")
  assert.deepEqual(await evaluate("['newer', 'older'].map(direction => document.querySelector('#scenes-' + direction).disabled)"), [false, true], "the final page enables only Newer")
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('#scene-gallery button'), button => button.getAttribute('aria-label'))"),
    [21, 22, 23].map(index => `Use scene ${index} as background`), "older-page scene labels use global indices")
  const oldestScene = olderScenes.scenes.at(-1)
  const oldestDigest = oldestScene.id.slice(6)
  await click(`#use-scene-${oldestDigest}`)
  await waitFor(`document.querySelector('#scene-${oldestDigest}')?.dataset.active === 'true' &&
    document.querySelector('#workspace-background img')?.getAttribute('src') === ${JSON.stringify(oldestScene.src)} &&
    document.querySelector('#workspace-background img')?.dataset.loaded === 'true'`, "an archived scene outside the recent seven is served and selectable")
  await scenesLoaded(3)
  assert.equal(await evaluate("document.querySelector('#scenes-panel').dataset.page"), "2", "selection retains the older gallery page")
  await scenesLayout(1440, false)
  await screenshot("scenes-older-selected")
  await click("#scenes-newer")
  await waitFor("document.querySelector('#scenes-panel')?.dataset.page === '1'", "return to the newer gallery page")
  await scenesLoaded(20, 0)
  assert.deepEqual(await sceneManifest(), {...initialScenes, scenes: initialScenes.scenes.map(scene => ({...scene, active: "false"}))}, "returning to newer scenes preserves dates and the off-page selection")
  assert.equal(await evaluate("document.querySelector('#workspace-background img').getAttribute('src')"), oldestScene.src, "paging never changes the selected background")
  const originalScene = initialScenes.scenes.find(scene => scene.active === "true")
  await click(`#use-scene-${originalScene.id.slice(6)}`)
  await waitFor(`document.querySelector('#workspace-background img')?.getAttribute('src') === ${JSON.stringify(originalScene.src)} &&
    document.querySelector('#workspace-background img')?.dataset.loaded === 'true'`, "restore the original scene before consent and cross-tab checks")
  await scenesLoaded()
  assert.deepEqual(await sceneManifest(), initialScenes, "archive selection and paging do not change generation attempts or image dates")
  console.log("PASS real 20 + 3 scene pagination, global labels, archived image serving/selection and return to newer scenes")

  // First verify safe cancellation. After these checks, Confirm is exercised
  // only against the disposable fixture's empty fake vault: no provider HTTP.
  await evaluate("document.querySelector('#scene-generate').focus()")
  await key("Enter")
  await sceneModal()
  assert.equal(await evaluate("(() => { document.querySelector('#home-link').focus(); return document.activeElement.id; })()"), "scene-generation-cancel", "native scene dialog prevents focus escaping to navigation")
  await key("Tab", undefined, 8)
  assert.equal(await evaluate("document.activeElement.id"), "scene-generation-confirm", "Shift+Tab reaches the explicit charge-bearing action")
  await key("Tab")
  assert.equal(await evaluate("document.activeElement.id"), "scene-generation-cancel")
  for (let index = 0; index < 5; index++) {
    await key("Tab")
    assert.equal(await evaluate("document.activeElement === document.body || document.querySelector('#scene-generation-modal').contains(document.activeElement)"), true, "native scene dialog contains keyboard traversal")
  }
  await evaluate("document.querySelector('#scene-generation-cancel').focus()")
  await screenshot("scene-confirmation")
  await key("Escape")
  await waitFor("!document.querySelector('#scene-generation-modal') && document.activeElement.id === 'scene-generate'", "scene Escape dismisses only confirmation and restores Generate")
  await focused()
  assert.deepEqual(await sceneManifest(), initialScenes, "opening and Escape do not reserve generation or change scenery")
  await key("Enter")
  await sceneModal()
  await key("Enter") // Safe default: Cancel, not the charge-bearing Confirm.
  await waitFor("!document.querySelector('#scene-generation-modal') && document.activeElement.id === 'scene-generate'", "default keyboard Cancel restores Generate")
  await refreshScenes()
  assert.deepEqual(await sceneManifest(), initialScenes, "Cancel and Refresh are read-only, including attempt timestamps and selection")
  assert.equal(await evaluate("document.querySelector('#scene-generate').disabled"), false, "cancelled consent leaves manual requests available")

  // A second authenticated tab uses this same disposable profile/database. Its
  // Home remains untouched while app-wide selection arrives through real PubSub.
  const {targetId: sharedTargetId} = await send("Target.createTarget", {url: "about:blank"}, null)
  try {
    const {sessionId: sharedSession} = await send("Target.attachToTarget", {targetId: sharedTargetId, flatten: true}, null)
    await send("Page.enable", {}, sharedSession)
    await send("Runtime.enable", {}, sharedSession)
    await send("Emulation.setTimezoneOverride", {timezoneId: "UTC"}, sharedSession)
    await send("Fetch.enable", {patterns: [{urlPattern: "*"}]}, sharedSession)
    await send("Runtime.addBinding", {name: "uiCspViolation"}, sharedSession)
    await send("Page.addScriptToEvaluateOnNewDocument", {source: "document.addEventListener('securitypolicyviolation', () => window.uiCspViolation('CSP violation'));"}, sharedSession)
    await send("Page.navigate", {url: `${origin}/`}, sharedSession)
    await waitFor("!!document.querySelector('#home-overview') && window.liveSocket?.getSocket().isConnected() && document.querySelector('#workspace-background img')?.dataset.loaded === 'true'", "second disposable Home is connected", 8_000, sharedSession)
    // createTarget activates the new tab; foreground the driving tab so Chrome
    // does not defer LiveView's animation-frame title/focus work while hidden.
    await send("Target.activateTarget", {targetId}, null)
    const chosen = initialScenes.scenes.find(scene => scene.active === "false")
    const digest = chosen.id.slice(6)
    await click(`#use-scene-${digest}`)
    await waitFor(`document.querySelector('#scene-${digest}')?.dataset.active === 'true' &&
      document.querySelector('#workspace-background img')?.getAttribute('src') === ${JSON.stringify(chosen.src)} &&
      document.querySelector('#workspace-background img')?.dataset.loaded === 'true'`, "selection updates the shared stage and active card")
    await scenesLoaded()
    await waitFor(`document.querySelector('#workspace-background img')?.getAttribute('src') === ${JSON.stringify(chosen.src)} &&
      document.querySelector('#workspace-background img')?.dataset.loaded === 'true'`, "other tab receives app-wide stage selection", 8_000, sharedSession)
    assert.equal(await evaluate("!!document.querySelector('#home-overview') && !document.querySelector('#scenes-panel') && document.querySelector('#main-content').dataset.entered !== 'true'", sharedSession), true, "a stage update does not navigate or wake another tab")
    assert.deepEqual((await sceneManifest()).attempts, initialScenes.attempts, "selection does not reserve generation")
    assert.equal(await evaluate(`document.querySelector('#use-scene-${digest}').disabled`), true)
    assert.equal(await evaluate("document.querySelectorAll('#scene-gallery button:not(:disabled)').length"), 19)
    const selectedScenes = await sceneManifest()
    await refreshScenes()
    assert.deepEqual(await sceneManifest(), selectedScenes, "read-only Refresh preserves manual selection and dates")

    const sceneScroll = await evaluate("document.querySelector('#workspace-content').scrollTop")
    await key("Escape")
    await landscape()
    assert.equal(await evaluate("!!document.querySelector('#scenes-panel') && !document.querySelector('#scene-generation-modal')"), true)
    await key("a", "a")
    await focused()
    assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), sceneScroll)
    assert.deepEqual(await sceneManifest(), selectedScenes, "scenery Escape/wake retains the Scenes view, selection and reservation")

    await media([{name: "prefers-reduced-motion", value: "reduce"}])
    await send("Page.reload")
    await waitFor(`location.pathname === '/scenes' && !!document.querySelector('#scenes-panel') && window.liveSocket?.getSocket().isConnected() &&
      document.querySelector('#workspace-background img')?.getAttribute('src') === ${JSON.stringify(chosen.src)} &&
      document.querySelector('#workspace-background img')?.dataset.loaded === 'true'`, "reload retains Scenes with the persisted chosen background")
    await click("#workspace-pane")
    await focused()
    await scenesLoaded()
    assert.deepEqual(await sceneManifest(), selectedScenes, "manual scene selection and timestamps survive a real page reload")
    await waitFor("!!document.querySelector('#scene-direction-form')", "saved direction loads after real reload")
    assert.equal(await evaluate("document.querySelector('#scene-direction-prompt').textContent"), savedDirectionPrompt, "saved direction survives real reload")
    assert.equal(await evaluate("document.querySelector('#scene-direction-setting').value"), 'coast')
    assert.equal(await evaluate("document.querySelector('#scene-generate').disabled"), false, "navigation, stage broadcasts and reload preserve manual availability")
  } finally {
    await send("Target.closeTarget", {targetId: sharedTargetId}, null)
  }
  // The test build refuses the production connector even with a synthetic key.
  // A confirmed local failure must not disable generation for another 24 hours.
  const beforeConfirmedAttempt = (await sceneManifest()).attempts[0]
  await click('#scene-generate')
  await sceneModal()
  await click('#scene-generation-confirm')
  await waitFor(`!document.querySelector('#scene-generation-modal') &&
    document.querySelector('#scenes-panel')?.getAttribute('aria-busy') === 'false' &&
    document.querySelector('#scene-generate')?.disabled === false &&
    document.querySelector('#scenes-panel .scene-status time')?.dateTime !== ${JSON.stringify(beforeConfirmedAttempt)} &&
    document.querySelector('#scenes-panel .scene-status')?.textContent.includes('Scene generation failed')`, 'confirmed test-transport failure leaves manual Generate enabled')
  await screenshot('scenes-after-confirmed-failure')
  await click("#home-link")
  await home()
  await media([])
  console.log("PASS Scenes keyboard navigation, confirmation with local test-transport failure and immediate manual availability, cross-tab selection, Escape/wake and reload persistence")

  await click(`#open-home-account-${accountId}`)
  await waitFor("document.querySelector('#home-inbox #mail-threads')?.getAttribute('aria-busy') === 'false'", "Home row opens separate account inbox")
  assert.equal(await evaluate("document.querySelector('#mail-heading').textContent.trim()"), "browser@example.test")
  assert.equal(await evaluate("document.querySelector('#home-link').hasAttribute('aria-current')"), false)
  await evaluate("document.querySelector('#workspace-content').scrollTop = 100")
  const inboxScroll = await evaluate("document.querySelector('#workspace-content').scrollTop")
  assert.ok(inboxScroll > 0, "synthetic inbox must really scroll")
  await key("Escape")
  await landscape()
  assert.equal(await evaluate("!!document.querySelector('#home-inbox #mail-account-view')"), true)
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), inboxScroll)
  await key("a", "a")
  await focused()
  assert.equal(await evaluate("document.querySelector('#mail-heading').textContent.trim()"), "browser@example.test")
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), inboxScroll)
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '0.02'")
  await key("Shift")
  await landscape()
  assert.equal(await evaluate("!!document.querySelector('#home-inbox #mail-account-view')"), true)
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), inboxScroll)
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '3'")
  await key("a", "a")
  await focused()
  assert.equal(await evaluate("document.querySelector('#mail-heading').textContent.trim()"), "browser@example.test")
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), inboxScroll)

  const conversationTitle = await evaluate("document.querySelector('#mail-thread-synthetic-thread-12 .mail-thread-subject').textContent.trim()")
  const resultsContext = await evaluate("document.querySelector('#mail-panel').dataset.mailContext")
  assert.ok(resultsContext, "inbox has an opaque results context")
  const returnScroll = await click("#mail-thread-synthetic-thread-12")
  assert.ok(returnScroll > 100, "open a genuinely scrolled result, capturing after the click helper scrolls it into view")
  const loadingHeight = await loadingStatus(false, false)
  await screenshot('mail-active-signal')
  await media([{name: "prefers-reduced-motion", value: "reduce"}])
  assert.equal(await evaluate("getComputedStyle(document.querySelector('#mail-loading .status-orbit')).animationName"), "none", "mid-load reduced-motion change stops the orbit")
  await media([])
  await readerLoaded()
  assert.equal(await evaluate("document.querySelector('#mail-status').getBoundingClientRect().height"), loadingHeight, "status space stays stable when loading completes")
  assert.equal(await evaluate("document.querySelector('#mail-panel').getAttribute('phx-hook')"), "MailReader")
  assert.equal(await evaluate("document.querySelector('#mail-panel').dataset.mailThread"), "synthetic-thread-12")
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('details.mail-message'), message => ({id: message.id, open: message.open}))"), [
    {id: "mail-message-synthetic-message-1", open: false},
    {id: "mail-message-synthetic-message-2", open: false},
    {id: "mail-message-synthetic-message-3", open: true},
  ], "chronological conversation expands only the latest message")
  assert.equal(await evaluate("document.querySelectorAll('#mail-conversation-heading').length"), 1)
  assert.equal(await evaluate("document.querySelector('#mail-conversation-heading').textContent.trim()"), conversationTitle)
  assert.equal(await evaluate(`Array.from(document.querySelectorAll('#mail-panel :is(h1, h2, h3, h4, h5, h6)')).filter(heading => heading.textContent.trim() === ${JSON.stringify(conversationTitle)}).length`), 1, "conversation subject is not repeated as message titles")
  assert.equal(await evaluate("document.querySelectorAll('.mail-message-subject').length"), 1, "only the changed middle subject gets a per-message title")
  assert.equal(await evaluate("!!document.querySelector('#mail-message-synthetic-message-2 .mail-message-subject')"), true)
  await evaluate("document.querySelector('#mail-message-synthetic-message-3 .mail-attachment').scrollIntoView({block: 'center'})")
  assert.equal(await evaluate("document.querySelectorAll('.mail-attachment img, .mail-attachment [src]').length"), 0, "opening a thread renders attachment metadata without image sources")
  assert.deepEqual(attachmentRequests, [], "opening and scrolling a thread never retrieves attachments")
  assert.equal(await evaluate("document.querySelector('#mail-message-synthetic-message-3 .mail-attachment-name').textContent.trim()"), "synthetic-scene.png")
  assert.equal(await evaluate("document.querySelector('#mail-message-synthetic-message-3 .mail-attachment a[href$=\"?download=1\"]').textContent.trim()"), "Download", "download uses an explicit same-origin attachment route")
  const previewSelector = '#mail-message-synthetic-message-3 .mail-attachment a[target="_blank"]'
  const previewUrl = await evaluate(`document.querySelector(${JSON.stringify(previewSelector)}).href`)
  assert.ok(previewUrl.startsWith(`${origin}/`), "preview stays on the authenticated same-origin route")
  await click(previewSelector)
  let previewTarget
  const previewDeadline = Date.now() + 8_000
  while (!previewTarget && Date.now() < previewDeadline) {
    const previewTargets = await send("Target.getTargets", {}, null)
    previewTarget = previewTargets.targetInfos.find(target => target.url === previewUrl)
    if (!previewTarget) await new Promise(resolve => setTimeout(resolve, 25))
  }
  assert.ok(previewTarget, "explicit Preview image opens its authenticated route in a new tab")
  try {
    const {sessionId: previewSession} = await send("Target.attachToTarget", {targetId: previewTarget.targetId, flatten: true}, null)
    await send("Runtime.enable", {}, previewSession)
    await waitFor("document.querySelector('img')?.naturalWidth === 480", "explicitly requested raster attachment safely decodes", 8_000, previewSession)
  } finally {
    await send("Target.closeTarget", {targetId: previewTarget.targetId}, null)
    await send("Target.activateTarget", {targetId}, null)
  }
  await readerLayout(1440, false)
  await screenshot('mail-attachments-desktop')

  await evaluate("document.querySelector('#mail-message-synthetic-message-1 > summary.mail-message-summary').focus()")
  await key("Enter")
  await waitFor("document.querySelector('#mail-message-synthetic-message-1').open", "native summary Enter opens earlier message")
  await key("Enter")
  await waitFor("!document.querySelector('#mail-message-synthetic-message-1').open", "native summary Enter collapses earlier message")
  await key("Enter")
  await waitFor("document.querySelector('#mail-message-synthetic-message-1').open", "reopen earlier message before refresh")
  await click("#mail-message-synthetic-message-2 > summary.mail-message-summary")
  await waitFor("document.querySelector('#mail-message-synthetic-message-2').open", "mouse opens middle message")
  await click("#mail-message-synthetic-message-3 > summary.mail-message-summary")
  await waitFor("!document.querySelector('#mail-message-synthetic-message-3').open", "collapse latest before refresh")

  // Observe the real loading round trip, so a fast pre-response assertion cannot pass accidentally.
  await evaluate(`(() => {
    window.uiMailRefreshDone = false;
    const observer = new MutationObserver(records => {
      if (records.some(record => record.target.id === 'mail-conversation' &&
          record.attributeName === 'aria-busy' && record.oldValue === 'true') &&
          document.querySelector('#mail-conversation')?.getAttribute('aria-busy') === 'false') {
        window.uiMailRefreshDone = true;
        observer.disconnect();
      }
    });
    observer.observe(document.querySelector('#mail-panel'), {subtree: true, attributes: true, attributeOldValue: true, attributeFilter: ['aria-busy']});
  })()`)
  await click("#mail-refresh")
  await waitFor("window.uiMailRefreshDone", "Refresh completes an asynchronous mail load")
  await readerLoaded()
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('details.mail-message'), message => message.open)"), [true, true, false], "user expansion choices survive Refresh, including collapsed latest")
  await click("#mail-message-synthetic-message-3 > summary.mail-message-summary")
  await waitFor("document.querySelector('#mail-message-synthetic-message-3').open", "reopen latest body")
  const metadata = "#mail-message-synthetic-message-3 .mail-message-details"
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(metadata)}).open`), false)
  await click(`${metadata} > summary`)
  await waitFor(`document.querySelector(${JSON.stringify(metadata)}).open`, "recipient metadata disclosure opens")
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(metadata)}).textContent.includes('<img src="https://mail-fixture.invalid/recipient.png">')`), true, "recipient markup is literal escaped metadata")
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(metadata)}).textContent.includes('Sat, 15 Mar 2025 11:30:00 +0000')`), true, "raw RFC2822 date remains available in details")
  assert.equal(await evaluate("document.querySelector('#mail-message-synthetic-message-3 .mail-message-text').textContent.includes('<img src=\"https://mail-fixture.invalid/body.png\"')"), true, "hostile body markup is literal text")
  assert.equal(await evaluate("Array.from(document.querySelectorAll('#mail-conversation img')).every(image => image.src.startsWith(location.origin + '/accounts/')) && document.querySelector('#mail-conversation iframe, #mail-conversation script') === null"), true, "email body content creates no remote-content elements; previews stay on authenticated local routes")
  assert.deepEqual(external, [], "body and metadata must not request remote content")
  await click(`${metadata} > summary`)
  await waitFor(`!document.querySelector(${JSON.stringify(metadata)}).open`, "recipient metadata disclosure closes")

  await evaluate("document.querySelector('#workspace-content').scrollTop = 700")
  const readerScroll = await evaluate("document.querySelector('#workspace-content').scrollTop")
  assert.ok(readerScroll > 100, "long latest message makes the reader scroll")
  await key("Escape")
  await landscape()
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), readerScroll)
  assert.equal(await evaluate("!!document.querySelector('#mail-message-synthetic-message-3[open] .mail-message-text') && !document.querySelector('#mail-threads')"), true)
  await key("a", "a")
  await focused()
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), readerScroll)
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('details.mail-message'), message => message.open)"), [true, true, true], "Escape/wake retains reader content and disclosures")
  await evaluate("history.back()")
  await waitFor(`document.querySelector('#mail-threads')?.getAttribute('aria-busy') === 'false' &&
    document.activeElement.id === 'mail-thread-synthetic-thread-12' &&
    Math.abs(document.querySelector('#workspace-content').scrollTop - ${returnScroll}) <= 1`, "Back restores original row keyboard focus and actual click scroll after async results")
  assert.equal(await evaluate("!!document.querySelector('#mail-conversation')"), false)
  assert.equal(await evaluate("document.querySelector('#mail-panel').dataset.mailContext"), resultsContext, "Back returns to the same results context")
  console.log("PASS dedicated conversation, native message/recipient disclosures, Refresh preservation, escaped mail, reader Escape/wake and async Back focus/scroll")
  await click("#home-link")
  await home()

  await click(`#open-home-account-${unattachedId}`)
  await waitFor("document.querySelector('#home-inbox #mail-threads')?.getAttribute('aria-busy') === 'false'", "Home opens an account without workspace membership")
  assert.equal(await evaluate("document.querySelector('#mail-heading').textContent.trim()"), "unattached@example.test")
  assert.equal(await evaluate("Array.from(document.querySelectorAll('#mail-panel button')).some(button => button.textContent.trim() === 'Home')"), false, "inbox has no redundant Home button")
  await click("#home-link")
  await home()
  await click(`#open-home-account-${accountId}`)
  await waitFor("!!document.querySelector('#home-inbox #mail-account-view') && document.activeElement.id === 'directory-heading'", "reopen inbox and heading focus for keyboard Home")
  await evaluate("document.querySelector('#home-link').focus()")
  assert.equal(await evaluate("document.activeElement.id"), "home-link")
  await key("Enter")
  await home()
  await waitFor("document.activeElement.id === 'directory-heading'", "keyboard Home transfers heading focus")
  await openGmailConnections()
  assert.equal(await evaluate("!!document.querySelector('#back-from-connections')"), false, "Connections has no redundant Home button")
  assert.equal(await evaluate("document.querySelectorAll('.gmail-connection-list > .gmail-connection-card').length"), 5, "five Gmail accounts use compact rows")
  assert.equal(await evaluate("!!document.querySelector('#mail-connect-new')"), false, "new Gmail form stays out of the connection list")
  await click("#new-gmail-connection")
  await waitFor("document.querySelector('#gmail-connection-modal')?.matches(':modal') && document.activeElement.id === 'mail-workspace-new'", "Gmail modal focuses receiving workspace")
  assert.equal(await evaluate("document.querySelector('#mail-connect-new').checkValidity()"), false, "a receiving workspace is required")
  await evaluate(`(() => {
    const select = document.querySelector('#mail-workspace-new');
    select.value = ${JSON.stringify(workspaceId)};
    select.dispatchEvent(new Event('change', {bubbles: true}));
  })()`)
  assert.equal(await evaluate("document.querySelector('#mail-workspace-new').value"), workspaceId, "receiving workspace choice is explicit")
  assert.equal(await evaluate("document.querySelector('#mail-connect-new').checkValidity()"), true)
  assert.equal(await evaluate("document.querySelector('#mail-connect-new').getAttribute('action')"), "/oauth/google/start", "OAuth remains an explicit ordinary POST")
  await key("Escape")
  await waitFor("!document.querySelector('#gmail-connection-modal') && document.activeElement.id === 'new-gmail-connection'", "Gmail Escape closes only modal and restores Add button")
  await focused()
  await click("#new-gmail-connection")
  await waitFor("document.querySelector('#gmail-connection-modal')?.matches(':modal')", "reopen Gmail modal")
  assert.equal(await evaluate("document.querySelector('#mail-workspace-new').value"), "", "reopening requires explicit workspace choice")
  await click("#gmail-connection-modal button[type=button]")
  await waitFor("!document.querySelector('#gmail-connection-modal') && document.activeElement.id === 'new-gmail-connection'", "Gmail Cancel restores Add button")
  console.log("PASS five-account Connections list and new Gmail modal, workspace choice and Escape/Cancel focus")
  assert.equal(await evaluate("!!document.querySelector('#gemini-connection')"), false, "Gmail mounts only after choosing its provider")
  await evaluate("document.querySelector('#connections-gemini').focus()")
  await key("Enter")
  await waitFor("!!document.querySelector('#gemini-connection') && !document.querySelector('#connections-panel')", "keyboard provider navigation shows Gemini only")
  assert.equal(await evaluate("document.activeElement.id"), "connections-gemini", "provider switching keeps keyboard focus on navigation")
  assert.equal(await evaluate("document.querySelector('#connections-gemini').getAttribute('aria-current')"), "page")
  assert.equal(await evaluate("document.querySelector('#connections-gmail').hasAttribute('aria-current')"), false)
  await key("Escape")
  await landscape()
  await key("a", "a")
  await focused()
  assert.equal(await evaluate("!!document.querySelector('#gemini-connection') && !document.querySelector('#connections-panel')"), true, "scenery wake preserves the provider view")
  await waitFor("document.querySelector('#gemini-status')?.textContent.includes('API key stored') && !document.querySelector('#gemini-status')?.textContent.includes('No API key stored')", "separate synthetic Gemini key presence")
  assert.equal(await evaluate("document.querySelector('#gemini-key-form').hasAttribute('phx-submit') || document.querySelector('#gemini-key-form').hasAttribute('phx-change')"), false, "credentials never enter LiveView events")
  await click("#gemini-key-editor summary")
  await click("#gemini-api-key")
  await send("Input.insertText", {text: "synthetic-browser-gemini-key"})
  assert.equal(await evaluate("document.querySelector('#gemini-api-key').type"), "password")
  await media([{name: "prefers-reduced-motion", value: "reduce"}])
  await click("#gemini-key-form button[type=submit]")
  await waitFor("location.pathname === '/connections/gemini' && document.querySelector('#gemini-api-key')?.value === '' && document.querySelector('#gemini-status')?.textContent.includes('API key stored') && !document.querySelector('#gemini-status')?.textContent.includes('No API key stored')", "Gemini save POST completes at canonical Connections URL with an empty form")
  await focused()
  assert.equal(await evaluate("document.querySelector('#gemini-api-key').value"), "", "stored key is not returned to the form")
  assert.equal(await evaluate("!!document.querySelector('#connections-panel')"), false, "credential POST returns to the Gemini provider view")
  assert.equal(await evaluate("document.querySelector('#gemini-status').textContent.includes('Google access not verified')"), true)
  assert.equal(await evaluate("document.querySelector('#gemini-connection').textContent.includes('Startup generation is disabled')"), true)
  await send("Page.navigate", {url: origin + "/"})
  await waitFor("!!document.querySelector('#home-accounts') && window.liveSocket?.getSocket().isConnected()", "connected Home after Gemini management reload")
  await click("#workspace-pane")
  await focused()
  await media([])
  console.log("PASS separate app-wide Gemini Keychain UI, ordinary credential POST, empty return form and truthful unverified/startup state")
  await click("#home-link")
  await home()
  await openGmailConnections()
  await click("#home-link")
  await home()
  await click("#show-workspaces")
  await waitFor(`!!document.querySelector('#open-${workspaceId}') && document.activeElement.id === 'directory-heading'`, "explicit workspace directory navigation")
  console.log("PASS local daily orientation, per-account counts/memberships, Home inbox, Escape/idle preservation and mouse/keyboard Home")

  await click(`#workspace-menu-${workspaceId} summary`)
  assert.equal(await evaluate(`document.querySelector('#workspace-menu-${workspaceId}').open`), true)
  await click(`#rename-${workspaceId}`)
  await waitFor("document.querySelector('#workspace-modal')?.matches(':modal') && document.activeElement.id === 'workspace-name'", "native rename modal and field focus")
  assert.equal(await evaluate("document.querySelector('#workspace-modal').getAttribute('aria-labelledby')"), "workspace-modal-title")
  assert.equal(await evaluate("(() => { document.querySelector('#owner-lock-form button').focus(); return document.activeElement.id === 'workspace-name'; })()"), true, "native modal makes outside controls inert")
  for (let index = 0; index < 6; index++) {
    await key("Tab")
    assert.equal(await evaluate("document.activeElement === document.body || document.querySelector('#workspace-modal').contains(document.activeElement)"), true, "native Tab stays within the modal, not outside controls")
  }
  await evaluate("document.querySelector('#workspace-name').focus()")
  await evaluate("(() => { const input = document.querySelector('#workspace-name'); input.setSelectionRange(input.value.length, input.value.length); })()")
  await send("Input.insertText", {text: " unsaved"})
  await waitFor("document.querySelector('#workspace-name').value.endsWith(' unsaved')", "unsaved input")
  const before = await evaluate("document.querySelector('#workspace-name').value")
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '0.02'")
  await key("Shift")
  await new Promise(resolve => setTimeout(resolve, 1400))
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), "true", "idle must not reset a modal")
  assert.equal(await evaluate("document.querySelector('#workspace-name').value"), before, "modal idle preserves draft")
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '3'")
  await key("Escape")
  await waitFor(`!document.querySelector('#workspace-modal') && document.activeElement === document.querySelector('#workspace-menu-${workspaceId} summary')`, "Escape closes only modal and restores management focus")
  await focused()
  assert.equal(await evaluate(`document.querySelector('#workspace-menu-${workspaceId}').open`), false)
  await click(`#workspace-menu-${workspaceId} summary`)
  await click(`#rename-${workspaceId}`)
  await waitFor("document.querySelector('#workspace-modal')?.matches(':modal') && document.activeElement.id === 'workspace-name'", "reopened rename modal")
  await click("#workspace-form button[type=button]")
  await waitFor(`!document.querySelector('#workspace-modal') && document.activeElement === document.querySelector('#workspace-menu-${workspaceId} summary')`, "Cancel restores management focus")
  await evaluate("document.querySelector('#workspace-content').scrollTop = 100")
  const scroll = await evaluate("document.querySelector('#workspace-content').scrollTop")
  assert.ok(scroll > 0, "fixture must actually scroll")
  await key("Escape")
  await landscape()
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), scroll)
  await key("a", "a")
  await focused()
  // Only shorten this disposable DOM timer, not persisted/user configuration.
  // Begin focused so removing expiration cannot make an already-idle assertion pass.
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), "true")
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '0.02'")
  await key("Shift") // A fresh activity timestamp schedules the real browser timer.
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), "true")
  await landscape()
  await send("Input.dispatchMouseEvent", {type: "mouseMoved", x: 10, y: 10})
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), "false")
  await evaluate("document.querySelector('#workspace').dataset.idleMinutes = '3'")
  await click("#new-workspace")
  await waitFor("!!document.querySelector('#workspace-form') && document.activeElement.id === 'workspace-name'", "first idle click activates intended control")
  await focused()
  console.log("PASS native modal focus/inertness, Escape isolation, modal idle draft preservation and scenery wake/scroll")
  await send("Input.insertText", {text: "Modal browser workspace"})
  await click("#workspace-form button[type=submit]")
  await waitFor("!document.querySelector('#workspace-modal') && document.activeElement.id === 'new-workspace'", "Create restores New workspace focus after stream update")

  await click(`#open-${workspaceId}`)
  await waitFor("!!document.querySelector('#mail-accounts') && document.activeElement.id === 'directory-heading'", "workspace navigation focus")
  await waitFor(`document.querySelector('#workspace-landing #calendar-agenda-account-${accountId}')?.textContent.includes('Synthetic focus time')`, "workspace shows attached account Calendar")
  assert.equal(await evaluate(`!!document.querySelector('#workspace-landing #calendar-agenda-account-${unattachedId}')`), false, "workspace Calendar excludes unattached Google accounts")
  assert.equal(await evaluate("!!document.querySelector('#workspace-landing #calendar-agenda button[phx-click=\"calendar:refresh\"]')"), true, 'workspace Calendar keeps its Refresh button')
  await calendarItemLayout()
  await click("#add-integration")
  await waitFor("!!document.querySelector('#integration-add-panel')", "Add integration panel")
  await click("#close-add-integration")
  await click("#mail-accounts .mail-account-open")
  await waitFor("document.querySelector('#mail-threads')?.getAttribute('aria-busy') === 'false'", "synthetic inbox")
  assert.equal(await evaluate("!!document.querySelector('#workspace-content #mail-account-view #mail-threads')"), true)
  await click("#show-connections")
  await connectionsOverview()
  await waitFor("document.activeElement.id === 'directory-heading'", "Connections navigation focus")
  await evaluate('history.back()')
  await waitFor("!!document.querySelector('#workspace-landing') && document.activeElement.id === 'directory-heading'", "return to workspace")
  await click("#back-to-workspaces")
  await waitFor(`!!document.querySelector('#open-${workspaceId}')`, "return to directory")
  await click(`#open-${workspaceId}`)
  await waitFor("!!document.querySelector('#workspace-landing')", "workspace before center-nav Home")
  await click("#home-link")
  await home()
  await click("#show-workspaces")
  await waitFor(`!!document.querySelector('#open-${workspaceId}')`, "directory before reload")
  console.log("PASS workspace/integration/Connections navigation, center-nav Home, decorative monogram and real LiveView focus events")

  // Reload really restarts the entrance. Changing preference mid-reveal must
  // finish once and open the actual inert gate, not just a fake hook target.
  failStageImages = true
  await send("Page.reload")
  await waitFor(`location.pathname === '/workspaces' && !!document.querySelector('#workspace-list') && document.querySelector('#workspace-background img')?.dataset.loaded === 'false'`, "reload retains Workspaces with fresh entrance and failed live image")
  await landscape()
  assert.equal(await evaluate("document.querySelector('#workspace-content').inert"), true)
  assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-background img')).opacity"), "0")
  await bundledBackground('#workspace-background')
  failStageImages = false
  await click("#workspace-pane")
  await media([{name: "prefers-reduced-motion", value: "reduce"}])
  await focused()
  await click('#home-link')
  await home()
  await media([])
  await key("Escape")
  await landscape()
  await key("a", "a")
  await focused()

  for (const forced of [false, true]) {
    await media([
      {name: "prefers-reduced-motion", value: "reduce"},
      {name: "forced-colors", value: forced ? "active" : "none"},
    ])
    for (const width of [1440, 390]) {
      await send("Emulation.setDeviceMetricsOverride", {width, height: 1000, deviceScaleFactor: 1, mobile: false})
      await focused()
      await click("#home-link")
      await home()
      assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true, "Home has no horizontal overflow")
      const homeDimensions = await evaluate(`(() => {
        const row = document.querySelector('#open-home-account-${accountId}').getBoundingClientRect();
        const button = document.querySelector('#home-link').getBoundingClientRect();
        const content = document.querySelector('#home-readouts').getBoundingClientRect();
        return {rowWidth: row.width, rowHeight: row.height, homeWidth: button.width, homeHeight: button.height, contentWidth: content.width, contentLeft: content.left};
      })()`)
      assert.ok(homeDimensions.rowWidth > 200 && homeDimensions.rowHeight >= 44 && homeDimensions.homeWidth >= 44 && homeDimensions.homeHeight >= 44,
        `usable Home targets at ${width}px (forced colors: ${forced}): ${JSON.stringify(homeDimensions)}`)
      await waitFor("document.querySelector('#calendar-agenda')?.textContent.includes('Synthetic focus time')", "Calendar remains available after navigation")
      await homeLayout(width, forced)
      const directorySpacing = await evaluate(`(() => {
        const directory = document.querySelector('.workspace-directory').getBoundingClientRect();
        const nav = document.querySelector('.workspace-topline').getBoundingClientRect();
        return directory.top - nav.bottom;
      })()`)
      assert.ok(directorySpacing >= 20 && directorySpacing <= 40, 'shared content starts close to navigation without crowding it')
      if (width === 390 && !forced) await screenshot('home-narrow')
      if (width === 390) await evaluate("document.querySelector('#calendar-agenda').scrollIntoView({block:'center'})")
      assert.equal(await evaluate("document.querySelector('#calendar-agenda').scrollWidth <= document.querySelector('#calendar-agenda').clientWidth"), true, "Calendar agenda has no horizontal overflow")
      if (width === 390 && !forced) await screenshot("calendar-home-narrow")
      if (width === 1440 && forced) await screenshot("calendar-home-forced-colors")
      await click(`#open-home-account-${accountId}`)
      await waitFor("document.querySelector('#home-inbox #mail-threads')?.getAttribute('aria-busy') === 'false'", "inbox for search layout checks")
      const searchDimensions = await evaluate(`(() => {
        const input = document.querySelector('#mail-search input');
        const button = document.querySelector('#mail-search button');
        const identity = document.querySelector('.mail-inbox-heading .mail-account-identity').getBoundingClientRect();
        const form = document.querySelector('#mail-search').getBoundingClientRect();
        const field = input.getBoundingClientRect();
        const submit = button.getBoundingClientRect();
        const pane = document.querySelector('#workspace-content');
        return {gap: submit.left - field.right, inputHeight: field.height, buttonHeight: submit.height,
          inputFont: getComputedStyle(input).fontSize, buttonFont: getComputedStyle(button).fontSize,
          identityRight: identity.right, identityBottom: identity.bottom, searchLeft: form.left, searchTop: form.top,
          overflow: pane.scrollWidth > pane.clientWidth};
      })()`)
      assert.ok(Math.abs(searchDimensions.gap) < 1 && Math.abs(searchDimensions.inputHeight - searchDimensions.buttonHeight) < 1,
        `search input/button touch and match heights: ${JSON.stringify(searchDimensions)}`)
      assert.equal(searchDimensions.inputFont, searchDimensions.buttonFont, "search input/button font sizes match")
      assert.ok(searchDimensions.buttonHeight >= 44, "search remains a usable target")
      assert.equal(searchDimensions.overflow, false, "inbox has no horizontal overflow")
      const inboxRowHeight = await evaluate("document.querySelector('.mail-thread').getBoundingClientRect().height")
      assert.ok(inboxRowHeight >= 80 && inboxRowHeight <= 104, 'compact inbox rows retain sender, subject and preview')
      if (!forced) await screenshot(`inbox-${width}`)
      assert.ok(width > 800 ? searchDimensions.searchLeft >= searchDimensions.identityRight : searchDimensions.searchTop >= searchDimensions.identityBottom,
        `identity/search split on desktop and stack on narrow screens: ${JSON.stringify(searchDimensions)}`)
      assert.equal(await evaluate("document.querySelector('#mail-search input').getAttribute('aria-label')"), "Search Gmail")
      // Distinct uncached threads exercise actual loading at every preference/width.
      const threadNumber = (forced ? 16 : 14) + (width === 390 ? 1 : 0)
      await click(`#mail-thread-synthetic-thread-${threadNumber}`)
      await loadingStatus(forced, true)
      await readerLoaded()
      await readerLayout(width, forced)
      if (!forced) await screenshot(`reader-${width}`)
      if (forced) {
        await evaluate("document.querySelector('#mail-message-synthetic-message-1 > summary.mail-message-summary').focus()")
        await key("Enter")
        await waitFor("document.querySelector('#mail-message-synthetic-message-1').open", "forced-color keyboard disclosure")
        assert.notEqual(await evaluate("getComputedStyle(document.activeElement).outlineStyle"), "none", "forced-color reader retains a visible keyboard focus outline")
      }
      await click('#show-connections')
      await connectionsOverview()
      if (!forced) await screenshot(width === 390 ? 'connections-overview-narrow' : 'connections-overview-layout-desktop')
      await click('#open-connection-gmail')
      await waitFor("!!document.querySelector('#connections-panel')", "Gmail Connections for shared width check")
      const connectionBounds = await evaluate(`(() => {
        const content = document.querySelector('#connections-panel').getBoundingClientRect();
        return {width: content.width, left: content.left};
      })()`)
      assert.ok(Math.abs(connectionBounds.width - homeDimensions.contentWidth) < 1 && Math.abs(connectionBounds.left - homeDimensions.contentLeft) < 1,
        `Home and Connections share the content width and alignment: ${JSON.stringify({home: homeDimensions, connections: connectionBounds})}`)
      const gmailRows = await evaluate(`Array.from(document.querySelectorAll('.gmail-connection-card'), row => {
        const identity = row.querySelector('.connection-identity').getBoundingClientRect();
        const actions = row.querySelector('.mail-actions').getBoundingClientRect();
        return {height: row.getBoundingClientRect().height, sideBySide: actions.left >= identity.right};
      })`)
      assert.equal(gmailRows.length, 5)
      if (width > 800) {
        assert.ok(gmailRows.every(row => row.height <= 100 && row.sideBySide), `compact desktop Gmail rows: ${JSON.stringify(gmailRows)}`)
      }
      assert.equal(await evaluate("document.querySelector('#connections-panel').scrollWidth <= document.querySelector('#connections-panel').clientWidth"), true, "Gmail rows do not overflow their container")
      assert.equal(await evaluate("document.querySelector('#gmail-disconnect-help').open"), false, 'occasional disconnect guidance starts collapsed')
      await evaluate("document.querySelector('#gmail-disconnect-help summary').focus()")
      await key('Enter')
      assert.equal(await evaluate("document.querySelector('#gmail-disconnect-help').open"), true, 'disconnect help is keyboard accessible')
      assert.match(await evaluate("document.querySelector('#gmail-disconnect-help').textContent"), /mailbox is unchanged/)
      if (!forced) await screenshot(`gmail-connections-${width}`)
      await statusDetails(width, forced)
      await waitFor("document.querySelector('#new-gmail-connection')?.disabled === false", "Google client diagnostic enables Gmail admission")
      await click("#new-gmail-connection")
      await waitFor("document.querySelector('#gmail-connection-modal')?.matches(':modal') && document.activeElement.id === 'mail-workspace-new'", "Gmail modal at each width/preference")
      assert.equal(await evaluate("document.querySelector('#gmail-connection-modal').scrollWidth <= document.querySelector('#gmail-connection-modal').clientWidth"), true, "Gmail modal has no horizontal overflow")
      assert.equal(await evaluate("document.querySelector('#mail-workspace-new').getBoundingClientRect().height >= 44"), true)
      await key("Escape")
      await waitFor("!document.querySelector('#gmail-connection-modal') && document.activeElement.id === 'new-gmail-connection'", "Gmail modal keyboard dismissal at each width/preference")
      await evaluate(`document.querySelector('#check-credentials-${accountId}').focus()`)
      await key("Enter")
      await waitFor(`document.querySelector('#credential-check-${accountId}')?.textContent.includes('Credential readable')`, "keyboard local Gmail credential check")
      assert.equal(await evaluate(`document.querySelector('#credential-check-${accountId}').getAttribute('role')`), "status")
      assert.equal(await evaluate(`document.querySelector('#credential-check-${accountId}').textContent.includes('Google access not checked')`), true)
      assert.equal(await evaluate(`document.querySelector('#credential-check-${accountId} time').hasAttribute('datetime')`), true)
      assert.equal(await evaluate("document.querySelector('#connections-panel').textContent.includes('synthetic-refresh')"), false, "credential never reaches browser")
      await click("#check-credentials-00000000-0000-4000-8000-000000000005")
      await waitFor("document.querySelector('#credential-check-00000000-0000-4000-8000-000000000005')?.textContent.includes('(locked)')", "Gmail item access denial is distinct from an absent credential")
      assert.equal(await evaluate("document.querySelector('#credential-check-00000000-0000-4000-8000-000000000005').textContent.includes('An unlocked keychain can still deny this item')"), true)
      await click("#gmail-keychain-help summary")
      assert.equal(await evaluate("document.querySelector('#gmail-keychain-help').open"), true)
      const priorCheckTime = await evaluate(`document.querySelector('#credential-check-${accountId} time').getAttribute('datetime')`)
      await click(`#check-credentials-${accountId}`)
      await waitFor(`document.querySelector('#credential-check-${accountId} time')?.getAttribute('datetime') !== ${JSON.stringify(priorCheckTime)} && !!document.querySelector('#credential-check-${accountId} time')`, "explicit repeat check records a new observation")
      assert.equal(await evaluate("document.querySelector('#gmail-keychain-help').open"), true, "Keychain help survives diagnostic patches")
      assert.equal(await evaluate("document.querySelector('#gmail-disconnect-help').open"), true, 'disconnect disclosure survives diagnostic patches')
      assert.equal(await evaluate("document.querySelector('#connections-panel').scrollWidth <= document.querySelector('#connections-panel').clientWidth"), true, "credential diagnostics and help do not overflow")
      const providerNav = await evaluate(`(() => {
        const heading = document.querySelector('#directory-heading').getBoundingClientRect();
        const nav = document.querySelector('#connections-subnav').getBoundingClientRect();
        return {sameRow: nav.top < heading.bottom && nav.bottom > heading.top,
          label: document.querySelector('#connections-subnav').getAttribute('aria-label')};
      })()`)
      assert.equal(providerNav.label, "Connection providers")
      if (width >= 640) assert.equal(providerNav.sameRow, true, "provider subnav shares the desktop Connections title row")
      else assert.equal(providerNav.sameRow, false, "provider navigation wraps below the heading on narrow screens")
      await click("#connections-google")
      await waitFor("!!document.querySelector('#google-connection') && !document.querySelector('#connections-panel, #calendar-connections, #gemini-connection')", "Google provider excludes other connection forms")
      await evaluate("document.querySelector('#google-client-editor summary').focus()")
      await key('Enter')
      assert.equal(await evaluate("document.querySelector('#google-client-editor').open"), true, "client editor opens from keyboard")
      assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true, "Google client editor fits each viewport")
      assert.equal(await evaluate("document.querySelector('#google-client-form').hasAttribute('phx-submit')"), false, "credentials use an ordinary POST")
      if (!forced) await screenshot(`google-connection-${width}`)
      await click("#connections-calendar")
      await waitFor("!!document.querySelector('#calendar-connections') && !document.querySelector('#connections-panel, #gemini-connection')", "Calendar only at each width/preference")
      assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth && document.querySelector('#calendar-connections').scrollWidth <= document.querySelector('#calendar-connections').clientWidth"), true, "Calendar Connections has no horizontal overflow")
      await evaluate("document.querySelector('#calendar-connections-disconnect-help summary').focus()")
      await key('Enter')
      assert.equal(await evaluate("document.querySelector('#calendar-connections-disconnect-help').open"), true, 'shared Google connection help is keyboard accessible')
      assert.match(await evaluate("document.querySelector('#calendar-connections-disconnect-help').textContent"), /every workspace/)
      if (width === 390 && !forced) await screenshot("calendar-connections-narrow")
      if (width === 1440 && forced) await screenshot("calendar-connections-forced-colors")
      await click("#connections-gemini")
      await waitFor("!!document.querySelector('#gemini-connection') && !document.querySelector('#connections-panel')", "Gemini only at each width/preference")
      assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true, "provider subnav/Gemini has no horizontal overflow")
      await waitFor("!document.querySelector('#gemini-status').textContent.includes('Checking')", 'Gemini status settles before disclosure check')
      assert.equal(await evaluate("document.querySelector('#gemini-generation-help').open"), false, 'billing policy starts collapsed')
      assert.equal(await evaluate("document.querySelector('#gemini-generation-help').contains(document.querySelector('#gemini-status'))"), false, 'credential health stays outside help')
      if (!forced) await screenshot(`gemini-compact-${width}`)
      await evaluate("document.querySelector('#gemini-generation-help summary').focus()")
      await key('Enter')
      assert.equal(await evaluate("document.querySelector('#gemini-generation-help').open"), true, 'billing policy opens with keyboard')
      assert.match(await evaluate("document.querySelector('#gemini-generation-help').textContent"), /Each request may incur API charges/)
      await click('#gemini-connection button[phx-click="gemini:check"]')
      await waitFor("!document.querySelector('#gemini-status').textContent.includes('Checking')", 'explicit fake-vault check completes')
      assert.equal(await evaluate("document.querySelector('#gemini-generation-help').open"), true, 'billing disclosure survives status patches')
      assert.equal(await evaluate("document.querySelector('#gemini-generation-help').scrollWidth <= document.querySelector('#gemini-generation-help').clientWidth"), true, 'expanded billing guidance wraps')
      await click("#connections-gmail")
      await waitFor("!!document.querySelector('#connections-panel') && !document.querySelector('#gemini-connection')", "Gmail only at each width/preference")
      await click("#show-scenes")
      await scenesLoaded()
      await scenesLayout(width, forced)
      const beforeSceneDialog = await sceneManifest()
      assert.equal(await evaluate("document.querySelector('#scene-generate').disabled"), false, "unconfirmed dialogs, unrelated credential saves and reloads never reserve generation")
      if (!forced && width === 390) {
        await click('#scene-prompt-preview summary')
        await evaluate("document.querySelector('#scene-direction').scrollIntoView({block: 'start'})")
        await screenshot("scene-direction-narrow")
        await click('#scene-prompt-preview summary')
        await screenshot("scenes-narrow")
      }
      if (forced && width === 1440) await screenshot("scenes-forced-colors")
      await evaluate("document.querySelector('#scenes-refresh').focus()")
      for (const field of ['model', 'aspect_ratio', 'image_size']) {
        await key("Tab")
        assert.equal(await evaluate("document.activeElement.id"), `scene-generation-${field}`, "keyboard reaches each generation setting from read-only Refresh")
      }
      await key("Tab")
      assert.equal(await evaluate("document.activeElement.id"), "scene-generate", "keyboard reaches generation after its settings")
      if (forced) assert.notEqual(await evaluate("getComputedStyle(document.activeElement).outlineStyle"), "none", "forced-color scene controls retain visible keyboard focus")
      await key("Enter")
      await sceneModal()
      const sceneDialogLayout = await evaluate(`(() => {
        const dialog = document.querySelector('#scene-generation-modal');
        const rect = dialog.getBoundingClientRect();
        return {overflow: dialog.scrollWidth > dialog.clientWidth + 1,
          withinViewport: rect.left >= 0 && rect.right <= innerWidth && rect.top >= 0 && rect.bottom <= innerHeight,
          usable: Array.from(dialog.querySelectorAll('button')).every(button => button.getBoundingClientRect().height >= 44)};
      })()`)
      assert.equal(sceneDialogLayout.overflow, false, "scene consent copy and controls wrap without horizontal overflow")
      assert.equal(sceneDialogLayout.withinViewport && sceneDialogLayout.usable, true, `usable scene dialog at ${width}px (forced colors: ${forced})`)
      if (width === 390) await click("#scene-generation-cancel")
      else await key("Escape")
      await waitFor("!document.querySelector('#scene-generation-modal') && document.activeElement.id === 'scene-generate'", "scene cancellation restores Generate at each width/preference")
      await focused()
      await refreshScenes()
      assert.deepEqual(await sceneManifest(), beforeSceneDialog, "narrow/forced-color dialog cancellation and Refresh leave cooldown and selected imagery unchanged")
      await click("#show-workspaces")
      await waitFor(`!!document.querySelector('#open-${workspaceId}')`, "directory for card layout checks")
      const workspaceBounds = await evaluate(`(() => {
        const content = document.querySelector('#workspace-list').getBoundingClientRect();
        return {width: content.width, left: content.left};
      })()`)
      assert.ok(Math.abs(workspaceBounds.width - homeDimensions.contentWidth) < 1 && Math.abs(workspaceBounds.left - homeDimensions.contentLeft) < 1,
        `Home and Workspaces share the content width and alignment: ${JSON.stringify({home: homeDimensions, workspaces: workspaceBounds})}`)
      assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true, "directory has no horizontal overflow")
      const dimensions = await evaluate(`(() => {
        const card = document.querySelector('#open-${workspaceId}').getBoundingClientRect();
        const menu = document.querySelector('#workspace-menu-${workspaceId} summary').getBoundingClientRect();
        const lock = document.querySelector('#owner-lock-form button').getBoundingClientRect();
        return {card: card.width, cardHeight: card.height, menu: menu.width, menuHeight: menu.height, lock: lock.height};
      })()`)
      assert.ok(dimensions.card > 200 && dimensions.menu >= 44 && dimensions.menuHeight >= 44 && dimensions.lock >= 44,
        `usable card/menu/Lock targets at ${width}px (forced colors: ${forced}): ${JSON.stringify(dimensions)}`)
      assert.ok(dimensions.cardHeight >= 120 && dimensions.cardHeight <= 160, 'workspace cards are shallow but retain generous native targets')
      assert.equal(await evaluate("!!document.querySelector('.workspace-card-eyebrow')"), false, 'cards omit the redundant Workspace label')
      if (!forced) await screenshot(`workspaces-${width}`)
      await pinnedControls(width, forced)
      if (width === 1440) {
        await send('Emulation.setDeviceMetricsOverride', {width: 1100, height: 1000, deviceScaleFactor: 1, mobile: false})
        await pinnedControls(1100, forced)
        await send('Emulation.setDeviceMetricsOverride', {width, height: 1000, deviceScaleFactor: 1, mobile: false})
      }
      await statusDetails(width, forced, true)
      if (width === 390) {
        assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-list')).gridTemplateColumns.split(' ').length"), 1)
        await click(`#open-${workspaceId}`)
        await waitFor("!!document.querySelector('#mail-accounts .integration-tile')", "narrow integration tiles")
        const tileHeight = await evaluate("document.querySelector('.integration-tile-open').getBoundingClientRect().height")
        assert.ok(tileHeight >= 120 && tileHeight <= 180, 'integration tile has no oversized reserved space')
        assert.equal(await evaluate("getComputedStyle(document.querySelector('.mail-integration-heading h3')).fontSize"), '18px', 'secondary integration heading stays quiet')
        if (!forced) await screenshot('workspace-detail-narrow')
        const longIdentity = await evaluate(`(() => {
          const name = document.querySelector('.integration-name');
          const original = name.textContent;
          name.textContent = 'long-synthetic-account-identity-for-layout-checks@example.test';
          const menu = document.querySelector('#mail-accounts .workspace-menu summary');
          menu.focus();
          const target = menu.getBoundingClientRect();
          const range = document.createRange(); range.selectNodeContents(name);
          const clear = Array.from(range.getClientRects()).every(rect =>
            rect.bottom <= target.top - 6 || rect.top >= target.bottom + 6 || rect.right <= target.left - 6);
          name.textContent = original;
          return {clear, focused: document.activeElement === menu};
        })()`)
        assert.equal(longIdentity.clear && longIdentity.focused, true, 'long account names clear the focused management target and its outline')
        assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true)
        await click("#mail-accounts .workspace-menu summary")
        assert.equal(await evaluate("document.querySelector('#mail-accounts details').open"), true)
        await click("#show-connections")
        await connectionsOverview()
        assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true)
        await evaluate('history.back()')
        await waitFor("!!document.querySelector('#workspace-landing')", "narrow return workspace")
        await click("#back-to-workspaces")
        await waitFor(`!!document.querySelector('#open-${workspaceId}')`, "narrow return directory")
      }
      await key("Escape")
      await landscape()
      if (forced) {
        assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-content')).filter"), "none")
        assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-content')).opacity"), "1")
        assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-background')).display"), "none")
      }
      await key("a", "a")
      await focused()
    }
  }
  await verifyAccountSwitchFencing()
  await verifyThemes()
  assert.deepEqual(cspViolations, [], "CSP evidence accumulates across all navigations/reloads")
  assert.deepEqual(errors, [])
  assert.deepEqual(external, [])
  console.log("PASS destination reload, reduced motion, forced colors, desktop/narrow Home/card/inbox/reader/Scenes/dialog layout and no off-origin requests/page errors")
  }
} catch (error) {
  console.error(error.message)
  if (socket?.readyState === WebSocket.OPEN) {
    await screenshot("failure").catch(() => console.error("Failure screenshot unavailable"))
    console.error(await evaluate(`JSON.stringify({url: location.pathname + location.search, entered: document.querySelector('#main-content')?.dataset.entered, pressed: document.querySelector('#workspace-pane')?.getAttribute('aria-pressed'), inert: document.querySelector('#workspace-content')?.inert, reduced: matchMedia('(prefers-reduced-motion: reduce)').matches, title: document.title, home: !!document.querySelector('#home-overview'), current: document.querySelector('#home-link')?.getAttribute('aria-current'), inbox: !!document.querySelector('#home-inbox'), active: document.activeElement?.id, heading: document.querySelector('#directory-heading')?.textContent.trim(), sceneBusy: document.querySelector('#scenes-panel')?.getAttribute('aria-busy'), sceneCards: document.querySelectorAll('#scene-gallery > li.scene-card').length, sceneImages: Array.from(document.querySelectorAll('#scene-gallery img'), image => ({id: image.id, loaded: image.dataset.loaded, width: image.naturalWidth}))})`).catch(() => "Browser state unavailable"))
  }
  process.exitCode = 1
} finally {
  socket?.close()
  for (const {reject, timer} of pending.values()) {
    clearTimeout(timer)
    reject(new Error("Browser closed"))
  }
  if (chrome.exitCode === null && chrome.signalCode === null) chrome.kill("SIGTERM")
  let kill
  await Promise.race([
    chromeClosed,
    new Promise(resolve => { kill = setTimeout(() => { chrome.kill("SIGKILL"); resolve() }, 2_000) }),
  ])
  clearTimeout(kill)
  clearTimeout(deadline)
}
