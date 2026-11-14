defmodule MonolithWeb.HomeComponents do
  @moduledoc "Daily orientation with separate account readouts and real local preferences."
  use MonolithWeb, :html

  def daily_heading(assigns) do
    ~H"""
    <div class="page-register-row page-header-row">
      <p class="page-register">01 / Home</p>
      <.lock_control />
    </div>
    <header id="daily-heading" class="home-hero" phx-hook="DailyOrientation" phx-update="ignore">
      <div class="date-block">
        <time data-daily-date class="daily-date">
          <span data-daily-number class="day-number"></span>
          <span class="date-caption"><span data-daily-weekday></span><span data-daily-month></span></span>
        </time>
      </div>
      <div class="home-greeting">
        <h1 id="directory-heading" tabindex="-1" data-workspace-heading>A day<br />in focus.</h1>
      </div>
    </header>
    """
  end

  attr :accounts, :list, required: true
  attr :loading, :boolean, default: false
  attr :error, :boolean, default: false

  def overview(assigns) do
    ~H"""
    <section
      id="home-overview"
      class="home-overview"
      aria-labelledby="home-mail-heading"
      aria-busy={to_string(@loading)}
    >
      <div class="home-section-heading">
        <h2 id="home-mail-heading" class="section-register">01 / Email</h2>
      </div>
      <p :if={@loading} class="home-empty" role="status">
        <.status_signal id="home-loading-signal" state={:active} label="Loading accounts…" />
      </p>
      <div :if={@error} id="home-error" class="home-empty" role="alert">
        <p>Accounts couldn’t be loaded.</p><button
          type="button"
          class="workspace-action"
          phx-click="retry_workspaces"
        >Try again</button>
      </div>
      <div :if={!@loading && !@error && @accounts == []} id="home-empty" class="empty-state">
        <.icon name="hero-envelope" class="empty-state-mark size-6" />
        <div class="empty-state-body">
          <h3 class="empty-state-title">No Gmail accounts connected</h3><p class="empty-state-copy">
            Connect an account to see unread counts here. Each inbox stays separate.
          </p><.link patch="/connections/gmail" class="workspace-action workspace-action-link">Connect Gmail</.link>
        </div>
      </div>
      <ul :if={!@error && !@loading && @accounts != []} id="home-accounts" class="home-accounts">
        <.account_readout
          :for={account <- @accounts}
          account={account}
          show_connection_warning={false}
        />
      </ul>
    </section>
    """
  end

  attr :account, :map, required: true
  attr :inbox_path, :string, default: nil
  attr :show_connection_warning, :boolean, default: true

  def account_readout(assigns) do
    ~H"""
    <li id={"home-account-#{@account.id}"} class="home-account">
      <.link
        id={"open-home-account-#{@account.id}"}
        patch={@inbox_path || MonolithWeb.HomeNavigation.account_path(@account.id)}
        class="home-account-open"
        aria-label={"Open inbox for #{@account.email}"}
        aria-describedby={"home-count-#{@account.id} home-health-#{@account.id}"}
      >
        <span class="home-account-identity">
          <span class="home-account-email">{@account.email}</span>
          <span class="home-account-workspaces">
            {if @account.workspaces == [],
              do: "Not in a workspace",
              else: Enum.join(@account.workspaces, " · ")}
          </span>
        </span>
        <span id={"home-count-#{@account.id}"} class="home-unread">
          <span class="home-count">
            <span class="metric-label">UNREAD</span>
            <b aria-hidden="true">{if is_integer(@account.inbox_unread_count),
              do: @account.inbox_unread_count,
              else: "—"}</b>
            <span class="sr-only">{if is_integer(@account.inbox_unread_count),
              do: "#{@account.inbox_unread_count} total unread inbox conversations",
              else: "Total unavailable for unread inbox conversations"}</span>
          </span>
          <span class="home-count home-count-recent">
            <span class="metric-label">LAST 24H</span>
            <b aria-hidden="true">{if is_integer(@account.inbox_unread_recent_count),
              do: @account.inbox_unread_recent_count,
              else: "—"}</b>
            <span class="sr-only">{if is_integer(@account.inbox_unread_recent_count),
              do: "#{@account.inbox_unread_recent_count} received in the last 24 hours",
              else: "Last 24 hours unavailable"}</span>
          </span>
        </span>
      </.link>
      <div id={"home-health-#{@account.id}"} class="home-account-health">
        <span
          :if={@show_connection_warning && health_message(@account)}
          class="connection-warning"
        >{health_message(@account)}</span>
        <.status_signal
          :if={!@account.inbox_unread_at && !health_message(@account)}
          id={"home-unknown-#{@account.id}"}
          state={:unknown}
          label="No unread count observation available"
        />
        <.link
          :if={@account.status == :reconnect || @account.last_error == :keychain}
          patch="/connections/gmail"
          class="home-recovery workspace-action workspace-action-link"
          aria-label={"Manage connection for #{@account.email}"}
        >Connections</.link>
      </div>
    </li>
    """
  end

  attr :startup_preference, :map, default: nil
  attr :startup_error, :boolean, default: false
  attr :startup_status, :string, default: ""

  def settings(assigns) do
    assigns =
      assign(
        assigns,
        :default_minutes,
        Application.get_env(:monolith, :workspace_idle_minutes, 3)
      )

    ~H"""
    <section id="settings-panel" aria-labelledby="directory-heading">
      <div class="settings-panel">
        <section class="settings-section" aria-labelledby="idle-heading">
          <header class="card-section-heading">
            <p class="mail-eyebrow">Visual focus</p>
            <h2 id="idle-heading">Scenery after inactivity</h2>
          </header>
          <div class="settings-section-content">
            <p>Escape or inactivity reveals the scenery. It doesn’t lock MONOLITH or stop work.</p>
            <form
              id="idle-preference"
              phx-hook="IdlePreference"
              phx-update="ignore"
              data-default-minutes={@default_minutes}
            >
              <div class="field">
                <label for="idle-minutes">Minutes without interaction</label><input
                  id="idle-minutes"
                  name="minutes"
                  type="number"
                  min="1"
                  max="60"
                  step="1"
                  value={@default_minutes}
                  required
                  aria-describedby="idle-help"
                  class="workspace-name-input"
                /><p id="idle-help" class="settings-help">
                  1–60 minutes. Default: 3 minutes. Saved in this browser.
                </p>
              </div>
              <button type="submit" class="workspace-action workspace-action-primary">Save preference</button>
              <p data-idle-status class="settings-status" role="status"></p>
            </form>
          </div>
        </section>
        <section class="settings-section" aria-labelledby="startup-heading">
          <header class="card-section-heading">
            <p class="mail-eyebrow">Scene generation</p>
            <h2 id="startup-heading">Automatic startup scenery</h2>
          </header>
          <div class="settings-section-content">
            <p>Saving this choice doesn’t generate a scene. Existing authorized work is unchanged.</p>
            <p :if={@startup_error} role="alert">
              The startup preference couldn’t be read or saved. No generation was started. Try loading Settings again.
            </p>
            <.form
              :if={@startup_preference}
              for={%{}}
              id="startup-preference"
              phx-submit="settings:startup"
            >
              <input type="hidden" name="enabled" value="false" />
              <label><input
                type="checkbox"
                name="enabled"
                value="true"
                checked={@startup_preference.enabled}
              />Allow a new scene at startup</label>
              <p>
                Opt-in only. Generation can incur Google charges and uses Google’s background interaction storage. Automatic startup has a persisted 24-hour cooldown. Manual requests always need fresh cost confirmation.
              </p>
              <p :if={!@startup_preference.environment_enabled}>
                Automatic startup is blocked by the terminal configuration. Saving an opt-in won’t override that restriction.
              </p>
              <button type="submit" class="workspace-action workspace-action-primary">Save startup choice</button>
            </.form>
            <p :if={@startup_status != ""} id="startup-status" class="settings-status" role="status">
              {@startup_status}
            </p>
          </div>
        </section>
      </div>
      <section class="settings-accessibility" aria-labelledby="accessibility-heading">
        <h2 id="accessibility-heading">Accessibility preferences</h2><p>
          Reduced motion and forced colors follow your browser or system setting. Mouse movement neither wakes the working plane nor extends visual focus.
        </p>
      </section>
    </section>
    """
  end

  defp health_message(%{status: :reconnect}), do: "Reconnect required"
  defp health_message(%{last_error: :keychain}), do: "Credential store unavailable"

  defp health_message(account) do
    case account.inbox_unread_error || account.last_error do
      :rate_limited -> "Gmail rate limit · waiting to retry"
      :reconnect -> "Reconnect required"
      :keychain -> "Credential store unavailable"
      nil -> nil
      _ -> "Update failed · retrying"
    end
  end
end
