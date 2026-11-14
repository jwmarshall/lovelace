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
const artifacts = await mkdtemp(path.join(tmpdir(), "monolith-ui-artifacts-"))
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
let expectedDisconnect = null
const disconnectConfirmations = []
const pending = new Map()
const errors = []
const cspViolations = []
const external = []
const attachmentRequests = []
const deadline = setTimeout(() => {
  console.error("UI browser suite exceeded its 180-second deadline")
  chrome.kill("SIGKILL")
  process.exit(1)
}, 180_000)

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
    try {
      if (await evaluate(expression, session)) return
    } catch (error) {
      // Navigation and a newly attached preview can briefly lack a JS world.
      // Retry only that CDP lifecycle race; page exceptions still fail immediately.
      if (!/Cannot find default execution context|Execution context was destroyed/.test(error.message)) throw error
    }
    await new Promise(resolve => setTimeout(resolve, 25))
  }
  throw new Error(`Timed out: ${label}`)
}

// Advance only this disposable page's wall clock, then deliver the same resume
// observation used after sleep. Production duration validation stays untouched.
async function elapsedIdle() {
  await evaluate(`(() => {
    if (!window.uiIdleClock) {
      window.uiIdleClock = {now: Date.now.bind(Date), elapsed: 0};
      Date.now = () => window.uiIdleClock.now() + window.uiIdleClock.elapsed;
    }
    window.uiIdleClock.elapsed += 61 * 60_000;
    document.dispatchEvent(new Event('visibilitychange'));
  })()`)
}

async function expandSidebar() {
  if (await evaluate("document.querySelector('#sidebar-toggle')?.getAttribute('aria-expanded') === 'false'")) {
    await click('#sidebar-toggle')
    await waitFor("document.querySelector('#sidebar-toggle').getAttribute('aria-expanded') === 'true' && !document.querySelector('#sidebar-content').hidden", 'expanded sidebar')
  }
  // Wait for the push-column transition before measuring native click coordinates.
  await evaluate(`Promise.all(document.querySelector('.workspace-shell').getAnimations()
    .map(animation => animation.finished.catch(() => {}))).then(() => true)`)
}

async function provider(name) {
  await click('#show-connections')
  await connectionsOverview()
  await click('#open-connection-' + name)
}

async function click(selector) {
  if (['#home-link', '#show-workspaces', '#show-connections', '#show-scenes', '#show-settings'].includes(selector)) await expandSidebar()
  const {scrollTop, ...point} = await evaluate(`(async () => {
    // Settle the pending inbox focus/scroll handoff before measuring a native
    // click, just as readerLoaded settles the corresponding reader handoff.
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const element = document.querySelector(${JSON.stringify(selector)});
    if (!element) throw new Error('Missing click target: ' + ${JSON.stringify(selector)});
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
  const space = key === " " ? {code: "Space", windowsVirtualKeyCode: 32, nativeVirtualKeyCode: 32, text: " ", unmodifiedText: " "} : {}
  await send("Input.dispatchKeyEvent", {type: "keyDown", key, modifiers, ...enter, ...space, ...(text ? {text} : {})})
  await send("Input.dispatchKeyEvent", {type: "keyUp", key, modifiers, ...enter, ...space})
}

async function media(features = []) {
  await send("Emulation.setEmulatedMedia", {features})
}

async function screenshot(name) {
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
  await media([{name: 'prefers-reduced-motion', value: 'reduce'}])
  await evaluate(`document.querySelector('#owner-unlock-form input[type=password]').value = 'synthetic browser owner password'; document.querySelector('#owner-unlock-form').requestSubmit()`)
  await waitFor("!!document.querySelector('#home-overview') && window.liveSocket?.getSocket().isConnected()", 'empty installation Home')
  await focused()
  assert.equal(await bundledBackground('#workspace-background'), initial, 'static and live default choices agree')
  assert.equal(await evaluate("!!document.querySelector('#workspace-background img')"), false)
  await screenshot('home-empty-desktop')
  await click('#calendar-agenda .calendar-empty a')
  await waitFor("!!document.querySelector('#calendar-connections')", 'Calendar setup goes directly to its Connections provider')
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
  await waitFor("Array.from(document.querySelectorAll('#github-readouts .github-home-owner-heading .github-home-metric:first-child .github-home-total')).length === 2 && Array.from(document.querySelectorAll('#github-readouts .github-home-owner-heading .github-home-metric:first-child .github-home-total')).every(count => count.textContent.trim() === '1')", 'synthetic owner snapshots repopulate through the protected GitHub queue', 16_000)
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
    document.title === 'Scenes · MONOLITH' &&
    !!document.querySelector('#directory-heading') &&
    document.querySelectorAll('#scene-gallery > li.scene-card').length === ${count} &&
    document.querySelectorAll('#scene-gallery > .scene-card[data-active=true]').length === ${active} &&
    Array.from(document.querySelectorAll('#scene-gallery img')).length === ${count} &&
    Array.from(document.querySelectorAll('#scene-gallery img')).every(image => image.dataset.loaded === 'true' && image.naturalWidth > 0)`, `${count} loaded synthetic scene thumbnails with ${active} active on this page`)
  assert.equal(await evaluate("document.title"), "Scenes · MONOLITH")
  assert.deepEqual(await evaluate("Array.from(document.querySelectorAll('#center-nav [aria-current=page]'), button => button.id)"), ["show-scenes"])
  assert.equal(await evaluate("!!document.querySelector('#home-overview, #home-inbox, #workspace-list, #workspace-landing, #connections-panel, #gemini-connection, #mail-panel')"), false, "Scenes is an exclusive view, not an overlay on mail or Connections")
  assert.equal(await evaluate("document.querySelectorAll('#scene-gallery > .scene-card[data-active=true]').length"), active)
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
    attempts: Array.from(document.querySelectorAll('#scenes-panel .scene-status time'), time => time.dateTime),
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
    return {pageOverflow: document.documentElement.scrollWidth > innerWidth,
      paneOverflow: pane.scrollWidth > pane.clientWidth + 1,
      panelOverflow: panel.scrollWidth > panel.clientWidth + 1,
      galleryOverflow: gallery.scrollWidth > gallery.clientWidth + 1,
      disabledCursors: Array.from(panel.querySelectorAll('button:disabled'), button => getComputedStyle(button).cursor),
      usable: buttons.every(rect => rect.height >= 44 && rect.width >= 44 && rect.left >= 0 && rect.right <= innerWidth),
      forced: matchMedia('(forced-colors: active)').matches};
  })()`)
  assert.equal(layout.pageOverflow || layout.paneOverflow || layout.panelOverflow || layout.galleryOverflow, false,
    `Scenes has no horizontal overflow at ${width}px (forced colors: ${forced}): ${JSON.stringify(layout)}`)
  assert.ok(layout.disabledCursors.every(cursor => cursor === 'default'), 'disabled controls never imply work with a waiting/spinner cursor')
  assert.equal(layout.usable, true, "scene and navigation controls remain usable within the viewport")
  assert.equal(layout.forced, forced)
}

async function focused() {
  await waitFor(`document.querySelector('#main-content')?.dataset.entered === 'true' &&
    document.querySelector('#workspace-pane')?.getAttribute('aria-pressed') === 'true' &&
    getComputedStyle(document.querySelector('#sidebar-toggle')).visibility === 'visible'`, "entered focused workspace")
  assert.equal(await evaluate(`getComputedStyle(document.querySelector('#workspace-pane')).display`), "none")
  assert.equal(await evaluate(`document.querySelector('#workspace-content').inert`), false)
}

async function landscape() {
  await waitFor(`document.querySelector('#workspace-pane')?.getAttribute('aria-pressed') === 'false'`, "landscape mode")
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
    const track = loading.querySelector('.monolith-loading rect');
    return {background: getComputedStyle(status).backgroundColor,
      loadingBackground: getComputedStyle(loading).backgroundColor,
      edge: getComputedStyle(status).borderLeftWidth,
      animation: getComputedStyle(track).animationName,
      hidden: track.closest('svg').getAttribute('aria-hidden'), role: status.getAttribute('role'),
      height: status.getBoundingClientRect().height};
  })()`)
  assert.equal(state.background, "rgba(0, 0, 0, 0)", "loading has no persistent status-panel fill")
  assert.equal(state.loadingBackground, "rgba(0, 0, 0, 0)")
  assert.equal(state.edge, "0px", "loading does not borrow the warning edge")
  assert.equal(state.animation, reduced ? "none" : "monolith-square-cycle", "motion respects user preferences and forced colors")
  assert.equal(state.hidden, "true", "the indeterminate SVG is decorative, not fake percentage progress")
  assert.equal(state.role, "status")
  assert.ok(state.height >= 28)
  return state.height
}

async function statusDetails(width, forced) {
  const selector = '.gmail-connection-card .status-signal'
  const signals = await evaluate(`Array.from(document.querySelectorAll(${JSON.stringify(selector)}), signal => ({
    state: signal.dataset.state, label: signal.querySelector('.status-label')?.textContent.trim(),
    decorative: signal.querySelector('svg')?.getAttribute('aria-hidden'),
    focusable: signal.querySelector('svg')?.getAttribute('focusable'), tab: signal.tabIndex,
    tooltip: !!signal.querySelector('[role=tooltip]'),
    fits: signal.scrollWidth <= signal.clientWidth + 1
  }))`)
  assert.ok(signals.length > 0, 'real account signals are present')
  assert.ok(signals.every(signal => signal.label && signal.decorative === 'true' && signal.focusable === 'false' && signal.tab < 0 && !signal.tooltip && signal.fits),
    `inline labelled decorative signals at ${width}px (forced: ${forced}): ${JSON.stringify(signals)}`)
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
      paneOverflow: pane.scrollWidth > pane.clientWidth + 1,
      pageOverflow: document.documentElement.scrollWidth > innerWidth,
      backHeight: back.height, refreshHeight: refresh.height,
      controlsInPane: back.left >= 0 && refresh.right <= innerWidth,
      forced: matchMedia('(forced-colors: active)').matches};
  })()`)
  assert.equal(dimensions.font, width > 760 ? "18px" : "17px", "reader body type scales for desktop/narrow")
  // Bound the reading measure without pinning a font-specific pixel snapshot.
  assert.ok(width > 800 ? dimensions.width >= 450 && dimensions.width <= 800 : dimensions.width >= 200 && dimensions.width <= width,
    `bounded reading measure at ${width}px (forced colors: ${forced}): ${JSON.stringify(dimensions)}`)
  assert.equal(dimensions.textOverflow || dimensions.readerOverflow || dimensions.paneOverflow || dimensions.pageOverflow, false,
    `long URL and escaped HTML must wrap at ${width}px (forced colors: ${forced})`)
  assert.ok(dimensions.backHeight >= 44 && dimensions.refreshHeight >= 44 && dimensions.controlsInPane, "reader controls remain usable and within the viewport")
  assert.equal(dimensions.forced, forced)
  if (!forced) {
    assert.equal(await evaluate(`Array.from(document.querySelectorAll(
      '#mail-account-view, #mail-conversation, .mail-reader-context, .mail-message'
    )).every(element => getComputedStyle(element).backgroundColor === 'rgba(0, 0, 0, 0)')`), true,
    "conversation and account context retain the study's transparent resting surfaces")
  }
}

async function calendarItemLayout() {
  assert.equal(await evaluate(`Array.from(document.querySelectorAll('#calendar-agenda .calendar-event')).every(item =>
    item.scrollWidth <= item.clientWidth && Array.from(item.querySelectorAll('a')).every(link =>
      link.protocol === 'https:' && ['calendar.google.com', 'www.google.com'].includes(link.hostname) && !link.username && !link.password && !link.port && (link.pathname === '/calendar' || link.pathname.startsWith('/calendar/')) && link.rel === 'noopener noreferrer'))`), true,
    'calendar content wraps and external links retain the safe provider origin and rel')
}

async function verifyHomeRepositories() {
  await evaluate(`Promise.all(document.querySelector('#workspace-content').getAnimations()
    .map(animation => animation.finished.catch(() => {}))).then(() => true)`)
  const ownerIds = await evaluate("[...document.querySelectorAll('#github-readouts .github-home-repository-disclosure')].map(section => section.id)")
  assert.equal(ownerIds.length, 2)
  assert.equal(await evaluate("[...document.querySelectorAll('#github-readouts .github-home-repository-disclosure')].every(section => section.hidden)"), true, 'owner repository sections start collapsed')
  assert.equal(await evaluate("document.querySelectorAll('#github-readouts summary').length"), 0, 'no separate Repositories toggle row')
  assert.equal(await evaluate("document.querySelectorAll('#github-readouts .github-home-workspaces a, #github-readouts .home-section-heading p').length"), 0, 'workspace labels are plain text and the GitHub header has no subtitle')
  assert.equal(await evaluate("[...document.querySelectorAll('#github-readouts .github-home-owner-heading .github-home-metrics')].every(metrics => metrics.getBoundingClientRect().height > 0)"), true, 'overall metrics remain visible while repositories are collapsed')
  assert.equal(await evaluate("document.querySelectorAll('#github-readouts .github-home-repository').length"), 5, 'Home follows selected repositories, not the entire catalog')
  const first = '#' + ownerIds[0]
  const second = '#' + ownerIds[1]
  const firstToggle = '[aria-controls="' + ownerIds[0] + '"]'
  const secondToggle = '[aria-controls="' + ownerIds[1] + '"]'
  await evaluate(`document.querySelector(${JSON.stringify(firstToggle)}).focus()`)
  await key('Enter')
  await waitFor(`!document.querySelector(${JSON.stringify(first)}).hidden`, 'org title keyboard activation opens repositories')
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(firstToggle)}).getAttribute('aria-expanded')`), 'true')
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(second)}).hidden`), true, 'owners expand independently')
  assert.equal(await evaluate("getComputedStyle(document.activeElement).outlineWidth"), '2px', 'keyboard title retains visible focus')
  assert.equal(await evaluate("document.activeElement.getBoundingClientRect().height >= 44"), true, 'title toggle retains a 44px target')
  await click(secondToggle)
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(second)}).hidden`), false)
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(secondToggle)}).getAttribute('aria-expanded')`), 'true')
  await click('.navigation-toggle')
  await evaluate("Promise.all(document.querySelector('.workspace-shell').getAnimations().map(animation => animation.finished.catch(() => {}))).then(() => true)")
  for (const width of [1081, 1080, 800, 761]) {
    await send('Emulation.setDeviceMetricsOverride', {width, height: 1000, deviceScaleFactor: 1, mobile: false})
    assert.equal(await evaluate(`(() => {
      const root = document.querySelector('#github-readouts');
      return root.scrollWidth <= root.clientWidth &&
        [...root.querySelectorAll('.github-home-owner-heading, .github-home-repository')]
          .every(row => row.scrollWidth <= row.clientWidth);
    })()`), true, `org titles and repositories fit expanded navigation at ${width}px`)
  }
  await click('.navigation-toggle')
  await evaluate("Promise.all(document.querySelector('.workspace-shell').getAnimations().map(animation => animation.finished.catch(() => {}))).then(() => true)")
  for (const width of [1440, 1080, 601, 600, 440, 320]) {
    await send('Emulation.setDeviceMetricsOverride', {width, height: 1000, deviceScaleFactor: 1, mobile: false})
    const layout = await evaluate(`(() => {
      const root = document.querySelector('#github-readouts');
      const rows = [...root.querySelectorAll('.github-home-repository')];
      return {fits: root.scrollWidth <= root.clientWidth && rows.every(row => row.scrollWidth <= row.clientWidth),
        quiet: [...root.querySelectorAll('[data-repository-id="QUIET_SYNTHETIC"] .github-home-total')].map(value => value.textContent.trim()),
        names: rows.map(row => row.querySelector('h5').textContent.trim()),
        indented: rows.every(row => row.querySelector('h5 bdi').getBoundingClientRect().left >
          row.closest('article').querySelector('.github-home-owner-toggle bdi').getBoundingClientRect().left)};
    })()`)
    assert.equal(layout.fits, true, `repository identities and metrics fit at ${width}px`)
    assert.equal(layout.indented, true, `repository names are indented beneath their owner at ${width}px`)
    assert.deepEqual(layout.quiet, ['0', '0', '0'], 'unselected quiet repository is absent; whole-owner selection retains its observed zeroes')
    assert.equal(layout.names.filter(name => name.includes('deliberately-long')).length, 2, 'long repository identities remain intact')
    await evaluate("document.querySelector('#github-readouts').scrollIntoView({block:'start'})")
    if ([1440, 320].includes(width)) await screenshot(`github-repositories-${width}`)
  }
  await send('Emulation.setDeviceMetricsOverride', {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false})
  await evaluate(`document.querySelector(${JSON.stringify(firstToggle)}).focus()`)
  await key(' ')
  await waitFor(`document.querySelector(${JSON.stringify(first)}).hidden`, 'Space collapses owner repositories')
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(firstToggle)}).getAttribute('aria-expanded')`), 'false')
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(second)}).hidden`), false, 'collapsing one owner leaves the other open')
  assert.equal(await evaluate("document.querySelectorAll('#github-readouts .github-home-owner-heading .github-home-metrics').length"), 2)
  await click(secondToggle)
  await evaluate("document.querySelector('#github-readouts').scrollIntoView({block:'start'})")
  await screenshot('github-owners-collapsed')
  await send('Emulation.setEmulatedMedia', {media: 'print'})
  assert.equal(await evaluate("[...document.querySelectorAll('#github-readouts .github-home-repository-disclosure')].every(section => getComputedStyle(section).display !== 'none')"), true, 'print media preserves repository content when collapsed')
  await send('Emulation.setEmulatedMedia', {media: ''})
  console.log('PASS Home org-title toggles, selected counts and long-name fit from 320px to desktop')
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
  assert.equal(width > 1200 ? layout.sideBySide : layout.stacked, true, `Home composition at ${width}px: ${JSON.stringify(layout)}`)
  if (width >= 1280) {
    assert.equal(layout.calendarHeadingVisible, true, `Calendar starts alongside Gmail: ${JSON.stringify(layout)}`)
  }
  assert.equal(layout.forced, forced)
  assert.equal(await evaluate(`Array.from(document.querySelectorAll(
    '#home-readouts, #home-overview, #calendar-agenda, .workspace-directory-home .github-plane, #github-readouts'
  )).every(element => getComputedStyle(element).backdropFilter === 'none')`), true,
  'Home Email, Calendar and GitHub readouts add no component-level backdrop blur')
  if (!forced) {
    assert.equal(await evaluate(`Array.from(document.querySelectorAll(
      '#home-readouts, #home-overview, #calendar-agenda, .workspace-directory-home .github-plane, #github-readouts'
    )).every(element => getComputedStyle(element).backgroundColor === 'rgba(0, 0, 0, 0)')`), true,
    'Home Email, Calendar and GitHub readouts have no persistent charcoal fill')
  }
  const metrics = await evaluate(`(() => {
    const labels = [...document.querySelectorAll('#home-overview .home-count > .metric-label, #github-readouts .github-home-metric dt')];
    const typography = labels.map(label => {
      const style = getComputedStyle(label);
      return [style.fontFamily, style.fontSize, style.fontWeight, style.lineHeight, style.letterSpacing, style.textTransform];
    });
    return {typography, aboveCounts: [...document.querySelectorAll('#home-overview .home-count')].every(metric =>
      metric.querySelector('.metric-label').getBoundingClientRect().bottom <= metric.querySelector('b').getBoundingClientRect().top)};
  })()`)
  assert.ok(metrics.typography.length > 0)
  for (const typography of metrics.typography) {
    assert.deepEqual(typography, metrics.typography[0], 'Gmail and GitHub metric labels share font and line height')
  }
  assert.equal(metrics.aboveCounts, true, 'Gmail labels sit above their counts')
  await calendarItemLayout()
}

async function connectionsOverview() {
  await waitFor("location.pathname === '/connections' && location.search === '' && !!document.querySelector('#connections-overview')", 'global Connections overview URL')
  assert.equal(await evaluate("document.querySelector('#show-connections').getAttribute('href')"), '/connections')
  assert.equal(await evaluate("!!document.querySelector('#google-connection, #connections-panel, #calendar-connections, #gemini-connection, #back-from-connections')"), false, 'overview mounts no provider or workspace return')
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
  await click('#mail-back')
  await waitFor("document.querySelector('#mail-threads')?.getAttribute('aria-busy') === 'false'", 'direct-reader fallback to results')
  assert.equal(await evaluate('location.pathname + location.search'), `/accounts/${accountId}/mail?q=synthetic&page_token=fixture-page`)
  assert.equal(await evaluate("document.querySelector('#mail-search input').value"), 'synthetic')
  await screenshot('navigation-deep-link-results')
  await send('Page.navigate', {url: origin + '/accounts/00000000-0000-4000-8000-000000000099/mail'})
  await waitFor("location.pathname === '/workspaces' && !!document.querySelector('#workspace-list') && !!document.querySelector('#flash-error')", 'unavailable account link visibly canonicalizes to Workspaces')
  await click('#workspace-pane')
  await focused()
  await click('#flash-error button')
  await waitFor("!document.querySelector('#flash-error')", 'dismiss unavailable-account notice before Lock')
  await click('#owner-lock-form button')
  await waitFor("location.pathname === '/unlock' && !!document.querySelector('#owner-unlock-form')", 'fixture owner explicitly locks')
  await evaluate('window.navigationBeforeUnlock = true')
  await send('Page.navigate', {url: origin + '/connections/calendar'})
  await waitFor("!window.navigationBeforeUnlock && location.pathname === '/unlock' && !!document.querySelector('#owner-unlock-form')", 'protected deep link requires a fresh unlock page')
  await evaluate("document.querySelector('#owner-unlock-form input[type=password]').value = 'synthetic browser owner password'; document.querySelector('#owner-unlock-form').requestSubmit()")
  await waitFor("location.pathname === '/connections/calendar' && !!document.querySelector('#calendar-connections') && window.liveSocket?.getSocket().isConnected()", 'unlock resumes the requested deep page rather than Home')
  await focused()
  await screenshot('navigation-unlock-return')
  await click('#home-link')
  await home()
  await media([])
  console.log('PASS global Connections overview and provider URLs, obsolete-query cleanup, direct Gemini GET/reload, browser Back/Forward, copied mail links, invalid-account recovery and unlock return')
}

async function verifySidebar() {
  await media([{name: 'prefers-reduced-motion', value: 'reduce'}])
  for (const width of [1440, 761, 760, 390, 320]) {
    await send('Emulation.setDeviceMetricsOverride', {width, height: 1000, deviceScaleFactor: 1, mobile: false})
    const collapsed = await evaluate("document.querySelector('#product-sidebar').getBoundingClientRect().width")
    assert.equal(Math.round(collapsed), width <= 760 ? 48 : 64, 'collapsed column fits shell threshold')
    assert.equal(await evaluate("document.querySelector('#sidebar-content').hidden"), true)
    await expandSidebar()
    const layout = await evaluate(`(() => {
      const sidebar = document.querySelector('#product-sidebar').getBoundingClientRect();
      const view = document.querySelector('.workspace-directory').getBoundingClientRect();
      const toggle = document.querySelector('#sidebar-toggle');
      return {width: sidebar.width, flow: view.top >= sidebar.bottom, beside: view.left >= sidebar.right,
        label: toggle.getAttribute('aria-label'), height: toggle.getBoundingClientRect().height,
        overflow: document.documentElement.scrollWidth > innerWidth,
        links: Array.from(document.querySelectorAll('#center-nav a'), link => [new URL(link.href).pathname, link.getBoundingClientRect().height])};
    })()`)
    assert.equal(layout.label, 'Collapse sidebar')
    assert.ok(layout.height >= 44 && !layout.overflow)
    assert.deepEqual(layout.links.map(([url]) => url), ['/', '/workspaces', '/connections', '/scenes', '/settings'])
    assert.ok(layout.links.every(([,height]) => height >= 44))
    if (width > 760) { assert.equal(Math.round(layout.width), 224); assert.equal(layout.beside, true) }
    else assert.equal(layout.flow, true, 'narrow expanded navigation is above content in normal flow')
    await key('Escape')
    await waitFor("document.querySelector('#sidebar-content').hidden && document.activeElement.id === 'sidebar-toggle'", 'Escape collapses and restores mark focus')
    await focused()
    await screenshot(`sidebar-${width}`)
  }
  await send('Emulation.setDeviceMetricsOverride', {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false})
  await click('#show-workspaces')
  await waitFor("location.pathname === '/workspaces' && document.querySelector('#sidebar-content').hidden && document.activeElement.matches('[data-workspace-heading]')", 'destination collapses navigation and focuses real heading')
  await expandSidebar()
  // A modal wins Escape over expanded navigation; its draft and opener survive.
  await click(`#rename-${workspaceId}`)
  await waitFor("document.querySelector('#workspace-modal')?.matches(':modal')", 'rename while sidebar expanded')
  await send('Input.insertText', {text: ' synthetic draft'})
  await key('Escape')
  await waitFor(`!document.querySelector('#workspace-modal') && document.activeElement.id === 'rename-${workspaceId}'`, 'modal Escape restores visible Rename')
  assert.equal(await evaluate("document.querySelector('#sidebar-toggle').getAttribute('aria-expanded')"), 'true', 'modal Escape does not also collapse sidebar')
  await key('Escape')
  await waitFor("document.querySelector('#sidebar-content').hidden && document.activeElement.id === 'sidebar-toggle'", 'next Escape collapses navigation only')
  await focused()
}

async function verifyPreferences() {
  await click('#show-scenes')
  await scenesLoaded()
  const before = await sceneManifest()
  await click('#show-settings')
  await waitFor("location.pathname === '/settings' && !!document.querySelector('#idle-preference') && !!document.querySelector('#startup-preference')", 'real Settings preferences')
  assert.equal(await evaluate("!!document.querySelector('#theme-picker')"), false, 'working UI has no alternate palette')
  assert.equal(await evaluate("document.documentElement.dataset.theme"), 'charcoal', 'Charcoal is the single working foundation')
  assert.equal(await evaluate("document.querySelector('#startup-preference input[type=checkbox]').checked"), false, 'startup is opt-in by default')
  await evaluate("document.querySelector('#idle-minutes').value = '7'; document.querySelector('#idle-preference').requestSubmit()")
  await waitFor("localStorage.getItem('monolith:idle-minutes') === '7' && document.querySelector('[data-idle-status]').textContent.includes('saved')", 'idle preference persisted in browser')
  await click('#startup-preference input[type=checkbox]')
  await click('#startup-preference button[type=submit]')
  await waitFor("!!document.querySelector('#startup-status')", 'Ash startup preference save acknowledged')
  await send('Page.reload')
  await waitFor("!!document.querySelector('#startup-preference') && window.liveSocket?.getSocket().isConnected()", 'Settings reloaded from persisted state')
  await click('#workspace-pane')
  await focused()
  assert.equal(await evaluate("document.querySelector('#idle-minutes').value"), '7')
  assert.equal(await evaluate("document.documentElement.dataset.theme"), 'charcoal')
  assert.equal(await evaluate("document.querySelector('#startup-preference input[type=checkbox]').checked"), true, 'startup opt-in survives actual reload')
  assert.match(await evaluate("document.querySelector('#startup-preference').textContent"), /blocked by the terminal configuration/)
  await click('#show-scenes')
  await scenesLoaded()
  assert.deepEqual(await sceneManifest(), before, 'saving preferences and reload never submit generation, reserve attempts or replace scenery')
  await click('#show-settings')
  await waitFor("!!document.querySelector('#startup-preference')", 'Settings before restore')
  await click('#startup-preference input[type=checkbox]')
  await click('#startup-preference button[type=submit]')
  await waitFor("!!document.querySelector('#startup-status')", 'startup restored off')
  await evaluate("document.querySelector('#idle-minutes').value = '3'; document.querySelector('#idle-preference').requestSubmit()")
  await send('Page.reload')
  await waitFor("!!document.querySelector('#startup-preference') && window.liveSocket?.getSocket().isConnected()", 'restored startup preference reload')
  assert.equal(await evaluate("document.querySelector('#startup-preference input[type=checkbox]').checked"), false)
  await click('#workspace-pane')
  await focused()
  await click('#home-link')
  await home()
  console.log('PASS real idle and startup persistence, environment veto and no generation on save')
}

async function verifyDisconnect() {
  await openGmailConnections()
  const fixture = await evaluate(`(() => {
    const row = Array.from(document.querySelectorAll('.gmail-connection-card')).find(row => row.textContent.includes('secondary-3@example.test'));
    const button = row.querySelector('button[phx-click="mail:disconnect"]');
    return {id: button.getAttribute('phx-value-id'), email: 'secondary-3@example.test'};
  })()`)
  expectedDisconnect = fixture.email
  try {
    await click(`button[phx-click="mail:disconnect"][phx-value-id="${fixture.id}"]`)
    await waitFor(`!document.querySelector('#check-credentials-${fixture.id}') &&
      Array.from(document.querySelectorAll('.gmail-connection-card')).filter(row => row.textContent.includes('${fixture.email}')).every(row => row.textContent.includes('Disconnected locally'))`,
      'synthetic disconnect removes credential access and publishes explicit local state')
    assert.deepEqual(disconnectConfirmations, [fixture.email], 'only the named synthetic global disconnect was confirmed')
    assert.equal(await evaluate(`!!document.querySelector('#check-credentials-${accountId}')`), true, 'disconnect is isolated from the primary account')
  } finally { expectedDisconnect = null }
  await click('#home-link')
  await home()
}

async function verifyGitHubActivity() {
  await click('#home-link')
  await home()
  assert.equal(await evaluate("document.querySelectorAll('#github-readouts .github-home-workspaces a').length"), 0)
  await click('#show-workspaces')
  await waitFor(`!!document.querySelector('#open-${workspaceId}')`, 'workspace directory for owner activity')
  await click(`#open-${workspaceId}`)
  const selector = '#workspace-github a[href*="/github/"]'
  await waitFor(`!!document.querySelector(${JSON.stringify(selector)})`, 'workspace offers owner activity')
  const route = await evaluate(`new URL(document.querySelector(${JSON.stringify(selector)}).href).pathname`)
  await click(selector)
  await waitFor("!!document.querySelector('#github-owner-activity')", 'actual owner activity page')
  assert.equal(await evaluate('location.pathname'), route)
  assert.equal(await evaluate("document.querySelector('#show-workspaces').getAttribute('aria-current')"), 'page')
  await send('Page.reload')
  await waitFor("!!document.querySelector('#github-owner-activity') && window.liveSocket?.getSocket().isConnected()", 'GitHub activity deep reload')
  await click('#workspace-pane')
  await focused()
  assert.equal(await evaluate('location.pathname'), route)
  await click('#github-owner-activity a[href=\"/workspaces/' + workspaceId + '\"]')
  await waitFor("!!document.querySelector('#workspace-landing')", 'activity returns to originating workspace')
  await click('#home-link')
  await home()
}

let homeVisits = 0
async function home() {
  await waitFor(`!!document.querySelector('#home-overview') &&
    document.querySelector('#home-link')?.getAttribute('aria-current') === 'page' &&
    document.title === 'Home · MONOLITH'`, `Home overview and title (visit ${++homeVisits})`)
  assert.equal(await evaluate("document.title"), "Home · MONOLITH")
  assert.equal(await evaluate("document.querySelector('#home-link').closest('nav')?.id"), "center-nav", "Home belongs to the sidebar navigation")
  assert.match(await evaluate("document.querySelector('#home-link').textContent.trim()"), /01\s*Home/)
  assert.equal(await evaluate("location.pathname + location.search + location.hash"), "/", "Home has its canonical URL")
  assert.equal(await evaluate("!!document.querySelector('#workspace-list, #home-inbox, #connections-panel, #scenes-panel')"), false)
  assert.equal(await evaluate("[...document.querySelectorAll('#home-overview a')].some(link => link.textContent.includes('Open account inbox'))"), false, 'all account readouts omit the redundant inbox prompt')
  assert.equal(await evaluate("document.querySelectorAll('#home-overview [phx-hook=\"ObservationTime\"]').length"), 0, 'account readouts contain no age/stale indicator, including hidden markup')
  const orientation = await evaluate(`(() => {
    const now = new Date(), date = document.querySelector('#daily-heading [data-daily-date]');
    return {day: document.querySelector('[data-daily-number]').textContent.trim(),
      expectedDay: new Intl.DateTimeFormat(undefined, {day: '2-digit'}).format(now), date: date.getAttribute('aria-label'),
      expectedDate: new Intl.DateTimeFormat(undefined, {weekday: 'long', month: 'long', day: 'numeric'}).format(now),
      iso: date.getAttribute('datetime'), expectedIso: now.getFullYear() + '-' + String(now.getMonth() + 1).padStart(2, '0') + '-' + String(now.getDate()).padStart(2, '0')};
  })()`)
  assert.equal(orientation.day, orientation.expectedDay)
  assert.equal(orientation.date, orientation.expectedDate, 'date uses the browser-local calendar')
  assert.equal(orientation.iso, orientation.expectedIso)
}

async function verifyInboxIdentityFit() {
  const link = await evaluate(`Array.from(document.querySelectorAll('.home-account-open'))
    .find(link => link.querySelector('.home-account-email').textContent === 'longer.address@example.test').id`)
  await click('#' + link)
  await waitFor("document.querySelector('#home-inbox #mail-threads')?.getAttribute('aria-busy') === 'false'", 'long-address inbox')
  await expandSidebar()
  const fit = await evaluate(`(() => {
    const heading = document.querySelector('#mail-heading'), search = document.querySelector('#mail-search');
    const rect = heading.getBoundingClientRect(), form = search.getBoundingClientRect();
    return {height: rect.height, lineHeight: parseFloat(getComputedStyle(heading).lineHeight),
      identityWidth: rect.width, searchWidth: form.width, overflow: document.querySelector('#workspace-content').scrollWidth > document.querySelector('#workspace-content').clientWidth};
  })()`)
  assert.ok(fit.searchWidth <= 320 && fit.identityWidth > fit.searchWidth && fit.height <= fit.lineHeight + 1,
    `expanded navigation preserves the full long address on one line: ${JSON.stringify(fit)}`)
  assert.equal(fit.overflow, false)
  await screenshot('inbox-long-address-expanded-sidebar')
  await send('Emulation.setDeviceMetricsOverride', {width: 320, height: 844, deviceScaleFactor: 1, mobile: false})
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollWidth <= document.querySelector('#workspace-content').clientWidth"), true, 'long identity and search reflow at 320px')
  await screenshot('inbox-long-address-320')
  await send('Emulation.setDeviceMetricsOverride', {width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false})
  await click('#home-link')
  await home()
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
    } else if (message.method === "Page.javascriptDialogOpening") {
      const {type, message: text, url} = message.params
      const accepted = type === 'confirm' && new URL(url).origin === origin && expectedDisconnect !== null &&
        text.includes(expectedDisconnect) && /everywhere/i.test(text)
      if (accepted) disconnectConfirmations.push(expectedDisconnect)
      else errors.push('Unexpected browser confirmation')
      send('Page.handleJavaScriptDialog', {accept: accepted}, message.sessionId).catch(() => {})
    } else if (message.method === "Fetch.requestPaused") {
      const {requestId, request} = message.params
      if (/\/attachments\//.test(request.url)) attachmentRequests.push(request.url)
      if (failStageImages && request.url.startsWith(`${origin}/stage/background/`)) {
        send("Fetch.failRequest", {requestId, errorReason: "Failed"}, message.sessionId).catch(() => {})
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
  await waitFor("!!document.querySelector('#owner-unlock-form') && [...document.querySelectorAll('link[rel=stylesheet]')].some(link => link.sheet)", "styled static unlock")
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
  assert.equal(await evaluate(`(() => {
    const password = document.querySelector('#owner-password').getBoundingClientRect();
    const button = document.querySelector('#owner-unlock-form button').getBoundingClientRect();
    return password.width === button.width && password.left === button.left;
  })()`), true, 'Unlock fills the same width as the password field')
  await evaluate(`document.querySelector('#owner-password').value = 'incorrect synthetic password'; document.querySelector('#owner-unlock-form').requestSubmit()`)
  await waitFor("!!document.querySelector('#owner-unlock-error') && [...document.querySelectorAll('link[rel=stylesheet]')].some(link => link.sheet)", 'styled failed unlock remains on the unlock page')
  assert.equal(await evaluate("document.querySelector('#owner-password').getAttribute('aria-invalid')"), 'true')
  assert.equal(await evaluate("document.querySelector('#owner-password').value"), '')
  await screenshot('failed-unlock')
  await evaluate(`document.querySelector('#owner-unlock-form input[type=password]').value = 'synthetic browser owner password'; document.querySelector('#owner-unlock-form').requestSubmit()`)
  await waitFor(`!!document.querySelector('#home-accounts') && window.liveSocket?.getSocket().isConnected()`, "connected Home after unlock")
  await home()
  assert.equal(await evaluate("document.querySelector('#main-content').dataset.entered ?? 'false'"), "false")
  assert.equal(await evaluate("document.querySelector('#workspace-content').inert"), true)
  assert.equal(await evaluate("getComputedStyle(document.querySelector('#sidebar-toggle')).visibility"), 'hidden')
  await focused()
  await waitFor("document.querySelector('#workspace-background img')?.dataset.loaded === 'true'", "live image hook load")
  assert.equal(await evaluate("document.activeElement.matches('[data-workspace-heading]')"), true)
  console.log("PASS automatic successful-unlock entrance, styled failure, equal control widths and gate/focus handoff")

  await verifyHomeRepositories()
  await verifyGitHubDiscovery()
  await home()
  await verifyNavigationHistory()
  await home()
  assert.equal(await evaluate("document.querySelectorAll('#home-accounts > li').length"), 5, "one Home card per connection, not per membership")
  for (const [id, count, recent] of [[accountId, "7", "3"], [unattachedId, "0", "0"]]) {
    assert.equal(await evaluate(`document.querySelectorAll('#home-account-${id}').length`), 1)
    assert.equal(await evaluate(`document.querySelector('#home-count-${id} .home-count:not(.home-count-recent) b').textContent.trim()`), count)
    assert.equal(await evaluate(`document.querySelector('#home-count-${id} .home-count-recent b').textContent.trim()`), recent)
  }
  const memberships = await evaluate(`document.querySelector('#home-account-${accountId} .home-account-workspaces').textContent`)
  assert.match(memberships, /Browser studio/)
  assert.match(memberships, /Synthetic space 1/)
  assert.match(await evaluate(`document.querySelector('#home-account-${unattachedId}').textContent`), /Not in a workspace/)
  await verifyInboxIdentityFit()

  await waitFor("document.querySelector('#calendar-agenda')?.textContent.includes('Synthetic focus time')", "browser-local Calendar cache renders")
  assert.equal(await evaluate("document.querySelectorAll('#calendar-agenda .calendar-account').length"), 1, "Calendar remains opt-in per account")
  assert.equal(await evaluate("!!document.querySelector('#calendar-agenda button[phx-click=\"calendar:refresh\"]')"), false, 'Home Calendar has no Refresh button')
  assert.match(await evaluate("document.querySelector('#calendar-agenda').textContent"), /All day/)
  assert.equal(await evaluate("Array.from(document.querySelectorAll('#calendar-agenda .calendar-event-link')).every(link => link.protocol === 'https:' && ['calendar.google.com', 'www.google.com'].includes(link.hostname) && !link.username && !link.password && !link.port && (link.pathname === '/calendar' || link.pathname.startsWith('/calendar/')))"), true)
  assert.equal(await evaluate("document.querySelector('#calendar-agenda a').rel"), "noopener noreferrer")
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

  await expandSidebar()
  await evaluate("document.querySelector('#show-scenes').focus()")
  await key("Enter")
  await scenesLoaded()
  await waitFor("document.activeElement.matches('[data-workspace-heading]')", "keyboard Scenes navigation transfers heading focus")
  const initialScenes = await sceneManifest()
  assert.equal(initialScenes.attempts.length, 1, "fixture exposes its actual last attempt")
  assert.equal(initialScenes.scenes.length, 20, "the first gallery page is bounded to 20 scenes")
  assert.equal(new Set(initialScenes.scenes.map(scene => scene.id)).size, 20)
  assert.ok(initialScenes.scenes.every(scene => Number.isFinite(Date.parse(scene.generatedAt)) && Date.parse(scene.generatedAt) < Date.now() - 86_400_000), "every synthetic scene has an honest generation timestamp older than the cooldown")
  assert.ok(initialScenes.scenes.every((scene, index, scenes) => index === 0 || Date.parse(scenes[index - 1].generatedAt) > Date.parse(scene.generatedAt)), "retained scenes are newest first")
  assert.ok(Date.parse(initialScenes.attempts[0]) > Date.now() - 60_000, 'the failed fixture attempt is recent, not an expired cooldown')
  assert.equal(await evaluate("document.querySelector('#scene-generate').disabled"), false, "manual confirmation remains available immediately after failure, even with startup disabled")
  assert.equal(await evaluate("Array.from(document.querySelectorAll('#scene-gallery > .scene-card')).every(card => { const digest = card.id.slice(6); const image = card.querySelector('img'); const button = card.querySelector('button'); return /^[0-9a-f]{64}$/.test(digest) && image.id === 'scene-preview-' + digest && image.getAttribute('phx-hook') === 'StageBackground' && !!image.alt && button.id === 'use-scene-' + digest && button.disabled === (card.dataset.active === 'true'); })"), true, "digest IDs, loaded hook thumbnails, accessible names and selection availability agree")
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
  assert.equal(await evaluate("(() => { document.querySelector('#sidebar-toggle').focus(); return document.activeElement.id; })()"), "scene-generation-cancel", "native scene dialog prevents focus escaping to navigation")
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
  assert.equal(await evaluate("document.querySelector('#home-link').getAttribute('aria-current')"), "page", "account mail belongs to Home")
  await waitFor("document.activeElement.id === 'mail-heading'", "inbox navigation focus/scroll handoff settles before user scrolling")
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), 0, "fresh inbox navigation keeps the shell's top inset instead of scrolling away the account register")
  assert.equal(await evaluate(`(() => {
    const context = document.querySelector('.mail-register-row').getBoundingClientRect();
    const mark = document.querySelector('#sidebar-toggle').getBoundingClientRect();
    const heading = document.querySelector('#mail-heading').getBoundingClientRect();
    return context.top >= 0 && Math.abs(context.top + context.height / 2 - mark.top - mark.height / 2) <= 1 && heading.top >= context.bottom;
  })()`), true, "account context and Lock remain visible, aligned with the sidebar mark above the inbox heading")
  assert.equal(await evaluate(`(() => {
    const input = document.querySelector('#mail-search input'), button = document.querySelector('#mail-search button');
    const field = input.getBoundingClientRect(), submit = button.getBoundingClientRect();
    return field.width >= 100 && field.height >= 44 && Math.abs(field.right - submit.left) <= 1 &&
      field.height === submit.height && getComputedStyle(input).fontSize === getComputedStyle(button).fontSize &&
      getComputedStyle(input.closest('label')).clipPath === 'none';
  })()`), true, "search is visibly editable with touching, equally sized input and submit controls")
  await send("Input.dispatchMouseEvent", {type: "mouseMoved", x: 0, y: 0})
  assert.equal(await evaluate(`Array.from(document.querySelectorAll(
    '#mail-account-view, #mail-threads, .mail-toolbar, #mail-status, .mail-thread'
  )).every(element => getComputedStyle(element).backgroundColor === 'rgba(0, 0, 0, 0)')`), true,
  "inbox and its rows remain transparent before hover")
  const hoverRow = await evaluate(`(() => {
    const rect = document.querySelector('.mail-thread').getBoundingClientRect();
    return {x: rect.left + rect.width / 2, y: rect.top + rect.height / 2};
  })()`)
  await send("Input.dispatchMouseEvent", {type: "mouseMoved", ...hoverRow})
  assert.deepEqual(await evaluate(`Array.from(document.querySelectorAll('.mail-thread')).slice(0, 2)
    .map(row => getComputedStyle(row).backgroundColor)`),
  ["rgba(18, 23, 21, 0.72)", "rgba(0, 0, 0, 0)"], "only the hovered inbox row gains the study's inset frosting")
  await send("Input.dispatchMouseEvent", {type: "mouseMoved", x: 0, y: 0})
  assert.equal(await evaluate("getComputedStyle(document.querySelector('.mail-thread')).backgroundColor"),
    "rgba(0, 0, 0, 0)", "leaving the row restores its transparent surface")
  await evaluate("document.querySelector('#workspace-content').scrollTop = 100")
  await evaluate("document.querySelector('#mail-search input').focus({preventScroll: true})")
  await send("Input.insertText", {text: "synthetic draft"})
  const inboxScroll = await evaluate("document.querySelector('#workspace-content').scrollTop")
  assert.ok(inboxScroll > 0, "synthetic inbox must really scroll")
  await key("Escape")
  await landscape()
  assert.equal(await evaluate("!!document.querySelector('#home-inbox #mail-account-view')"), true)
  assert.ok(Math.abs(await evaluate("document.querySelector('#workspace-content').scrollTop") - inboxScroll) <= 1, "Escape preserves inbox scroll within CSS-pixel rounding")
  await key("a", "a")
  await focused()
  assert.equal(await evaluate("document.querySelector('#mail-heading').textContent.trim()"), "browser@example.test")
  assert.ok(Math.abs(await evaluate("document.querySelector('#workspace-content').scrollTop") - inboxScroll) <= 1, "wake preserves inbox scroll within CSS-pixel rounding")
  assert.equal(await evaluate("document.querySelector('#mail-search input').value"), 'synthetic drafta', 'first wake key types into the preserved search draft without replay')
  await evaluate("document.querySelector('#mail-search input').value = ''")
  await elapsedIdle()
  await landscape()
  assert.equal(await evaluate("!!document.querySelector('#home-inbox #mail-account-view')"), true)
  assert.ok(Math.abs(await evaluate("document.querySelector('#workspace-content').scrollTop") - inboxScroll) <= 1, "idle preserves inbox scroll within CSS-pixel rounding")
  await key("a", "a")
  await focused()
  assert.equal(await evaluate("document.querySelector('#mail-heading').textContent.trim()"), "browser@example.test")
  assert.ok(Math.abs(await evaluate("document.querySelector('#workspace-content').scrollTop") - inboxScroll) <= 1, "idle wake preserves inbox scroll within CSS-pixel rounding")

  const conversationTitle = await evaluate("document.querySelector('#mail-thread-synthetic-thread-12 .mail-thread-subject').textContent.trim()")
  const resultsContext = await evaluate("document.querySelector('#mail-panel').dataset.mailContext")
  assert.ok(resultsContext, "inbox has an opaque results context")
  const returnScroll = await click("#mail-thread-synthetic-thread-12")
  assert.ok(returnScroll > 100, "open a genuinely scrolled result, capturing after the click helper scrolls it into view")
  const loadingHeight = await loadingStatus(false, false)
  await screenshot('mail-active-signal')
  await media([{name: "prefers-reduced-motion", value: "reduce"}])
  assert.equal(await evaluate("getComputedStyle(document.querySelector('#mail-loading .monolith-loading rect')).animationName"), "none", "mid-load reduced-motion change stops the loading squares")
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
  assert.equal(await evaluate("document.activeElement.matches('[data-mail-latest=\"true\"] > summary')"), true, "latest reply receives keyboard focus")
  assert.equal(await evaluate("getComputedStyle(document.activeElement).outlineStyle"), "none",
    "opening mail with the mouse does not paint a selected message summary")
  assert.equal(await evaluate("(() => { const r = document.activeElement.getBoundingClientRect(); const context = document.querySelector('.mail-reader-context').getBoundingClientRect(); return r.top >= context.bottom && r.bottom <= innerHeight; })()"), true, "focused reply stays visible below account and return context")
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
  assert.equal(await evaluate("getComputedStyle(document.activeElement).outlineStyle"), "solid",
    "native keyboard disclosure interaction retains visible focus")
  assert.equal(await evaluate("getComputedStyle(document.activeElement).outlineWidth"), "2px")
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
  await waitFor("!!document.querySelector('#home-inbox #mail-account-view') && document.activeElement.matches('[data-workspace-heading]')", "reopen inbox and heading focus for keyboard Home")
  await expandSidebar()
  await evaluate("document.querySelector('#home-link').focus()")
  assert.equal(await evaluate("document.activeElement.id"), "home-link")
  await key("Enter")
  await home()
  await waitFor("document.activeElement.matches('[data-workspace-heading]')", "keyboard Home transfers heading focus")
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
  await provider('gemini')
  await waitFor("!!document.querySelector('#gemini-connection') && !document.querySelector('#connections-panel')", 'Gemini provider header replaces Gmail')
  assert.equal(await evaluate("document.querySelector('#directory-heading').tagName"), 'H1')
  assert.equal(await evaluate("document.querySelector('#back-to-connections').getAttribute('href')"), '/connections')
  await key("Escape")
  await landscape()
  await key("a", "a")
  await focused()
  assert.equal(await evaluate("!!document.querySelector('#gemini-connection') && !document.querySelector('#connections-panel')"), true, "scenery wake preserves the provider view")
  await waitFor("document.querySelector('#gemini-status')?.textContent.includes('API key stored') && !document.querySelector('#gemini-status')?.textContent.includes('No API key stored')", "separate synthetic Gemini key presence")
  assert.equal(await evaluate("document.querySelector('#gemini-key-form').hasAttribute('phx-submit') || document.querySelector('#gemini-key-form').hasAttribute('phx-change')"), false, "credentials never enter LiveView events")
  await click("#gemini-key-editor-trigger")
  await waitFor("document.querySelector('#gemini-key-editor')?.matches(':modal') && document.activeElement.id === 'gemini-api-key'", "credential modal opens with key focus")
  await send("Input.insertText", {text: "synthetic-browser-gemini-key"})
  assert.equal(await evaluate("document.querySelector('#gemini-api-key').type"), "password")
  await media([{name: "prefers-reduced-motion", value: "reduce"}])
  await click("#gemini-key-form button[type=submit]")
  await waitFor("location.pathname === '/connections/gemini' && document.querySelector('#gemini-api-key')?.value === '' && document.querySelector('#gemini-status')?.textContent.includes('API key stored') && !document.querySelector('#gemini-status')?.textContent.includes('No API key stored')", "Gemini save POST completes at canonical Connections URL with an empty form")
  await focused()
  assert.equal(await evaluate("document.querySelector('#gemini-api-key').value"), "", "stored key is not returned to the form")
  assert.equal(await evaluate("!!document.querySelector('#connections-panel')"), false, "credential POST returns to the Gemini provider view")
  assert.equal(await evaluate("document.querySelector('#gemini-status').textContent.includes('Google access not verified')"), true)
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
  await waitFor(`!!document.querySelector('#open-${workspaceId}') && document.activeElement.matches('[data-workspace-heading]')`, "explicit workspace directory navigation")
  console.log("PASS local daily orientation, per-account counts/memberships, Home inbox, Escape/idle preservation and mouse/keyboard Home")

  await click(`#rename-${workspaceId}`)
  await waitFor("document.querySelector('#workspace-modal')?.matches(':modal') && document.activeElement.id === 'workspace-name'", "native rename modal and field focus")
  assert.equal(await evaluate("document.querySelector('#workspace-modal').getAttribute('aria-labelledby')"), "workspace-modal-title")
  assert.equal(await evaluate("(() => { document.querySelector('#sidebar-toggle').focus(); return document.activeElement.id === 'workspace-name'; })()"), true, "native modal makes outside controls inert")
  for (let index = 0; index < 6; index++) {
    await key("Tab")
    assert.equal(await evaluate("document.activeElement === document.body || document.querySelector('#workspace-modal').contains(document.activeElement)"), true, "native Tab stays within the modal, not outside controls")
  }
  await evaluate("document.querySelector('#workspace-name').focus()")
  await evaluate("(() => { const input = document.querySelector('#workspace-name'); input.setSelectionRange(input.value.length, input.value.length); })()")
  await send("Input.insertText", {text: " unsaved"})
  await waitFor("document.querySelector('#workspace-name').value.endsWith(' unsaved')", "unsaved input")
  const before = await evaluate("document.querySelector('#workspace-name').value")
  await elapsedIdle()
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), "true", "idle must not reset a modal")
  assert.equal(await evaluate("document.querySelector('#workspace-name').value"), before, "modal idle preserves draft")
  await key("Escape")
  await waitFor(`!document.querySelector('#workspace-modal') && document.activeElement === document.querySelector('#rename-${workspaceId}')`, "Escape closes only modal and restores Rename focus")
  await focused()
  await click(`#rename-${workspaceId}`)
  await waitFor("document.querySelector('#workspace-modal')?.matches(':modal') && document.activeElement.id === 'workspace-name'", "reopened rename modal")
  await click("#workspace-form button[type=button]")
  await waitFor(`!document.querySelector('#workspace-modal') && document.activeElement === document.querySelector('#rename-${workspaceId}')`, "Cancel restores Rename focus")
  await evaluate("document.querySelector('#workspace-content').scrollTop = 100")
  const scroll = await evaluate("document.querySelector('#workspace-content').scrollTop")
  assert.ok(scroll > 0, "fixture must actually scroll")
  await key("Escape")
  await landscape()
  assert.equal(await evaluate("document.querySelector('#workspace-content').scrollTop"), scroll)
  await key("a", "a")
  await focused()
  // Resume after elapsed time reaches the real, validated idle deadline.
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), "true")
  await elapsedIdle()
  await landscape()
  await send("Input.dispatchMouseEvent", {type: "mouseMoved", x: 10, y: 10})
  assert.equal(await evaluate("document.querySelector('#workspace-pane').getAttribute('aria-pressed')"), "false")
  await click("#new-workspace")
  await waitFor("!!document.querySelector('#workspace-form') && document.activeElement.id === 'workspace-name'", "first idle click activates intended control")
  await focused()
  console.log("PASS native modal focus/inertness, Escape isolation, modal idle draft preservation and scenery wake/scroll")
  await send("Input.insertText", {text: "Modal browser workspace"})
  await click("#workspace-form button[type=submit]")
  await waitFor("!document.querySelector('#workspace-modal') && document.activeElement.id === 'new-workspace'", "Create restores New workspace focus after stream update")

  await click(`#open-${workspaceId}`)
  await waitFor("!!document.querySelector('#mail-accounts') && document.activeElement.matches('[data-workspace-heading]')", "workspace navigation focus")
  await waitFor(`document.querySelector('#workspace-landing #calendar-agenda-account-${accountId}')?.textContent.includes('Synthetic focus time')`, "workspace shows attached account Calendar")
  assert.equal(await evaluate(`!!document.querySelector('#workspace-landing #calendar-agenda-account-${unattachedId}')`), false, "workspace Calendar excludes unattached Google accounts")
  assert.equal(await evaluate("!!document.querySelector('#workspace-landing #calendar-agenda button[phx-click=\"calendar:refresh\"]')"), true, 'workspace Calendar keeps its Refresh button')
  await calendarItemLayout()
  await click("#add-integration")
  await waitFor("!!document.querySelector('#integration-add-panel')", "Add integration panel")
  await click("#close-add-integration")
  await waitFor("!document.querySelector('#integration-add-panel') && !!document.querySelector('#mail-accounts .home-account-open')", "workspace integrations restored after closing Add")
  await click("#mail-accounts .home-account-open")
  await waitFor("document.querySelector('#mail-threads')?.getAttribute('aria-busy') === 'false'", "synthetic inbox")
  assert.equal(await evaluate("!!document.querySelector('#workspace-content #mail-account-view #mail-threads')"), true)
  await click("#show-connections")
  await connectionsOverview()
  await waitFor("document.activeElement.matches('[data-workspace-heading]')", "Connections navigation focus")
  await evaluate('history.back()')
  await waitFor("!!document.querySelector('#mail-account-view #mail-threads') && document.activeElement.id === 'mail-heading'", "history returns to the requested workspace inbox")
  await click("#mail-panel .mail-register-row a")
  await waitFor("!!document.querySelector('#back-to-workspaces') && !!document.querySelector('#mail-accounts .home-account-open')", "All accounts returns to the workspace")
  await click("#back-to-workspaces")
  await waitFor(`!!document.querySelector('#open-${workspaceId}')`, "return to directory")
  await click(`#open-${workspaceId}`)
  await waitFor("!!document.querySelector('#workspace-landing')", "workspace before sidebar Home")
  await click("#home-link")
  await home()
  await click("#show-workspaces")
  await waitFor(`!!document.querySelector('#open-${workspaceId}')`, "directory before reload")
  console.log("PASS workspace/integration/Connections navigation, sidebar Home, decorative monogram and real LiveView focus events")

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
        const button = document.querySelector('#sidebar-toggle').getBoundingClientRect();
        const content = document.querySelector('#home-readouts').getBoundingClientRect();
        return {rowWidth: row.width, rowHeight: row.height, homeWidth: button.width, homeHeight: button.height, contentWidth: content.width, contentLeft: content.left};
      })()`)
      assert.ok(homeDimensions.rowWidth > 200 && homeDimensions.rowHeight >= 44 && homeDimensions.homeWidth >= 44 && homeDimensions.homeHeight >= 44,
        `usable Home targets at ${width}px (forced colors: ${forced}): ${JSON.stringify(homeDimensions)}`)
      await waitFor("document.querySelector('#calendar-agenda')?.textContent.includes('Synthetic focus time')", "Calendar remains available after navigation")
      await homeLayout(width, forced)
      if (width === 390 && !forced) await screenshot('home-narrow')
      if (!forced) {
        await evaluate("document.querySelector('#github-readouts').scrollIntoView({block:'start'})")
        await screenshot(`github-home-${width}`)
      }
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
      assert.ok(searchDimensions.buttonHeight >= 44, "search remains a usable target")
      assert.equal(searchDimensions.overflow, false, "inbox has no horizontal overflow")
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
      assert.equal(await evaluate("document.querySelector('#connections-panel').scrollWidth <= document.querySelector('#connections-panel').clientWidth"), true, "Gmail rows do not overflow their container")
      const gmailHelpLayout = await evaluate(`(() => {
        const main = document.querySelector('.provider-main').getBoundingClientRect();
        const aside = document.querySelector('#provider-context-gmail').getBoundingClientRect();
        return {inSidebar: ['gmail-keychain-help', 'gmail-disconnect-help'].every(id =>
          document.getElementById(id)?.closest('#provider-context-gmail')),
          mainRight: main.right, mainBottom: main.bottom, asideLeft: aside.left, asideTop: aside.top};
      })()`)
      assert.equal(gmailHelpLayout.inSidebar, true, 'Gmail Keychain and removal guidance belong in the context sidebar')
      assert.ok(width > 1080 ? gmailHelpLayout.asideLeft >= gmailHelpLayout.mainRight :
        gmailHelpLayout.asideTop >= gmailHelpLayout.mainBottom,
      `Gmail guidance sits right on desktop and below on narrow screens: ${JSON.stringify(gmailHelpLayout)}`)
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
      await provider("google")
      await waitFor("!!document.querySelector('#google-connection') && !document.querySelector('#connections-panel, #calendar-connections, #gemini-connection')", "Google provider excludes other connection forms")
      await evaluate("document.querySelector('#google-client-editor-trigger').focus()")
      await key('Enter')
      assert.equal(await evaluate("document.querySelector('#google-client-editor').open"), true, "client editor opens from keyboard")
      assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true, "Google client editor fits each viewport")
      assert.equal(await evaluate("document.querySelector('#google-client-form').hasAttribute('phx-submit')"), false, "credentials use an ordinary POST")
      if (!forced) await screenshot(`google-connection-${width}`)
      await key('Escape')
      await waitFor("!document.querySelector('#google-client-editor').open && document.activeElement.id === 'google-client-editor-trigger'", "credential Escape restores opener before provider navigation")
      await provider("calendar")
      await waitFor("!!document.querySelector('#calendar-connections') && !document.querySelector('#connections-panel, #gemini-connection')", "Calendar only at each width/preference")
      assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth && document.querySelector('#calendar-connections').scrollWidth <= document.querySelector('#calendar-connections').clientWidth"), true, "Calendar Connections has no horizontal overflow")
      await evaluate("document.querySelector('#calendar-connections-disconnect-help summary').focus()")
      await key('Enter')
      assert.equal(await evaluate("document.querySelector('#calendar-connections-disconnect-help').open"), true, 'shared Google connection help is keyboard accessible')
      assert.match(await evaluate("document.querySelector('#calendar-connections-disconnect-help').textContent"), /every workspace/)
      if (width === 390 && !forced) await screenshot("calendar-connections-narrow")
      if (width === 1440 && forced) await screenshot("calendar-connections-forced-colors")
      await provider("gemini")
      await waitFor("!!document.querySelector('#gemini-connection') && !document.querySelector('#connections-panel')", "Gemini only at each width/preference")
      assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true, "provider subnav/Gemini has no horizontal overflow")
      await waitFor("!document.querySelector('#gemini-status').textContent.includes('Checking')", 'Gemini status settles before disclosure check')
      assert.equal(await evaluate("document.querySelector('#gemini-generation-help').open"), false, 'billing policy starts collapsed')
      assert.equal(await evaluate("document.querySelector('#gemini-generation-help').contains(document.querySelector('#gemini-status'))"), false, 'credential health stays outside help')
      if (!forced) await screenshot(`gemini-compact-${width}`)
      await evaluate("document.querySelector('#gemini-generation-help summary').focus()")
      await key('Enter')
      assert.equal(await evaluate("document.querySelector('#gemini-generation-help').open"), true, 'billing policy opens with keyboard')
      await click('#gemini-connection button[phx-click="gemini:check"]')
      await waitFor("!document.querySelector('#gemini-status').textContent.includes('Checking')", 'explicit fake-vault check completes')
      assert.equal(await evaluate("document.querySelector('#gemini-generation-help').open"), true, 'billing disclosure survives status patches')
      assert.equal(await evaluate("document.querySelector('#gemini-generation-help').scrollWidth <= document.querySelector('#gemini-generation-help').clientWidth"), true, 'expanded billing guidance wraps')
      await provider("gmail")
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
      await evaluate("document.querySelector('#scene-generate').focus()")
      if (forced) {
        // Programmatic focus after a pointer click does not establish keyboard
        // modality. Traverse natively before checking :focus-visible styling.
        await key("Tab", undefined, 8)
        await key("Tab")
        assert.equal(await evaluate("document.activeElement.id"), "scene-generate", "Generate remains reachable by native keyboard traversal")
        assert.notEqual(await evaluate("getComputedStyle(document.activeElement).outlineStyle"), "none", "forced-color scene controls retain visible keyboard focus")
      }
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
        const menu = document.querySelector('#rename-${workspaceId}').getBoundingClientRect();
        const lock = document.querySelector('#sidebar-toggle').getBoundingClientRect();
        return {card: card.width, cardHeight: card.height, menu: menu.width, menuHeight: menu.height, lock: lock.height};
      })()`)
      assert.ok(dimensions.card > 200 && dimensions.menu >= 44 && dimensions.menuHeight >= 44 && dimensions.lock >= 44,
        `usable card/menu/Lock targets at ${width}px (forced colors: ${forced}): ${JSON.stringify(dimensions)}`)
      if (!forced) await screenshot(`workspaces-${width}`)
      if (width === 390) {
        assert.equal(await evaluate("getComputedStyle(document.querySelector('#workspace-list')).gridTemplateColumns.split(' ').length"), 1)
        await click(`#open-${workspaceId}`)
        await waitFor(`!!document.querySelector('#mail-account-${accountId}')`, "narrow account readout")
        if (!forced) await screenshot('workspace-detail-narrow')
        assert.equal(await evaluate("document.documentElement.scrollWidth <= innerWidth"), true)
        await click(`#mail-account-${accountId} a[href="/connections/gmail"]`)
        await waitFor("!!document.querySelector('#connections-panel') && location.pathname === '/connections/gmail'", "account management opens global Gmail connections")
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
  await verifySidebar()
  await verifyGitHubActivity()
  await verifyPreferences()
  await verifyDisconnect()
  assert.deepEqual(cspViolations, [], "CSP evidence accumulates across all navigations/reloads")
  assert.deepEqual(errors, [])
  assert.deepEqual(external, [])
  console.log("PASS destination reload, reduced motion, forced colors, desktop/narrow Home/card/inbox/reader/Scenes/dialog layout and no off-origin requests/page errors")
  }
} catch (error) {
  console.error(error.stack)
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
