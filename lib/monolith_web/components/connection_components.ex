defmodule MonolithWeb.ConnectionComponents do
  @moduledoc "Global connection directory; provider health belongs to each management page."
  use MonolithWeb, :html

  def overview(assigns) do
    ~H"""
    <nav id="connections-overview" class="connections-overview" aria-label="Connections">
      <.link id="open-connection-google" patch="/connections/google" class="connection-provider">
        <span class="connection-provider-register">Shared configuration</span>
        <span class="connection-provider-copy">
          <span class="connection-provider-name">Google</span>
          <span class="mail-muted">Shared Desktop client settings for Google account consent.</span>
        </span>
      </.link>
      <.link id="open-connection-gmail" patch="/connections/gmail" class="connection-provider">
        <span class="connection-provider-register">Per Google account</span>
        <span class="connection-provider-copy">
          <span class="connection-provider-name">Gmail</span>
          <span class="mail-muted">Read-only mail connections and workspace memberships.</span>
        </span>
      </.link>
      <.link id="open-connection-calendar" patch="/connections/calendar" class="connection-provider">
        <span class="connection-provider-register">Per Google account</span>
        <span class="connection-provider-copy">
          <span class="connection-provider-name">Calendar</span>
          <span class="mail-muted">Optional access and selected calendars, separately by account.</span>
        </span>
      </.link>
      <.link id="open-connection-gemini" patch="/connections/gemini" class="connection-provider">
        <span class="connection-provider-register">App-wide</span>
        <span class="connection-provider-copy">
          <span class="connection-provider-name">Gemini</span>
          <span class="mail-muted">Optional scenery credentials. Requests may incur charges.</span>
        </span>
      </.link>
      <.link id="open-connection-github" patch="/connections/github" class="connection-provider">
        <span class="connection-provider-register">Installation access</span>
        <span class="connection-provider-copy">
          <span class="connection-provider-name">GitHub</span>
          <span class="mail-muted">Read-only installation owners and repository access.</span>
        </span>
      </.link>
    </nav>
    """
  end

  attr :provider, :atom, required: true, values: [:google, :gmail, :calendar, :gemini, :github]
  attr :gmail_accounts_present, :boolean, default: false
  slot :github_help

  def context(assigns) do
    ~H"""
    <aside
      id={"provider-context-#{@provider}"}
      class="provider-context"
      aria-labelledby={"provider-context-heading-#{@provider}"}
    >
      <%= case @provider do %>
        <% :google -> %>
          <h2 id="provider-context-heading-google">Permission is specific.</h2>
          <p>
            Saving a client ID and secret stores shared settings locally. It does not
            connect an account, grant Gmail or Calendar access, or verify Google access.
          </p>
          <details id="google-client-help" phx-mounted={JS.ignore_attributes("open")}>
            <summary>Google project setup</summary>
            <div class="provider-context-copy">
              <p>
                Create a Desktop app OAuth client in your own Google Cloud project,
                not a Web application or service account. Enable Gmail, and Calendar
                only if you choose to use it.
              </p>
              <p>
                The setup guide covers APIs, consent scopes, audience and publishing
                settings. One client can serve several Google accounts and workspaces.
              </p>
              <a href="/onboarding/project">Open Google setup guide</a>
            </div>
          </details>
          <details phx-mounted={JS.ignore_attributes("open")}>
            <summary>Storage and account access</summary>
            <div class="provider-context-copy">
              <p>
                Client values live in the dedicated MONOLITH keychain and are never
                displayed again. Saving makes no provider request and needs no restart.
                Check Keychain checks local readability, not Google permissions.
              </p>
              <p>
                Replacing settings does not disconnect accounts or change their grants.
                Switching Google Cloud clients may require those accounts to reconnect.
                Gmail and Calendar each need explicit consent. Gemini uses a separate API key.
              </p>
            </div>
          </details>
        <% :gmail -> %>
          <h2 id="provider-context-heading-gmail">Permission is specific.</h2>
          <p>
            Gmail and Calendar share a Google identity, but their permissions and health
            are separate. Each unread total belongs to one account’s inbox conversations.
          </p>
          <details phx-mounted={JS.ignore_attributes("open")}>
            <summary>Read-only access and workspaces</summary>
            <div class="provider-context-copy">
              <p>
                Connect an account with explicit read-only Gmail consent and choose its
                receiving workspace. Reuse that connection in other workspaces without
                combining inboxes or requesting consent again.
              </p>
              <p>
                Reading mail here does not mark it as read in Gmail. Removing an account
                from one workspace is not disconnecting the shared Google connection everywhere.
              </p>
            </div>
          </details>
          <details id="gmail-keychain-help" phx-mounted={JS.ignore_attributes("open")}>
            <summary>About Keychain access</summary>
            <div class="provider-context-copy">
              <p>
                Check Keychain reads only this account’s local credential. It does not contact Google,
                change permissions, or refresh mail. A readable credential does not verify Google access.
                An unavailable read is not proof that a credential is missing or that Google revoked access.
              </p>
              <p>
                MONOLITH uses its own password-locked keychain, separate from your login keychain.
                Individual items can still deny access to the monolith-vault helper after a rebuild
                changes its security identity. Preserve the vault and review access before rebuilding again.
              </p>
              <p>
                Do not delete credentials or allow all applications. Rebuilding again is not an access
                repair. Reconnect Google only for a missing credential or expired Google authorization.
              </p>
              <p>
                Native storage access failures can lock the application. After a Gmail reconnect,
                enable Calendar again if needed.
              </p>
            </div>
          </details>
          <details
            :if={@gmail_accounts_present}
            id="gmail-disconnect-help"
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>Removal &amp; disconnecting</summary>
            <div class="provider-context-copy">
              <p>
                Remove from workspace only detaches that link. Disconnect everywhere removes all workspace links,
                cached mail and credentials, and attempts Google revocation. Your Gmail mailbox is unchanged.
              </p>
            </div>
          </details>
        <% :calendar -> %>
          <h2 id="provider-context-heading-calendar">Calendar is optional.</h2>
          <p>
            Grant read-only Calendar access explicitly, then select personal or shared
            calendars for each account. A Calendar failure does not by itself mean Gmail is unavailable.
          </p>
          <details phx-mounted={JS.ignore_attributes("open")}>
            <summary>Selection and today’s agenda</summary>
            <div class="provider-context-copy">
              <p>
                Today follows your browser’s local day. An empty selection means no
                calendars are selected, not that Google has no events. Selections and
                observations stay separate for each Google account.
              </p>
              <p>
                Calendar access reuses the existing Google connection and dedicated
                keychain credential. It does not create another owner login or permit calendar edits.
              </p>
            </div>
          </details>
          <details phx-mounted={JS.ignore_attributes("open")}>
            <summary>Consent and recovery</summary>
            <div class="provider-context-copy">
              <p>
                Declining optional Calendar consent leaves an existing Gmail connection
                intact. A Gmail reconnect disables Calendar locally; explicitly enable
                Calendar again afterward.
              </p>
              <p>
                Calendar health and freshness are independent of Gmail. A failure of the
                shared Google credential can still require reconnecting the shared connection.
                Local Keychain readability does not verify provider access.
              </p>
            </div>
          </details>
        <% :gemini -> %>
          <h2 id="provider-context-heading-gemini">Optional, potentially billable.</h2>
          <p>
            Bundled scenery works without Gemini. Saving or removing an API key does
            not generate an image, contact Google or change your startup opt-in.
            Removing a key does not cancel an accepted request. Each generation can incur
            charges even if it fails or its outcome is unknown.
          </p>
          <details id="gemini-generation-help" phx-mounted={JS.ignore_attributes("open")}>
            <summary>Scenery and startup</summary>
            <div class="provider-context-copy">
              <p>
                Scenery is app-wide, not tied to an account or workspace. Manual requests
                in <.link patch="/scenes">Scenes</.link> require fresh cost confirmation
                and have no daily cooldown. Automatic startup has a persisted 24-hour minimum.
              </p>
              <p>
                Save startup opt-in in <.link patch="/settings">Settings</.link>.
                Automatic startup also requires <code>MONOLITH_STAGE_ENABLED=true</code>
                and an eligible restart. Saving the preference neither generates nor cancels work.
              </p>
            </div>
          </details>
          <details phx-mounted={JS.ignore_attributes("open")}>
            <summary>Key storage and recovery</summary>
            <div class="provider-context-copy">
              <p>
                Use a Gemini Developer API key from Google AI Studio. The dedicated
                MONOLITH keychain stores it separately from Google account credentials;
                the saved value is never displayed again.
              </p>
              <p>
                Check Keychain checks local readability, not Google access, billing or
                quota. Generation submissions are not automatically retried. If a submission’s
                outcome is unknown, Google may still have accepted it and charged for it.
                Review that attempt in Scenes before authorizing another request.
              </p>
            </div>
          </details>
        <% :github -> %>
          <h2 id="provider-context-heading-github">Permission is specific.</h2>
          <p>
            Authorizing a GitHub account and choosing an installation’s repositories are
            separate steps. Both the signed-in user and installed App must have repository access.
          </p>
          {render_slot(@github_help)}
          <details phx-mounted={JS.ignore_attributes("open")}>
            <summary>Read-only access and workspaces</summary>
            <div class="provider-context-copy">
              <p>
                MONOLITH reads pull requests, issues and recent Actions separately for
                each installation owner. It does not request repository writes or fetch
                contents, workflow logs or artifacts.
              </p>
              <p>
                Workspace repository selections filter the owner’s saved snapshots.
                Removing a workspace membership is not disconnecting the account.
                Neither action revokes authorization or uninstalls the App on GitHub;
                manage those separately on GitHub.
              </p>
            </div>
          </details>
          <details phx-mounted={JS.ignore_attributes("open")}>
            <summary>Keychain checks and recovery</summary>
            <div class="provider-context-copy">
              <p>
                App settings and account token bundles live in the dedicated MONOLITH
                keychain. Saving settings and Check Keychain inspect local storage,
                not GitHub permissions. Unavailable storage is not proof of revoked access.
              </p>
              <p>
                Replacing changed App settings requires sign-in again. An unknown token
                exchange or refresh outcome also needs fresh sign-in; an old code or
                refresh token is not automatically replayed.
              </p>
            </div>
          </details>
      <% end %>
    </aside>
    """
  end
end
