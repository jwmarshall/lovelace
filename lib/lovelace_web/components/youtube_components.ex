defmodule LovelaceWeb.YouTubeComponents do
  @moduledoc "Bounded, account-separated subscriptions and a deliberately click-loaded official player."
  use LovelaceWeb, :html
  alias LovelaceWeb.HomeNavigation

  attr :readouts, :list, required: true
  attr :workspace_options, :list, required: true
  attr :google_status, :atom, required: true
  attr :stopped, :boolean, default: false
  attr :error, :boolean, default: false

  def connections(assigns) do
    ~H"""
    <section id="youtube-connections" class="youtube-section" aria-labelledby="youtube-heading">
      <h3 id="youtube-heading" class="mail-section-title">YouTube</h3>
      <p class="mail-muted">
        Read-only subscriptions · Separate Google accounts · No recommendations feed
      </p>
      <p
        :if={@google_status != :stored}
        role="status"
        aria-busy={to_string(@google_status in [:unknown, :loading])}
        class={if @google_status in [:unknown, :loading], do: "mail-muted", else: "calendar-warning"}
      >
        <%= if @google_status in [:unknown, :loading] do %>
          Checking Google client settings…
        <% else %>
          Set up or restore
          <.link patch="/connections/google" class="workspace-action-link">Google client settings</.link>
          before authorizing YouTube.
        <% end %>
      </p>
      <p :if={@error} role="alert" class="calendar-warning">
        Local YouTube state could not be read. No account or selection changes were made. Reopen this page to check again.
      </p>
      <p :if={@readouts == [] && !@error} class="mail-muted">
        Connect an existing Google account in
        <.link patch="/connections/gmail" class="workspace-action-link">Gmail</.link>
        first, then return here. YouTube is optional.
      </p>
      <article
        :for={{account, snapshot} <- @readouts}
        id={"youtube-account-#{account.id}"}
        class="youtube-account"
      >
        <h4 class="calendar-identity">{account.email}</h4>
        <p class="mail-muted">
          <%= cond do %>
            <% !snapshot.available -> %>
              YouTube state unavailable
            <% snapshot.error == :reconnect -> %>
              Google sign-in required
            <% snapshot.enabled -> %>
              YouTube enabled · read-only
            <% true -> %>
              YouTube not enabled
          <% end %>
        </p>
        <.form
          :if={snapshot.available && (!snapshot.enabled || snapshot.error == :reconnect)}
          for={%{}}
          id={"youtube-authorize-#{account.id}"}
          action="/oauth/google/start"
          method="post"
          class="calendar-authorize"
        >
          <input type="hidden" name="expected_account_id" value={account.id} />
          <input type="hidden" name="capability" value="youtube" />
          <label for={"youtube-workspace-#{account.id}"}>Receiving workspace</label>
          <select
            id={"youtube-workspace-#{account.id}"}
            name="workspace_id"
            class="connection-workspace-select"
            required
            disabled={@google_status != :stored}
          >
            <option value="">Choose workspace</option>
            <option :for={{name, id} <- @workspace_options} value={id}>{name}</option>
          </select>
          <button
            type="submit"
            class="workspace-action workspace-action-primary"
            disabled={@google_status != :stored || @workspace_options == []}
          >
            {if account.youtube_enabled,
              do: "Authorize YouTube again",
              else: "Enable read-only YouTube"}
          </button>
          <p class="mail-muted">
            Explicitly grants YouTube read access to this account only. Gmail and Calendar remain separate.
          </p>
        </.form>
        <.status snapshot={snapshot} id={"youtube-status-#{account.id}"} />
        <div :if={snapshot.available && snapshot.enabled}>
          <.link
            patch={HomeNavigation.youtube_path(account.id)}
            class="workspace-action workspace-action-link"
          >Open subscriptions</.link>
        </div>
      </article>
      <.observation_stopped :if={@stopped} />
      <details
        id="youtube-setup-guide"
        class="connection-help mail-muted"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>YouTube API setup &amp; privacy</summary>
        <ol class="youtube-guide">
          <li>
            Reuse the Google Cloud project and Desktop OAuth client already configured in <.link
              patch="/connections/google"
              class="workspace-action-link"
            >Google connections</.link>. No new account or onboarding step is needed.
          </li>
          <li>
            In <a
              href="https://console.cloud.google.com/apis/library/youtube.googleapis.com"
              target="_blank"
              rel="noopener noreferrer"
              class="workspace-action-link"
              aria-label="YouTube Data API v3 in Google Cloud (new tab)"
            >Google Cloud’s API Library</a>, enable YouTube Data API v3 for that project.
          </li>
          <li>
            In Google Auth Platform → Data Access, add <code>https://www.googleapis.com/auth/youtube.readonly</code>. Keep your account in Audience → Test users while the app is in Testing. Testing grants can expire and require authorization again.
          </li>
          <li>
            Choose the existing account and receiving workspace above, then explicitly consent. Choose up to 10 subscribed channels on its subscriptions page; none are selected automatically. LOVELACE never changes subscriptions, likes, playlists or videos.
          </li>
        </ol>
        <p>
          At most 100 subscriptions and 10 uploads per selected channel (100 total) are read. Updates are bounded, not a complete history. No comments, infinite scroll or automatic next video. Refresh has a cooldown; background work runs only while LOVELACE is running and unlocked.
        </p>
        <p>
          No remote thumbnails or player are loaded on opening a page. Only a fresh “Load YouTube player” click contacts YouTube. The official privacy-enhanced player may show ads and recommendations controlled by YouTube, not LOVELACE.
        </p>
        <p>
          Manage or disconnect the shared Google account in <.link
            patch="/connections/gmail"
            class="workspace-action-link"
          >Gmail connections</.link>. Removing it from a workspace is not a global disconnect.
        </p>
      </details>
    </section>
    """
  end

  attr :account, :map, required: true
  attr :snapshot, :map, required: true
  attr :video, :map, default: nil
  attr :video_route, :boolean, default: false
  attr :stopped, :boolean, default: false

  def feed(assigns) do
    ~H"""
    <section
      id="youtube-feed"
      class="youtube-section"
      aria-labelledby="youtube-account-heading"
      aria-busy={to_string(@snapshot.loading)}
    >
      <header class="calendar-account-heading">
        <h3 id="youtube-account-heading" class="calendar-identity">{@account.email}</h3>
        <.link patch="/connections/youtube" class="workspace-action workspace-action-link">YouTube connections</.link>
      </header>
      <p class="mail-muted">Subscribed channels · Newest uploads first · This account only</p>
      <.status snapshot={@snapshot} id="youtube-feed-status" />
      <p :if={@snapshot.available && !@account.youtube_enabled} class="mail-muted">
        YouTube is not enabled. Authorize this account in Connections.
      </p>
      <div :if={@snapshot.enabled}>
        <div class="youtube-actions">
          <button
            id="youtube-refresh"
            type="button"
            class="workspace-action"
            phx-click="youtube:refresh"
            phx-value-account_id={@account.id}
            disabled={@snapshot.loading}
          >Refresh YouTube</button>
          <span :if={cooling?(@snapshot)} class="mail-muted">Refresh available after {iso(
            @snapshot.cooldown_until
          )}</span>
        </div>
        <details
          id="youtube-selection"
          class="calendar-selection"
          phx-mounted={JS.ignore_attributes("open")}
        >
          <summary>Choose subscribed channels ({length(@snapshot.selected_ids)} / 10)</summary>
          <.form for={%{}} id="youtube-select" phx-submit="youtube:select">
            <input type="hidden" name="account_id" value={@account.id} />
            <input type="hidden" name="generation" value={@snapshot.generation} />
            <input type="hidden" name="revision" value={@snapshot.revision} />
            <input type="hidden" name="channel_ids[]" value="" />
            <fieldset disabled={
              @snapshot.loading || @snapshot.error == :reconnect || !@snapshot.enabled
            }>
              <legend>Choose up to 10 channels. Uncheck all to show none.</legend>
              <label :for={channel <- @snapshot.channels} class="calendar-checkbox">
                <input
                  type="checkbox"
                  name="channel_ids[]"
                  value={channel["id"]}
                  checked={channel["id"] in @snapshot.selected_ids}
                />
                <span>{channel["title"]}</span>
              </label>
              <label
                :for={id <- @snapshot.selected_ids -- Enum.map(@snapshot.channels, & &1["id"])}
                class="calendar-checkbox"
              >
                <input type="checkbox" name="channel_ids[]" value={id} checked />
                <span>Previously selected channel · {id} (outside the current catalog)</span>
              </label>
              <p :if={@snapshot.channels == []} class="mail-muted">
                No subscription catalog available. Refresh to check this account.
              </p>
              <button type="submit" class="workspace-action workspace-action-primary">Save channel selection</button>
            </fieldset>
          </.form>
        </details>
        <.observation_stopped :if={@stopped} />
        <div :if={@video_route} id="youtube-watch">
          <.link
            patch={HomeNavigation.youtube_path(@account.id)}
            class="workspace-action workspace-action-link"
          >Back to uploads</.link>
          <%= if @video do %>
            <h4 class="mail-section-title">{@video["title"]}</h4>
            <p class="mail-muted">{@video["channel_title"]}</p>
            <p id="youtube-player-privacy" class="mail-muted">
              Loading the player contacts YouTube. Ads and recommendations inside the official player are controlled by YouTube. Nothing plays automatically.
            </p>
            <p class="mail-muted">
              Inside YouTube, use Tab or Shift+Tab to return to the controls below. Escape controls LOVELACE only outside the player. Visual idle pauses while the visible player has keyboard focus.
            </p>
            <div
              id="youtube-player"
              class="youtube-player"
              phx-hook="YouTubePlayer"
              data-video-id={@video["id"]}
              data-account-id={@account.id}
              data-generation={@snapshot.generation}
              data-revision={@snapshot.revision}
              data-selection={Enum.join(Enum.sort(@snapshot.selected_ids), ",")}
            >
              <div id="youtube-player-host" data-youtube-player-host phx-update="ignore"></div>
              <button
                id="youtube-player-load"
                type="button"
                class="workspace-action"
                data-youtube-load
                aria-describedby="youtube-player-privacy"
              >Load YouTube player</button>
              <button type="button" class="workspace-action" data-youtube-unload hidden>Unload player</button>
              <p class="sr-only" role="status" data-youtube-player-status></p>
            </div>
          <% else %>
            <p role="status" class="calendar-warning">
              This video is no longer in this account’s selected feed. The player has been removed.
            </p>
          <% end %>
        </div>
        <div :if={!@video_route}>
          <p
            :if={
              @snapshot.selected_ids == [] && !@snapshot.loading && is_nil(@snapshot.error) &&
                @snapshot.fetched_at
            }
            class="mail-muted"
          >
            No channels selected. Choose subscriptions above; nothing is selected automatically.
          </p>
          <p
            :if={
              @snapshot.selected_ids != [] && @snapshot.videos == [] &&
                @snapshot.status in [:ready, :empty] && !@snapshot.loading && is_nil(@snapshot.error)
            }
            class="mail-muted"
          >
            No recent uploads were returned for your selected channels.
          </p>
          <ol id="youtube-videos" class="youtube-videos">
            <li :for={video <- @snapshot.videos}>
              <.link
                patch={HomeNavigation.youtube_path(@account.id, video["id"])}
                class="youtube-video-link"
              >
                <span>{video["title"]}</span>
                <span class="mail-muted">{video["channel_title"]} ·
                <time datetime={video["published_at"]}>{video["published_at"]}</time></span>
              </.link>
            </li>
          </ol>
          <p class="mail-muted">
            Bounded recent uploads, not a full archive. No automatic next video.
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :snapshot, :map, required: true
  attr :id, :string, required: true

  defp status(assigns) do
    ~H"""
    <div id={@id} role="status" class="youtube-status" aria-live="polite">
      <p :if={@snapshot.loading} class="mail-muted">Updating YouTube…</p>
      <p :if={@snapshot.status == :stale} class="calendar-warning">
        The local uploads copy may be out of date. Refresh to check for newer uploads.
      </p>
      <p :if={@snapshot.error} class="calendar-warning">{error_text(@snapshot.error)}</p>
      <p :if={@snapshot.truncated} class="calendar-warning">
        This is a partial, bounded result: at most 100 subscriptions and 10 uploads per selected channel. It is not your complete subscription list or upload history.
      </p>
      <p :if={@snapshot.fetched_at} class="mail-muted">
        Last checked · <time datetime={iso(@snapshot.fetched_at)}>{iso(@snapshot.fetched_at)}</time>
      </p>
      <p
        :if={
          @snapshot.enabled && !@snapshot.loading && is_nil(@snapshot.fetched_at) &&
            is_nil(@snapshot.error)
        }
        class="mail-muted"
      >
        YouTube has not been checked yet.
      </p>
    </div>
    """
  end

  defp observation_stopped(assigns) do
    ~H"""
    <p class="mail-muted" role="status">
      Automatic status checks stopped. Accepted work may still finish.
      <button type="button" class="workspace-action" phx-click="youtube:check">Check local status</button>
    </p>
    """
  end

  defp error_text(:reconnect),
    do:
      "YouTube needs authorization again. Gmail and Calendar access are separate. Open YouTube connections."

  defp error_text(:rate_limited),
    do:
      "YouTube’s API limit was reached. Refresh is paused until the cooldown ends; trying again cannot bypass it."

  defp error_text(_),
    do:
      "YouTube could not be updated. The last successful local copy, if available, is shown. Try Refresh or check Connections."

  defp cooling?(%{cooldown_until: %DateTime{} = until}),
    do: DateTime.compare(until, DateTime.utc_now()) == :gt

  defp cooling?(_), do: false
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(_), do: nil
end
