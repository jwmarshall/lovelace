defmodule LovelaceWeb.GoogleComponents do
  @moduledoc "Shared Google Desktop OAuth client settings; account consent stays separate."
  use LovelaceWeb, :html

  attr :status, :atom, required: true

  def connection(assigns) do
    ~H"""
    <section
      id="google-connection"
      class="connection-card gemini-connection empty-state empty-state-card"
      aria-labelledby="google-heading"
    >
      <.icon name="hero-key" class="empty-state-mark size-6" />
      <div class="empty-state-body">
        <div class="mail-account-identity">
          <p class="mail-eyebrow">Gmail · Calendar · YouTube</p>
          <h3 id="google-heading" class="empty-state-title">
            {if @status == :stored, do: "Google client", else: "Set up Google"}
          </h3>
          <p class="empty-state-copy">
            Use your own Google Cloud Desktop OAuth client for Gmail, Calendar and YouTube.
            These shared settings do not connect an account or grant access.
          </p>
          <p id="google-status" class="mail-muted" role="status">
            <.status_signal
              id="google-credential-signal"
              state={signal_state(@status)}
              label={status_text(@status)}
              text={@status in [:not_connected, :locked, :invalid, :unavailable]}
            />
          </p>
        </div>
        <div class="empty-state-actions gemini-actions">
          <details
            id="google-client-editor"
            class="gemini-key-editor"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary class={["workspace-action", @status != :stored && "workspace-action-primary"]}>
              {if @status == :stored, do: "Replace client settings", else: "Add client settings"}
            </summary>
            <.form
              for={%{}}
              id="google-client-form"
              action="/connections/google"
              method="post"
              autocomplete="off"
              class="gemini-key-form"
            >
              <label for="google-client-id">Client ID</label>
              <input
                id="google-client-id"
                name="client_id"
                type="password"
                class="workspace-name-input"
                required
                maxlength="8192"
                autocomplete="off"
                spellcheck="false"
                autocapitalize="none"
                aria-describedby="google-client-hint"
              />
              <label for="google-client-secret">Client secret</label>
              <input
                id="google-client-secret"
                name="client_secret"
                type="password"
                class="workspace-name-input"
                required
                maxlength="8192"
                autocomplete="off"
                spellcheck="false"
                autocapitalize="none"
                aria-describedby="google-client-hint"
              />
              <p id="google-client-hint" class="mail-muted">
                Stored in the dedicated LOVELACE keychain. Values are never shown again.
                Saving does not contact Google or require a restart.
              </p>
              <button type="submit" class="workspace-action workspace-action-primary">
                Save client settings
              </button>
            </.form>
          </details>
          <button
            type="button"
            class="workspace-action"
            phx-click="google:check"
            disabled={@status == :loading}
          >
            Check Keychain
          </button>
          <a href="/onboarding/project" class="workspace-action workspace-action-link">
            Google setup guide
          </a>
        </div>
        <p :if={@status == :stored} class="empty-state-copy">
          Next, connect an account in
          <.link patch="/connections/gmail" class="workspace-action-link">Gmail</.link>
          and optionally enable
          <.link patch="/connections/calendar" class="workspace-action-link">Calendar</.link>
          or <.link patch="/connections/youtube" class="workspace-action-link">YouTube</.link>.
          Gemini uses a separate API key.
        </p>
      </div>
    </section>
    <details
      id="google-client-help"
      class="connection-help gemini-safety mail-muted"
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary>Google client &amp; account access</summary>
      <p>
        Create a Desktop app client, not a Web application or service account.
        The setup guide covers Google Cloud APIs, consent scopes and publishing settings.
        One client can be reused for several Google accounts and workspaces.
      </p>
      <p>
        Replacing settings with a different client requires accounts to authorize again and clears
        their local Calendar and YouTube snapshots. Saving identical settings preserves access.
        Gmail, Calendar and YouTube each require explicit consent; saving settings does not verify Google access.
      </p>
    </details>
    """
  end

  defp signal_state(:loading), do: :active
  defp signal_state(:stored), do: :ready
  defp signal_state(:unknown), do: :unknown
  defp signal_state(:not_connected), do: :offline
  defp signal_state(_), do: :warning

  defp status_text(:stored), do: "Client settings stored · Google access not verified"
  defp status_text(:not_connected), do: "No client settings stored"
  defp status_text(:locked), do: "Keychain is locked or access was denied"
  defp status_text(:invalid), do: "Stored settings have an invalid format · replace them"
  defp status_text(:loading), do: "Checking Keychain…"
  defp status_text(:unknown), do: "Keychain not checked"
  defp status_text(_), do: "Keychain unavailable · credential state unknown"
end
