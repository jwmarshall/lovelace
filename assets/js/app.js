// Third-party UI libraries are pinned under assets/vendor and bundled locally.
// Preserve their licenses/provenance/checksums; never use runtime CDN imports.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/lovelace"
import topbar from "../vendor/topbar"
import BrandReveal from "./hooks/brand_reveal"
import WorkspaceIdle from "./hooks/workspace_idle"
import NativeModal from "./hooks/native_modal"
import WorkspaceEntrance from "./hooks/workspace_entrance"
import DailyOrientation from "./hooks/daily_orientation"
import {CalendarDay, CalendarEventTime} from "./hooks/calendar_agenda"
import ObservationTime from "./hooks/observation_time"
import StatusSignal from "./hooks/status_signal"
import MailReader from "./hooks/mail_reader"
import {MailDate, MailFreshness} from "./hooks/mail_time"
import StageBackground, {observeStageImage} from "./hooks/stage_background"
import ThemePicker from "./hooks/theme_picker"
import {initOnboardingCalendar} from "./onboarding_calendar"
import {initFirstRunEntrance} from "./first_run_entrance"
import YouTubePlayer from "./hooks/youtube_player"

// Controller-rendered unlock/setup has no LiveView hooks. These observers belong
// only to their image elements and are collected with the document on navigation.
for (const image of document.querySelectorAll("[data-static-stage-image]")) {
  observeStageImage(image, value => image.setAttribute("data-loaded", value))
}
initOnboardingCalendar()
initFirstRunEntrance()

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, YouTubePlayer, StatusSignal, CalendarDay, CalendarEventTime, BrandReveal, WorkspaceIdle, NativeModal, WorkspaceEntrance, StageBackground, DailyOrientation, ObservationTime, MailReader, MailDate, MailFreshness, ThemePicker},
})

// Show progress bar on live navigation and form submits
const configureThemeChrome = () => {
  const styles = getComputedStyle(document.documentElement)
  topbar.config({
    barColors: {0: styles.getPropertyValue("--color-primary").trim()},
    shadowColor: styles.getPropertyValue("--shadow-color").trim(),
  })
  document.querySelector("meta[name='theme-color']").content = styles.getPropertyValue("--color-base-100").trim()
}
configureThemeChrome()
window.addEventListener("lovelace:theme-change", configureThemeChrome)
window.addEventListener("phx:page-loading-start", _info => {
  configureThemeChrome()
  topbar.show(300)
})
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

