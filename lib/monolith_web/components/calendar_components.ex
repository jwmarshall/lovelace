defmodule MonolithWeb.CalendarComponents do
  @moduledoc "Read-only, account-separated Calendar presentation from the local cache."
  use MonolithWeb, :html

  attr :accounts, :list, required: true
  attr :accounts_state, :atom, default: :ready
  attr :window, :map, default: nil
  attr :refresh, :integer, default: 0
  attr :id, :string, default: "calendar-agenda"
  attr :home, :boolean, default: false

  def agenda(assigns) do
    # Render-local only: never retain event/provider content in the LiveView socket.
    assigns =
      assign(
        assigns,
        :readouts,
        directory_readouts(assigns.accounts_state, assigns.accounts, assigns.window)
      )

    ~H"""
    <section
      id={@id}
      class="calendar-agenda"
      aria-labelledby={"#{@id}-heading"}
      phx-hook="CalendarEventDialog"
    >
      <header class="home-section-heading">
        <h2 id={"#{@id}-heading"} class="section-register">
          {if @home, do: "02 / Calendar", else: "02 / Today's calendar"}
        </h2>
        <span class="calendar-muted home-section-meta">{timezone(@window)}</span>
      </header>
      <.directory_status :if={@accounts_state != :ready} state={@accounts_state} id={@id} />
      <div :if={@accounts_state == :ready && @accounts == []} class="calendar-empty empty-state">
        <.icon name="hero-calendar-days" class="empty-state-mark size-6" />
        <div class="empty-state-body">
          <h4 class="empty-state-title">Calendar isn’t connected</h4>
          <p class="empty-state-copy">
            Connect Calendar and choose which calendars appear here, read-only.
          </p>
          <.link patch="/connections/calendar" class="workspace-action workspace-action-link">Set up Calendar</.link>
        </div>
      </div>
      <section
        :for={{account, snapshot} <- @readouts}
        id={"#{@id}-account-#{account.id}"}
        class="calendar-account"
        aria-labelledby={"#{@id}-identity-#{account.id}"}
        aria-busy={to_string(snapshot.loading)}
      >
        <header class="calendar-account-heading">
          <h4 id={"#{@id}-identity-#{account.id}"} class="calendar-identity">{account.email}</h4>
          <button
            :if={!@home && snapshot.enabled && @window}
            type="button"
            class="workspace-action"
            phx-click="calendar:refresh"
            phx-value-id={account.id}
            aria-label={"Refresh Calendar for #{account.email}"}
            disabled={snapshot.loading}
          >Refresh</button>
        </header>
        <div :if={!snapshot.enabled} class="empty-state">
          <.icon name="hero-calendar-days" class="empty-state-mark size-6" />
          <div class="empty-state-body">
            <h4 class="empty-state-title">Calendar is not connected</h4>
            <p class="empty-state-copy">Enable read-only Calendar access for this account.</p>
            <.link patch="/connections/calendar" class="workspace-action workspace-action-link">Set up Calendar</.link>
          </div>
        </div>
        <div :if={snapshot.enabled}>
          <.status snapshot={snapshot} id={"#{@id}-status-#{account.id}"} warnings_only={@home} />
          <.link
            :if={snapshot.error == :reconnect}
            patch="/connections/calendar"
            class="workspace-action workspace-action-link"
          >Authorize Calendar again in Connections</.link>
          <div :if={successful?(snapshot) && snapshot.events == []} class="calendar-message">
            <div class="empty-state-body">
              <h4 class="empty-state-title">
                {if snapshot.selected_ids == [], do: "No calendars selected", else: "No events today"}
              </h4>
              <p :if={!@home || snapshot.selected_ids == []} class="empty-state-copy">
                {if snapshot.selected_ids == [],
                  do: "Choose which calendars appear in MONOLITH.",
                  else: "Your selected calendars have no events today."}
              </p>
              <.link
                :if={snapshot.selected_ids == []}
                patch="/connections/calendar"
                class="workspace-action workspace-action-link"
              >Choose calendars</.link>
            </div>
          </div>
          <ul :if={snapshot.events != []} class="calendar-events">
            <%= for event <- snapshot.events do %>
              <% occurrence = event_identity(account, event) %>
              <li id={"#{@id}-event-#{occurrence}"} class="calendar-event">
                <div class="calendar-event-content">
                  <p class="calendar-event-title">
                    <button
                      type="button"
                      class="calendar-event-button"
                      aria-haspopup="dialog"
                      aria-controls={"#{@id}-event-dialog"}
                      data-calendar-event-open
                      data-event-title={present(event.title, "(Untitled event)")}
                      data-event-account={account.email}
                      data-event-calendar={present(event.calendar_name, "Calendar")}
                      data-event-url={safe_google_url(event.url)}
                    >{present(event.title, "(Untitled event)")}</button>
                  </p>
                  <p class="calendar-muted">{present(event.calendar_name, "Calendar")}</p>
                </div>
                <span
                  id={"#{@id}-time-#{occurrence}"}
                  class="calendar-event-time"
                  phx-hook="CalendarEventTime"
                  data-start={iso(event.start)}
                  data-end={iso(event.end)}
                  data-all-day={to_string(event.all_day == true)}
                >
                  <span
                    id={"#{@id}-time-text-#{occurrence}"}
                    data-calendar-time-text
                    phx-update="ignore"
                  >{if event.all_day, do: "All day", else: "Local time loading…"}</span>
                </span>
                <a
                  :if={safe_google_url(event.url)}
                  href={safe_google_url(event.url)}
                  target="_blank"
                  rel="noopener noreferrer"
                  referrerpolicy="no-referrer"
                  class="calendar-event-link workspace-action-link"
                  aria-label={"Open #{present(event.title, "untitled event")} in Google Calendar (new tab)"}
                >Google Calendar</a>
              </li>
            <% end %>
          </ul>
        </div>
      </section>
      <dialog
        id={"#{@id}-event-dialog"}
        class="monolith-modal calendar-event-dialog"
        aria-labelledby={"#{@id}-event-title"}
        data-calendar-dialog
        phx-update="ignore"
      >
        <p class="home-eyebrow">02 / Calendar · read-only</p>
        <h3 id={"#{@id}-event-title"} class="monolith-modal-title" data-calendar-dialog-title>
          Calendar event.
        </h3>
        <p class="calendar-identity" data-calendar-dialog-account></p>
        <p class="calendar-muted" data-calendar-dialog-calendar></p>
        <p data-calendar-dialog-time></p>
        <p class="calendar-muted">
          Times use this browser’s local timezone. Changes are made in Google Calendar.
        </p>
        <div class="calendar-dialog-actions">
          <a
            data-calendar-dialog-link
            target="_blank"
            rel="noopener noreferrer"
            referrerpolicy="no-referrer"
            class="workspace-action workspace-action-link"
            hidden
          >Open in Google Calendar<span class="sr-only"> (opens in a new tab)</span></a>
          <form method="dialog">
            <button type="submit" class="workspace-action" autofocus>Close event</button>
          </form>
        </div>
      </dialog>
    </section>
    """
  end

  attr :accounts, :list, required: true
  attr :accounts_state, :atom, default: :ready
  attr :workspace_options, :list, required: true
  attr :google_status, :atom, required: true
  attr :window, :map, default: nil
  attr :refresh, :integer, default: 0
  attr :id, :string, default: "calendar-connections"

  def connections(assigns) do
    assigns =
      assign(
        assigns,
        :readouts,
        directory_readouts(assigns.accounts_state, assigns.accounts, assigns.window)
      )

    ~H"""
    <section id={@id} class="calendar-connections" aria-labelledby={"#{@id}-heading"}>
      <header class="card-section-heading">
        <p class="mail-eyebrow">Google account access</p>
        <h3 id={"#{@id}-heading"}>Calendar access</h3>
      </header>
      <p class="calendar-muted">Optional, read-only access · independent of Gmail health</p>
      <p
        :if={@google_status != :stored}
        id={"#{@id}-google-prerequisite"}
        class="calendar-muted"
        role="status"
      >
        <%= if @google_status in [:unknown, :loading] do %>
          Checking Google client settings…
        <% else %>
          Set up or restore client settings in
          <.link patch="/connections/google" class="workspace-action-link">Google connections</.link>
          before connecting Calendar.
        <% end %>
      </p>
      <.directory_status :if={@accounts_state != :ready} state={@accounts_state} id={@id} />
      <div :if={@accounts_state == :ready && @accounts == []} class="empty-state calendar-empty">
        <.icon name="hero-calendar-days" class="empty-state-mark size-6" />
        <div class="empty-state-body">
          <h4 class="empty-state-title">Start with a Google connection</h4>
          <p class="empty-state-copy">
            Connect Gmail first, then return here to enable Calendar for the same account
            and choose which calendars appear. Calendar access is read-only.
          </p>
          <.link
            :if={@google_status == :stored}
            patch="/connections/gmail"
            class="workspace-action workspace-action-primary"
          >
            Connect Gmail
          </.link>
          <button
            :if={@google_status != :stored}
            type="button"
            class="workspace-action workspace-action-primary"
            disabled
            aria-describedby={"#{@id}-google-prerequisite"}
          >Connect Gmail</button>
        </div>
      </div>
      <article
        :for={{account, snapshot} <- @readouts}
        id={"#{@id}-account-#{account.id}"}
        class="calendar-account"
        aria-labelledby={"#{@id}-identity-#{account.id}"}
      >
        <header class="connection-card-head">
          <div>
            <h4 id={"#{@id}-identity-#{account.id}"} class="calendar-identity">{account.email}</h4>
            <p class="identity calendar-muted">
              {if snapshot.enabled, do: "Calendar · read-only", else: "Calendar not enabled"}
            </p>
          </div>
          <.status_signal
            id={"#{@id}-capability-#{account.id}"}
            state={if snapshot.enabled, do: :ready, else: :unknown}
            label={if snapshot.enabled, do: "Calendar enabled", else: "Not enabled"}
          />
        </header>
        <.authorize
          :if={!snapshot.enabled || snapshot.error == :reconnect}
          account={account}
          workspace_options={@workspace_options}
          id={@id}
          reconnect={snapshot.error == :reconnect}
          disabled={@google_status != :stored}
        />
        <div :if={snapshot.enabled}>
          <.status snapshot={snapshot} id={"#{@id}-status-#{account.id}"} />
          <details
            :if={snapshot.calendars != []}
            id={"#{@id}-selection-#{account.id}"}
            class="calendar-selection"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Calendars shown in MONOLITH</summary>
            <.form
              for={to_form(%{}, as: nil)}
              id={"#{@id}-select-#{account.id}"}
              phx-submit="calendar:select"
            >
              <input type="hidden" name="account_id" value={account.id} />
              <input type="hidden" name="generation" value={account.generation} />
              <%!-- An empty selection still submits a list; the handler discards the sentinel. --%>
              <input type="hidden" name="calendar_ids[]" value="" />
              <fieldset disabled={
                snapshot.loading || snapshot.error == :reconnect || @google_status != :stored
              }>
                <legend>Choose up to 20 calendars for this account</legend>
                <p class="calendar-muted">
                  Google-selected calendars are used by default. Changes here affect only MONOLITH.
                  Uncheck all to show none.
                </p>
                <label :for={calendar <- snapshot.calendars} class="calendar-checkbox">
                  <input
                    type="checkbox"
                    name="calendar_ids[]"
                    value={calendar.id}
                    checked={calendar.id in snapshot.selected_ids}
                  />
                  <span>{present(calendar.name, "(Unnamed calendar)")}</span>
                </label>
                <button type="submit" class="workspace-action workspace-action-primary">Save calendar selection</button>
              </fieldset>
              <p
                :if={snapshot.loading || snapshot.error == :reconnect || @google_status != :stored}
                class="calendar-muted"
              >
                <%= cond do %>
                  <% snapshot.error == :reconnect -> %>
                    Authorize Calendar again before changing this selection.
                  <% @google_status != :stored -> %>
                    Restore Google client settings before changing this selection.
                  <% true -> %>
                    Calendar is updating. Selection changes are unavailable until it finishes.
                <% end %>
              </p>
            </.form>
          </details>
          <div :if={snapshot.calendars == [] && successful?(snapshot)} class="calendar-message">
            <div class="empty-state-body">
              <h4 class="empty-state-title">No calendars available</h4>
              <p class="empty-state-copy">
                Google returned no calendars for this account.
              </p>
            </div>
          </div>
          <p :if={snapshot.calendars == [] && !successful?(snapshot)} class="calendar-message">
            Calendar list unavailable until a successful update.
          </p>
          <button
            type="button"
            class="workspace-action"
            phx-click="calendar:refresh"
            phx-value-id={account.id}
            disabled={snapshot.loading || is_nil(@window) || @google_status != :stored}
          >Refresh Calendar</button>
          <p :if={is_nil(@window)} class="calendar-muted">
            Waiting for this browser’s local day before refreshing Calendar.
          </p>
        </div>
      </article>
      <details
        :if={@accounts_state == :ready && @accounts != []}
        id={"#{@id}-disconnect-help"}
        class="calendar-muted calendar-disconnect-help connection-help"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>Shared Google connection</summary>
        <p>
          Calendar has no separate disconnect. Disconnect everywhere removes the shared Google
          connection from every workspace.
        </p>
        <.link patch="/connections/gmail" class="workspace-action workspace-action-link">Manage in Gmail</.link>
      </details>
    </section>
    """
  end

  attr :account, :map, required: true
  attr :workspace_options, :list, required: true
  attr :id, :string, required: true
  attr :reconnect, :boolean, required: true
  attr :disabled, :boolean, required: true

  defp authorize(assigns) do
    assigns =
      assign(assigns, :form, to_form(%{"workspace_id" => ""}, as: nil))

    ~H"""
    <.form
      for={@form}
      id={"#{@id}-authorize-#{@account.id}"}
      action="/oauth/google/start"
      method="post"
      class="calendar-authorize"
    >
      <input type="hidden" name="capability" value="calendar" />
      <input type="hidden" name="expected_account_id" value={@account.id} />
      <.input
        field={@form[:workspace_id]}
        id={"#{@id}-workspace-#{@account.id}"}
        type="select"
        label="Receiving workspace"
        options={@workspace_options}
        prompt="Choose workspace"
        class="connection-workspace-select"
        required
        disabled={@disabled}
      />
      <button
        type="submit"
        class="workspace-action workspace-action-primary"
        disabled={@disabled || @workspace_options == []}
      >
        {if @reconnect, do: "Authorize Calendar again", else: "Enable read-only Calendar"}
      </button>
      <p :if={@workspace_options == []} class="calendar-muted">Create a workspace first.</p>
    </.form>
    """
  end

  attr :snapshot, :map, required: true
  attr :id, :string, required: true
  attr :warnings_only, :boolean, default: false

  defp status(assigns) do
    ~H"""
    <div id={@id} class="calendar-status">
      <div
        :if={
          @snapshot.loading || @snapshot.pending || @snapshot.error || @snapshot.truncated ||
            @snapshot.selection_truncated || @snapshot.stale || !@snapshot.fetched_at
        }
        role="status"
        aria-live="polite"
      >
        <.status_signal
          :if={@snapshot.loading}
          id={"#{@id}-loading"}
          state={:active}
          label="Updating Calendar…"
        />
        <.status_signal
          :if={@snapshot.pending && !@snapshot.loading && !@snapshot.error}
          id={"#{@id}-waiting"}
          state={:waiting}
          label="Waiting for today's Calendar update…"
        />
        <p :if={@snapshot.error} class="calendar-warning">{error_text(@snapshot.error)}</p>
        <p :if={@snapshot.truncated} class="calendar-warning">
          Today's agenda is incomplete. Open Google Calendar for the full day.
        </p>
        <p :if={@snapshot.selection_truncated} class="calendar-warning">
          Not all calendars could be included. Choose up to 20 calendars in Connections.
        </p>
        <p :if={@snapshot.stale && !@snapshot.error} class="calendar-warning">
          Showing a previous local copy; it may no longer match Google Calendar.
        </p>
        <.status_signal
          :if={!@snapshot.loading && !@snapshot.pending && !@snapshot.error && !@snapshot.fetched_at}
          id={"#{@id}-unknown"}
          state={:unknown}
          label="No successful Calendar update yet."
        />
      </div>
      <span
        :if={iso(@snapshot.fetched_at)}
        id={"#{@id}-observed"}
        phx-hook="ObservationTime"
        phx-update="ignore"
        data-observed-at={iso(@snapshot.fetched_at)}
        data-warnings-only={to_string(@warnings_only)}
        data-failed={to_string(not is_nil(@snapshot.error) || @snapshot.truncated || @snapshot.stale)}
      >{if !@warnings_only, do: "Last checked · #{iso(@snapshot.fetched_at)}"}</span>
    </div>
    """
  end

  defp event_identity(account, event) do
    {account.id, Map.get(account, :generation), event.calendar_id, event.id, event.start}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  attr :state, :atom, required: true
  attr :id, :string, required: true

  defp directory_status(assigns) do
    ~H"""
    <div id={"#{@id}-directory-status"} class="calendar-message" role="status">
      <.status_signal
        id={"#{@id}-directory-signal"}
        state={:unknown}
        label={
          if @state == :unavailable,
            do: "Calendar connections unavailable",
            else: "Calendar connections not checked"
        }
      />
      <p class="calendar-muted">
        Calendar access can’t be confirmed. Reload Connections to check the current accounts.
      </p>
      <.link href="/connections/calendar" class="workspace-action workspace-action-link">
        Reload Calendar connections
      </.link>
    </div>
    """
  end

  defp directory_readouts(:ready, accounts, window), do: readouts(accounts, window)
  defp directory_readouts(_, _, _), do: []

  defp readouts(accounts, window) do
    Enum.map(accounts, fn account -> {account, snapshot(account, window)} end)
  end

  defp snapshot(account, window) do
    enabled = Map.get(account, :calendar_enabled, false) == true

    result =
      if enabled && window do
        Monolith.Calendar.snapshot(account.id, window.from, window.to, window.date,
          actor: %{role: :local_owner}
        )
      else
        %{enabled: enabled, loading: enabled}
      end

    snapshot = normalize_snapshot(result, enabled)

    if enabled && Map.get(account, :status) == :reconnect,
      do: %{snapshot | error: :reconnect, loading: false},
      else: snapshot
  end

  # Keep the local-cache API boundary here so backend shape changes stay localized.
  defp normalize_snapshot({:ok, data}, enabled), do: normalize_snapshot(data, enabled)

  defp normalize_snapshot({:error, error}, enabled),
    do: normalize_snapshot(%{error: error, loading: false}, enabled)

  defp normalize_snapshot(data, enabled) when is_map(data) do
    calendars = Map.get(data, :calendars, []) || []
    fetched_at = Map.get(data, :fetched_at)
    error = Map.get(data, :error)

    %{
      # Account capability remains enabled even when backend availability is false on reconnect.
      enabled: enabled,
      calendars: calendars,
      selected_ids:
        Map.get(data, :selected_ids) ||
          for(calendar <- calendars, Map.get(calendar, :selected, false), do: calendar.id),
      events: Enum.map(Map.get(data, :events, []) || [], &normalize_event/1),
      fetched_at: fetched_at,
      error: error,
      truncated: Map.get(data, :truncated, false) == true,
      selection_truncated: Map.get(data, :selection_truncated, false) == true,
      stale: Map.get(data, :stale, false) == true,
      pending: Map.get(data, :pending, is_nil(fetched_at)) == true,
      loading: Map.get(data, :loading, is_nil(fetched_at) && is_nil(error)) == true
    }
  end

  defp normalize_snapshot(_, enabled),
    do: normalize_snapshot(%{error: :unavailable, loading: false}, enabled)

  defp normalize_event(event) do
    Map.new([:id, :title, :start, :end, :all_day, :url, :calendar_id, :calendar_name], fn key ->
      {key, Map.get(event, key)}
    end)
  end

  defp successful?(snapshot),
    do:
      not is_nil(snapshot.fetched_at) && !snapshot.loading && !snapshot.pending &&
        is_nil(snapshot.error) && !snapshot.truncated && !snapshot.selection_truncated &&
        !snapshot.stale

  defp timezone(nil), do: "Waiting for browser timezone"
  defp timezone(window), do: Map.get(window, :timezone, "Browser local time")

  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(%Date{} = value), do: Date.to_iso8601(value)
  defp iso(value) when is_binary(value), do: value
  defp iso(_), do: nil

  defp present(value, fallback) when value in [nil, ""], do: fallback
  defp present(value, _fallback), do: value

  defp safe_google_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, port: 443, path: path}
      when host in ["calendar.google.com", "www.google.com"] ->
        if is_binary(path) && (path == "/calendar" || String.starts_with?(path, "/calendar/")),
          do: value

      _ ->
        nil
    end
  end

  defp safe_google_url(_), do: nil

  defp error_text(:reconnect), do: "Calendar authorization needs reconnecting."
  defp error_text(:keychain), do: "Credential store unavailable. Check Connections."

  defp error_text(:rate_limited),
    do: "Google is rate limiting Calendar updates; polling will wait."

  defp error_text(:offline), do: "Calendar update unavailable while offline."

  defp error_text(:truncated),
    do: "Today's agenda is incomplete. Open Google Calendar for the full day."

  defp error_text(_),
    do: "Calendar update unavailable. Any displayed events are a previous local copy."
end
