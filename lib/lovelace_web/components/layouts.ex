defmodule LovelaceWeb.Layouts do
  @moduledoc """
  Document and workspace layouts shared by LOVELACE's web interface.
  """
  use LovelaceWeb, :html

  alias Lovelace.StageDesigner.BundledScenes

  embed_templates "layouts/*"

  attr :id, :string, required: true
  attr :class, :string, default: nil
  attr :background, :map, default: %{url: nil, status: :ready}
  attr :static, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  # Static owner screens and LiveViews share the same validated local scenery.
  # Static images use the same load observer without requiring a LiveView socket.
  def stage(assigns) do
    assigns =
      assigns
      |> assign(:background_url, local_background_url(assigns.background))
      |> assign(:default_background_url, BundledScenes.default_url())

    ~H"""
    <div id={@id} class={["glass-workspace", @class]} {@rest}>
      <div
        id={"#{@id}-background"}
        class="workspace-background"
        style={"--workspace-default-background: url('#{@default_background_url}')"}
        aria-hidden="true"
      >
        <img
          :if={@background_url}
          id={"stage-background-#{Path.rootname(Path.basename(@background_url))}"}
          class="workspace-background-image"
          src={@background_url}
          alt=""
          phx-hook={if !@static, do: "StageBackground"}
          data-static-stage-image={@static && "true"}
        />
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :class, :string, default: nil
  attr :stroke_id, :string, default: nil

  def monogram(assigns) do
    ~H"""
    <svg
      id={@id}
      class={@class}
      viewBox="0 0 104 104"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
      focusable="false"
    >
      <path
        id={@stroke_id}
        d="M16 82C34 65 64 23 56 12C48 1 33 37 29 63C24 94 41 88 57 70C73 51 89 18 80 12C70 3 56 42 52 66C47 91 62 90 88 71"
        stroke="currentColor"
        stroke-width="1.8"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
    </svg>
    """
  end

  attr :id, :string, default: "workspace-brand"
  attr :static, :boolean, default: false

  def brand(assigns) do
    ~H"""
    <div
      id={@id}
      class="workspace-brand"
      aria-hidden="true"
      phx-hook={if !@static, do: "BrandReveal"}
      phx-update={if !@static, do: "ignore"}
      data-static-brand={@static && "true"}
      hidden={@static}
    >
      <.monogram
        id="lovelace-monogram"
        class="workspace-monogram"
        stroke_id="lovelace-monogram-stroke"
      />
      <p class="workspace-wordmark" aria-label="LOVELACE">
        <span
          :for={{letter, index} <- Enum.with_index(String.graphemes("LOVELACE"))}
          id={"lovelace-letter-#{index}"}
          class="workspace-letter"
        >{letter}</span>
      </p>
    </div>
    """
  end

  attr :flash, :map, required: true
  attr :background, :map, default: %{url: nil, status: :unavailable}
  attr :enter_on_return, :boolean, default: false
  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assign(assigns, :idle_minutes, Application.get_env(:lovelace, :workspace_idle_minutes, 3))

    ~H"""
    <.stage
      id="workspace"
      background={@background}
      phx-hook="WorkspaceIdle"
      data-idle-minutes={@idle_minutes}
      data-workspace-focus={focus_workspace()}
      data-workspace-reset={reset_workspace()}
    >
      <a href="#main-content" class="workspace-skip-link">Skip to workspace</a>
      <p id="stage-background-status" class="sr-only" role="status" aria-live="polite">
        {background_status(@background)}
      </p>
      <main
        id="main-content"
        class="workspace-glass"
        tabindex="-1"
        aria-labelledby="workspace-title"
        phx-hook="WorkspaceEntrance"
        data-enter-on-return={to_string(@enter_on_return)}
        phx-window-keydown={reset_workspace()}
        phx-key="Escape"
      >
        <p id="workspace-instructions" class="sr-only">
          Click or focus the workspace to bring the glass into focus. Press Escape to look
          through to the landscape. After inactivity, the landscape returns; click or type to
          resume your current view. Home summarizes your day; Workspaces organizes your areas of life. Connected
          Gmail accounts remain separate; reading mail never marks it as read.
        </p>
        <button
          id="workspace-pane"
          type="button"
          class="workspace-pane"
          aria-label="Focus workspace"
          aria-describedby="workspace-instructions"
          aria-pressed="false"
          phx-click={focus_workspace()}
          phx-focus={focus_workspace()}
        >
          <span class="sr-only">Focus workspace</span>
        </button>
        {render_slot(@inner_block)}
      </main>
    </.stage>

    <.flash_group flash={@flash} />
    """
  end

  defp focus_workspace do
    JS.set_attribute({"aria-pressed", "true"}, to: "#workspace-pane")
    |> JS.dispatch("lovelace:brand-focus", to: "#workspace-brand")
  end

  defp reset_workspace do
    JS.dispatch("lovelace:player-stop", to: "#workspace")
    |> JS.set_attribute({"aria-pressed", "false"}, to: "#workspace-pane")
    |> JS.dispatch("lovelace:brand-reset", to: "#workspace-brand")
  end

  defp local_background_url(%{url: url}) when is_binary(url) do
    if Regex.match?(~r/\A\/stage\/background\/[0-9a-f]{64}\.(?:png|jpg)\z/, url), do: url
  end

  defp local_background_url(_background), do: nil

  defp background_status(%{status: status}) when status in [:pending, :generating] do
    "Preparing the background. The current landscape remains available."
  end

  defp background_status(%{status: :uncertain}) do
    "The background attempt has no confirmed outcome. The current landscape remains available."
  end

  defp background_status(%{status: status}) when status in [:failed, :error, :unavailable] do
    "Background unavailable. Using the previous image or bundled scenery."
  end

  defp background_status(_background), do: ""

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Connection interrupted")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        <.status_signal
          id="client-reconnect-signal"
          state={:active}
          label={gettext("Attempting to reconnect")}
          text
        />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        <.status_signal
          id="server-reconnect-signal"
          state={:active}
          label={gettext("Attempting to reconnect")}
          text
        />
      </.flash>
    </div>
    """
  end
end
