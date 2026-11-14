defmodule MonolithWeb.MailComponents do
  @moduledoc "Read-only mail UI. Provider strings are always escaped plain text."
  use MonolithWeb, :html

  alias Monolith.Mail.ViewData
  alias MonolithWeb.HomeNavigation

  attr :mail, :map, required: true
  attr :workspace, :map, default: nil
  attr :readouts, :list, default: []

  def panel(assigns) do
    # Local render assigns only; never copy provider content into the LV socket.
    data = ViewData.get(assigns.mail.data_ref)

    assigns =
      assigns
      |> assign(:account, Enum.find(assigns.mail.accounts, &(&1.id == assigns.mail.account_id)))
      |> assign(:threads, Enum.take(Map.get(data || %{}, "threads", []), 20))
      |> assign(:messages, Map.get(data || %{}, "messages", []))
      |> assign(:conversation_subject, conversation_subject(data))
      |> assign(:payload_expired, assigns.mail.data_loaded && is_nil(data))

    ~H"""
    <section
      id="mail-panel"
      class={[
        "mail-panel",
        @account && if(@mail.thread_id, do: "mail-conversation-panel", else: "mail-inbox-panel"),
        @workspace && !@account && !@mail.adding && "mail-workspace-panel"
      ]}
      aria-labelledby={if @mail.adding, do: "directory-heading", else: "mail-heading"}
      phx-hook="MailReader"
      data-mail-context={"#{@mail.list_key}:#{@account && @account.generation}"}
      data-mail-account={@mail.account_id || ""}
      data-mail-thread={@mail.thread_id || ""}
      data-mail-loaded={to_string(@mail.data_loaded && !@payload_expired)}
    >
      <div
        :if={@account}
        class={["mail-register-row page-header-row", @mail.thread_id && "mail-reader-context"]}
      >
        <p :if={!@mail.thread_id} class="mail-eyebrow">
          01 / Gmail / {if @workspace, do: @workspace.name, else: "Account"}
        </p>
        <.link
          :if={@mail.thread_id}
          id="mail-back"
          patch={HomeNavigation.mail_path(@mail, %{thread_id: nil})}
          class="workspace-action workspace-action-link"
        >Back to results</.link>
        <h2 :if={@mail.thread_id} id="mail-heading" class="mail-reader-account">
          {@account.email}
          <span :if={@workspace} class="mail-muted">{@workspace.name}</span>
        </h2>
        <.mail_tools :if={@mail.thread_id} mail={@mail} />
        <.link
          :if={!@mail.thread_id && @workspace}
          patch={HomeNavigation.workspace_path(@mail.workspace_id)}
          class="workspace-action workspace-action-link"
        >All accounts</.link>
        <.lock_control />
      </div>
      <header :if={@account && !@mail.thread_id} class="mail-heading mail-inbox-heading">
        <div class="mail-account-identity">
          <h1 id="mail-heading" tabindex="-1" data-workspace-heading>{@account.email}</h1>
        </div>
        <.form
          for={@mail.search_form}
          id="mail-search"
          class="mail-search"
          phx-submit="mail:search"
          aria-label={"Search Gmail for #{@account.email}"}
        >
          <.input
            field={@mail.search_form[:query]}
            type="search"
            label="Search this account"
            aria-label="Search Gmail"
            placeholder="Search Gmail"
            class="mail-search-input"
            maxlength="1024"
            autocomplete="off"
          />
          <button type="submit" class="workspace-action" disabled={!!@mail.command}>Search</button>
        </.form>
      </header>
      <header :if={@workspace && !@account && !@mail.adding} class="home-section-heading">
        <h2 id="mail-heading" class="section-register" tabindex="-1">
          01 / Google accounts
        </h2>
      </header>
      <h2
        :if={!@workspace && !@account && !@mail.adding}
        id="mail-heading"
        class="mail-section-register"
        tabindex="-1"
      >
        01 / Google accounts
      </h2>

      <p :if={@mail.notice} id="mail-notice" class="mail-notice" role="status">{@mail.notice}</p>
      <div :if={@mail.directory_error} class="mail-notice" role="alert">
        <p>Accounts couldn’t be loaded.</p>
        <button type="button" class="workspace-action" phx-click="mail:reload_accounts">Try again</button>
      </div>

      <div :if={!@account && !@mail.directory_error && @mail.scope != :home} id="mail-accounts">
        <div :if={@mail.memberships == [] && !@mail.adding} class="empty-state">
          <.icon name="hero-envelope" class="empty-state-mark size-6" />
          <div class="empty-state-body">
            <h4 class="empty-state-title">No Gmail accounts in this workspace</h4>
            <p class="empty-state-copy">
              Add a Gmail account to read its inbox here. Each account stays separate.
            </p>
          </div>
        </div>
        <div :if={!@mail.adding} class="mail-workspace-accounts">
          <.workspace_account
            :for={account <- @mail.accounts}
            :if={account.id in @mail.memberships}
            account={account}
            readout={Enum.find(@readouts, &(&1.id == account.id))}
            workspace={@workspace}
            busy={!!@mail.command}
          />
        </div>
        <.add_panel :if={@mail.adding} mail={@mail} workspace={@workspace} />
      </div>

      <div
        :if={@account}
        id="mail-account-view"
        class={if @mail.thread_id, do: "mail-conversation-plane", else: "mail-inbox-plane"}
      >
        <.connect
          :if={@workspace && (@account.status == :reconnect || @mail.error == :reconnect)}
          workspace={@workspace}
          account={@account}
        />
        <.link
          :if={!@workspace && (@account.status == :reconnect || @mail.error == :reconnect)}
          patch="/connections/gmail"
          class="workspace-action workspace-action-link"
        >Reconnect in Connections</.link>
        <div :if={!@mail.thread_id} class="mail-toolbar">
          <div class="mail-actions">
            <.link
              patch="/connections/gmail"
              class="workspace-action workspace-action-link"
              aria-label={"Manage connection for #{@account.email}"}
            >Manage connection</.link>
            <span class="mail-muted">Read-only</span>
            <span :if={@mail.command || @mail.loading} class="mail-muted">
              {if @mail.command, do: "Account update in progress.", else: "Read in progress."}
            </span>
            <.link
              :if={@mail.query || @mail.page_token}
              patch={HomeNavigation.mail_path(@mail, %{page_token: nil})}
              class="workspace-action workspace-action-link"
            >First page</.link>
          </div>
          <.mail_tools mail={@mail} />
        </div>

        <div id="mail-status" class="mail-status" role="status" aria-live="polite" aria-atomic="true">
          <p :if={@mail.loading} id="mail-loading" class="mail-loading">
            <.status_signal
              id="mail-loading-signal"
              state={:active}
              label={"Loading #{if @mail.thread_id, do: "conversation", else: "messages"}…"}
            />
          </p>
          <p
            :if={@mail.error}
            class={["mail-warning", @mail.error != :rate_limited && "mail-error"]}
          >
            {error_text(@mail.error)}
          </p>
          <p :if={@payload_expired} class="mail-warning">
            This local view has expired. Refresh to load it again.
          </p>
          <p :if={@mail.stale && @mail.data_loaded} class="mail-warning">
            Showing stale local mail. It may no longer match Gmail.
          </p>
        </div>

        <div :if={!@mail.thread_id} id="mail-threads" aria-busy={to_string(@mail.loading)}>
          <p :if={@mail.data_loaded && !@payload_expired && @threads == []} class="mail-empty">
            {if @mail.query, do: "No conversations match this search.", else: "Your inbox is empty."}
          </p>
          <.link
            :for={thread <- @threads}
            id={"mail-thread-#{thread["id"]}"}
            patch={HomeNavigation.mail_path(@mail, %{thread_id: thread["id"]})}
            class={["mail-thread", thread["unread"] == true && "mail-thread-unread"]}
            data-mail-open-thread
          >
            <span class="mail-thread-marker" aria-hidden="true"></span>
            <span class="mail-thread-content">
              <span class="mail-thread-sender">{present(thread["from"], "(Unknown sender)")}</span>
              <span class="mail-thread-subject">{present(thread["subject"], "(No subject)")}</span>
              <span class="mail-thread-snippet">{thread["snippet"]}</span>
            </span>
            <.mail_date id={"thread-date-#{thread["id"]}"} value={thread["date"]} />
            <span :if={thread["unread"] == true} class="sr-only">Unread in Gmail</span>
          </.link>
        </div>

        <section
          :if={@mail.thread_id}
          id="mail-conversation"
          class="mail-reader"
          aria-label="Conversation"
          aria-busy={to_string(@mail.loading)}
        >
          <header class="mail-conversation-header">
            <p class="mail-eyebrow">
              {@account.email} / Read-only conversation
            </p>
            <h1 id="mail-conversation-heading" tabindex="-1" data-workspace-heading>
              {@conversation_subject}
            </h1>
          </header>
          <p :if={@mail.data_loaded && !@payload_expired && @messages == []} class="mail-empty">
            No plain-text messages are available.
          </p>
          <details
            :for={{message, index} <- Enum.with_index(@messages)}
            id={"mail-message-#{message["id"]}"}
            class="mail-message"
            open={index == length(@messages) - 1}
            data-mail-latest={to_string(index == length(@messages) - 1)}
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary class="mail-message-summary">
              <span class="mail-message-chevron" aria-hidden="true">›</span>
              <span class="mail-message-sender">{present(message["from"], "(Unknown sender)")}</span>
              <.mail_date id={"message-date-#{message["id"]}"} value={message["date"]} />
            </summary>
            <div class="mail-message-content">
              <p
                :if={present(message["subject"], "(No subject)") != @conversation_subject}
                class="mail-message-subject"
              >
                {present(message["subject"], "(No subject)")}
              </p>
              <details
                id={"mail-message-details-#{message["id"]}"}
                class="mail-message-details"
                phx-mounted={JS.ignore_attributes("open")}
              >
                <summary>Show details<span class="sr-only"> for message {index + 1}</span></summary>
                <dl class="mail-message-meta">
                  <dt>From</dt><dd>{message["from"]}</dd>
                  <dt>To</dt><dd>{message["to"]}</dd>
                  <dt>Date</dt><dd>{message["date"]}</dd>
                </dl>
              </details>
              <p :if={message["text"] in [nil, ""]} class="mail-muted">
                No plain-text body. HTML email content is not displayed.
              </p>
              <pre :if={message["text"] not in [nil, ""]} class="mail-message-text">{message["text"]}</pre>
              <section
                :if={message["attachments"] not in [nil, []]}
                class="mail-attachments"
                aria-label={"Attachments for message #{index + 1}"}
              >
                <h5>Attachments</h5>
                <ul>
                  <li :for={attachment <- message["attachments"]} class="mail-attachment">
                    <div class="mail-attachment-meta">
                      <span class="mail-attachment-name">{attachment["filename"]}</span>
                      <span class="mail-muted">
                        {attachment["mime_type"]} · {attachment_size(attachment["size"])}
                      </span>
                    </div>
                    <a
                      :if={downloadable_attachment?(attachment["size"])}
                      class="workspace-action"
                      href={
                        attachment_path(
                          @mail.account_id,
                          @mail.thread_id,
                          message["id"],
                          attachment["attachment_id"],
                          download: true
                        )
                      }
                    >Download</a>
                    <span
                      :if={!downloadable_attachment?(attachment["size"])}
                      class="mail-muted"
                    >Larger than the 5 MiB limit</span>
                    <a
                      :if={
                        previewable_image?(attachment["mime_type"]) &&
                          downloadable_attachment?(attachment["size"])
                      }
                      class="workspace-action"
                      href={
                        attachment_path(
                          @mail.account_id,
                          @mail.thread_id,
                          message["id"],
                          attachment["attachment_id"]
                        )
                      }
                      target="_blank"
                      rel="noopener noreferrer"
                      aria-label={"Preview image #{attachment["filename"]} (opens in a new tab)"}
                    >Preview image<span class="sr-only"> (opens in a new tab)</span></a>
                  </li>
                </ul>
              </section>
            </div>
          </details>
        </section>

        <div :if={!@mail.thread_id && @mail.next_page_token} class="mail-pagination">
          <.link
            patch={HomeNavigation.mail_path(@mail, %{page_token: @mail.next_page_token})}
            class="workspace-action workspace-action-link"
          >Next page</.link>
        </div>
      </div>
    </section>
    """
  end

  attr :mail, :map, required: true

  defp mail_tools(assigns) do
    ~H"""
    <div class="mail-tools">
      <details :if={@mail.fetched_at} id="mail-observation" class="mail-observation">
        <summary>
          <span
            id="mail-freshness"
            phx-hook="MailFreshness"
            phx-update="ignore"
            data-fetched-at={DateTime.to_iso8601(@mail.fetched_at)}
            data-stale={to_string(@mail.stale || not is_nil(@mail.error))}
            data-cached={to_string(@mail.cached)}
          >
            {if @mail.cached, do: "Local copy ·", else: "Fetched ·"}
            {Calendar.strftime(@mail.fetched_at, "%Y-%m-%d %H:%M:%S UTC")}
          </span>
        </summary>
        <p>
          Fetched ·
          <time datetime={DateTime.to_iso8601(@mail.fetched_at)}>{Calendar.strftime(
            @mail.fetched_at,
            "%Y-%m-%d %H:%M:%S UTC"
          )}</time>
        </p>
      </details>
      <button
        id="mail-refresh"
        type="button"
        class="workspace-action"
        phx-click="mail:refresh"
        disabled={@mail.loading || !!@mail.command}
      >Refresh</button>
    </div>
    """
  end

  attr :account, :map, required: true
  attr :readout, :map, default: nil
  attr :workspace, :map, required: true
  attr :busy, :boolean, required: true

  defp workspace_account(assigns) do
    assigns =
      assign(
        assigns,
        :readout,
        assigns.readout ||
          %{
            id: assigns.account.id,
            email: assigns.account.email,
            workspaces: [assigns.workspace.name],
            status: assigns.account.status,
            last_error: assigns.account.last_error,
            inbox_unread_count: nil,
            inbox_unread_recent_count: nil,
            inbox_unread_at: nil,
            inbox_unread_error: nil
          }
      )

    ~H"""
    <article id={"mail-account-#{@account.id}"} class="mail-workspace-account">
      <ul class="mail-workspace-readout">
        <MonolithWeb.HomeComponents.account_readout
          account={@readout}
          inbox_path={HomeNavigation.workspace_path(@workspace.id) <> "/accounts/" <> @account.id <> "/mail"}
        />
      </ul>
      <div class="mail-workspace-account-actions">
        <.link
          patch="/connections/gmail"
          class="workspace-action workspace-action-link"
          aria-label={"Manage connection for #{@account.email}"}
        >Manage connection</.link>
        <button
          id={"detach-#{@account.id}"}
          type="button"
          class="workspace-action workspace-action-danger"
          phx-click={JS.push("mail:detach") |> JS.focus(to: "#mail-heading")}
          phx-value-id={@account.id}
          aria-label={"Remove #{@account.email} from #{@workspace.name}"}
          disabled={@busy}
        >Remove from workspace</button>
      </div>
      <div :if={@account.status == :reconnect} class="integration-recovery">
        <.connect workspace={@workspace} account={@account} busy={@busy} />
      </div>
    </article>
    """
  end

  attr :mail, :map, required: true
  attr :workspace, :map, required: true

  defp add_panel(assigns) do
    ~H"""
    <section
      id="integration-add-panel"
      class="integration-add-panel"
      aria-labelledby="integration-add-heading"
    >
      <h3 id="integration-add-heading" class="mail-section-register">Google accounts</h3>
      <p class="mail-muted mail-add-description">
        Add to <strong>{@workspace.name}</strong>. Adding an existing connection only changes
        this workspace’s membership; it doesn’t request additional Google consent.
      </p>
      <h5 class="mail-section-title">Available connections</h5>
      <p :if={!Enum.any?(@mail.accounts, &(&1.id not in @mail.memberships))} class="mail-muted">
        No other Gmail accounts are available. Connect another Google account below.
      </p>
      <div
        :for={account <- @mail.accounts}
        :if={account.id not in @mail.memberships}
        id={"mail-available-#{account.id}"}
        class="connection-row"
      >
        <div class="mail-account-identity">
          <p>{account.email}</p>
          <p class="mail-muted">
            <.account_signal account={account} id={"available-signal-#{account.id}"} />
          </p>
        </div>
        <button
          :if={account.status == :ready}
          id={"attach-#{account.id}"}
          type="button"
          class="workspace-action"
          phx-click={JS.push("mail:attach") |> JS.focus(to: "#directory-heading")}
          phx-value-id={account.id}
          disabled={!!@mail.command}
        >
          Add to workspace
        </button>
        <.connect
          :if={account.status == :reconnect}
          workspace={@workspace}
          account={account}
          busy={!!@mail.command}
        />
        <p :if={account.status == :disconnected} class="mail-muted">
          Retry credential removal in Connections.
        </p>
      </div>
      <div class="mail-connect">
        <.connect workspace={@workspace} busy={!!@mail.command} />
        <p class="mail-muted">
          Read-only Gmail. Reusable across workspaces.
        </p>
      </div>
    </section>
    """
  end

  attr :mail, :map, required: true
  attr :workspace_options, :list, required: true
  attr :google_status, :atom, required: true
  attr :readouts, :list, default: []

  def connections(assigns) do
    assigns = assign(assigns, :busy_reason, connection_busy_reason(assigns.mail))

    ~H"""
    <section
      id="connections-panel"
      class="connections-panel"
      aria-labelledby="gmail-connections-heading"
    >
      <header class="card-section-heading">
        <p class="mail-eyebrow">Google account access</p>
        <h3 id="gmail-connections-heading">Gmail accounts</h3>
        <button
          :if={@mail.accounts != [] || @mail.directory_error}
          id="new-gmail-connection"
          type="button"
          class="workspace-action workspace-action-primary provider-heading-action"
          phx-click="mail:new_connection"
          disabled={!!@mail.command || @mail.directory_error || @google_status != :stored}
          aria-describedby={connection_action_description(@busy_reason, @google_status)}
        >
          Add Gmail account
        </button>
      </header>
      <p
        :if={@google_status != :stored}
        id="gmail-google-prerequisite"
        class="mail-muted"
        role="status"
      >
        <%= if @google_status in [:unknown, :loading] do %>
          Checking Google client settings…
        <% else %>
          Set up or restore client settings in
          <.link patch="/connections/google" class="workspace-action-link">Google connections</.link>
          before adding a Gmail account.
        <% end %>
      </p>
      <p :if={@busy_reason} id="gmail-account-operation" class="mail-muted" role="status">
        {@busy_reason}
      </p>
      <div
        :if={@mail.accounts == [] && !@mail.directory_error}
        class="empty-state connection-card empty-state-card"
      >
        <.icon name="hero-envelope" class="empty-state-mark size-6" />
        <div class="empty-state-body">
          <h4 class="empty-state-title">
            {if @workspace_options == [],
              do: "Create a workspace first",
              else: "Connect your first Gmail account"}
          </h4>
          <p class="empty-state-copy">
            {if @workspace_options == [],
              do:
                "Create a workspace for your first Gmail connection. You can reuse the account in other spaces later.",
              else:
                "Read your mail here without changing it in Gmail. Each account keeps its own inbox."}
          </p>
          <.link
            :if={@workspace_options == []}
            patch="/workspaces"
            class="workspace-action workspace-action-primary"
          >
            Create a workspace
          </.link>
          <button
            :if={@workspace_options != []}
            id="new-gmail-connection"
            type="button"
            class="workspace-action workspace-action-primary"
            phx-click="mail:new_connection"
            disabled={!!@mail.command || @mail.directory_error || @google_status != :stored}
            aria-describedby={connection_action_description(@busy_reason, @google_status)}
          >
            Add Gmail account
          </button>
        </div>
      </div>
      <p :if={@mail.accounts != []} class="mail-muted">
        Read-only · Separate inboxes
      </p>
      <p :if={@mail.notice} id="mail-notice" class="mail-notice" role="status">{@mail.notice}</p>
      <div :if={@mail.directory_error} class="mail-notice" role="alert">
        <p>Connections couldn’t be loaded.</p>
        <button type="button" class="workspace-action" phx-click="mail:reload_accounts">Try again</button>
      </div>
      <div class="gmail-connection-list">
        <article
          :for={account <- @mail.accounts}
          id={"connection-account-#{account.id}"}
          class="gmail-connection-card"
          aria-labelledby={"connection-email-#{account.id}"}
        >
          <header class="connection-card-head">
            <div class="mail-account-identity">
              <h4 id={"connection-email-#{account.id}"}>{account.email}</h4>
              <p class="identity mail-muted">Gmail · Read-only</p>
            </div>
            <p class={[
              "mail-muted",
              needs_attention?(account) && "connection-warning"
            ]}>
              <.account_signal account={account} id={"connection-signal-#{account.id}"} />
            </p>
          </header>
          <.connection_memberships readout={Enum.find(@readouts, &(&1.id == account.id))} />
          <div class="mail-actions">
            <button
              :if={account.status != :disconnected}
              id={"check-credentials-#{account.id}"}
              type="button"
              class="workspace-action"
              phx-click="mail:check_credentials"
              phx-value-id={account.id}
              aria-label={"Check Keychain access for #{account.email}"}
              disabled={!!@mail.command || !!@mail.credential_check}
              aria-describedby={@busy_reason && "gmail-account-operation"}
            >Check Keychain</button>
            <.connect
              :if={account.status == :reconnect}
              account={account}
              workspace_options={@workspace_options}
              busy={!!@mail.command || !!@mail.credential_check}
              busy_description={@busy_reason && "gmail-account-operation"}
            />
            <.disconnect
              account={account}
              busy={!!@mail.command || !!@mail.credential_check}
              busy_description={@busy_reason && "gmail-account-operation"}
            />
          </div>
          <.credential_check account={account} check={credential_check_result(@mail, account)} />
          <div :if={cleanup = Map.get(account, :cleanup)} class="mail-muted" role="status">
            <p :if={cleanup.state == :pending}>
              Local account removed. Credential cleanup and Google revocation are pending.
            </p>
            <p :if={cleanup.state != :pending && !cleanup.credentials_removed}>
              Local account removed. Credential removal needs retrying.
            </p>
            <p :if={cleanup.state != :pending && cleanup.remote != :revoked}>
              Google revocation is not confirmed ({cleanup.remote}). Review <a
                href="https://myaccount.google.com/connections"
                target="_blank"
                rel="noopener noreferrer"
                class="workspace-action-link"
              >Google account access</a>.
            </p>
          </div>
        </article>
      </div>
      <MonolithWeb.ModalComponents.modal
        :if={@mail.connecting}
        id="gmail-connection-modal"
        title="Add Gmail account"
        on_cancel="mail:close_connection"
        return_focus="#new-gmail-connection"
        initial_focus="#mail-workspace-new"
      >
        <p id="gmail-connection-hint" class="mail-muted">
          Choose a workspace for this read-only account. Reuse it elsewhere anytime.
        </p>
        <.connect workspace_options={@workspace_options} busy={!!@mail.command} />
        <button
          type="button"
          class="workspace-action gmail-connection-cancel"
          phx-click="mail:close_connection"
        >Cancel</button>
      </MonolithWeb.ModalComponents.modal>
    </section>
    """
  end

  defp connection_busy_reason(%{credential_check: {id, _, _}} = mail) do
    account = Enum.find(mail.accounts, &(&1.id == id))
    identity = if account, do: account.email, else: "another Gmail account"

    "Checking local Keychain access for #{identity}. Account actions are unavailable until it finishes."
  end

  defp connection_busy_reason(%{command: {id, _}} = mail) do
    account = Enum.find(mail.accounts, &(&1.id == id))
    identity = if account, do: account.email, else: "a Gmail account"

    "Disconnect cleanup for #{identity} is pending. Account actions are unavailable until it finishes."
  end

  defp connection_busy_reason(_mail), do: nil

  defp connection_action_description(busy_reason, google_status) do
    [
      busy_reason && "gmail-account-operation",
      if(google_status != :stored, do: "gmail-google-prerequisite")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  attr :readout, :map, default: nil

  defp connection_memberships(assigns) do
    ~H"""
    <p class="mail-muted mail-memberships">
      <%= cond do %>
        <% is_nil(@readout) -> %>
          Workspace membership unavailable.
        <% @readout.workspaces == [] -> %>
          Not in a workspace.
        <% true -> %>
          Workspaces: {Enum.join(@readout.workspaces, " · ")}
      <% end %>
      <span>Calendar permission and status are independent.</span>
    </p>
    """
  end

  attr :account, :map, required: true
  attr :check, :map, default: nil

  defp credential_check(assigns) do
    ~H"""
    <div
      :if={@check}
      id={"credential-check-#{@account.id}"}
      class="credential-check mail-muted"
      role="status"
      aria-live="polite"
      aria-atomic="true"
    >
      <p class={@check.status not in [:accessible, :checking] && "connection-warning"}>
        <.status_signal
          id={"credential-check-signal-#{@account.id}"}
          state={credential_signal_state(@check.status)}
          label={credential_check_text(@check.status)}
        />
      </p>
      <p :if={@check.status == :locked}>
        An unlocked keychain can still deny this item. Review helper access in Keychain Access;
        see About Keychain access in the connection guidance. No permissions were changed.
      </p>
      <p :if={@check.status == :timeout}>
        The local helper did not respond in time. This does not establish a Google failure.
      </p>
      <p :if={@check.status == :unavailable}>
        The helper could not complete the read. Credential presence and access are unknown.
      </p>
      <p :if={@check.status == :not_found}>
        No stored credential was found for this account. Reconnect Google to restore access.
      </p>
      <p :if={@check[:checked_at]}>
        Local check ·
        <time datetime={DateTime.to_iso8601(@check.checked_at)}>{Calendar.strftime(
          @check.checked_at,
          "%Y-%m-%d %H:%M:%S UTC"
        )}</time>
        · Mail sync status is unchanged.
      </p>
    </div>
    """
  end

  defp credential_check_result(mail, account) do
    case mail.credential_check do
      {id, generation, _} when id == account.id and generation == account.generation ->
        %{status: :checking}

      _ ->
        Map.get(mail.credential_checks, account.id)
    end
  end

  defp credential_signal_state(:checking), do: :active
  defp credential_signal_state(:accessible), do: :ready
  defp credential_signal_state(_), do: :warning

  defp credential_check_text(:checking), do: "Checking local Keychain access…"
  defp credential_check_text(:accessible), do: "Credential readable · Google access not checked."

  defp credential_check_text(:locked),
    do: "Keychain access denied or interaction required (locked)."

  defp credential_check_text(:not_found), do: "Credential not found (not_found)."
  defp credential_check_text(:timeout), do: "Keychain helper timed out (timeout)."

  defp credential_check_text(:invalid_account),
    do: "Invalid local account identifier (invalid_account)."

  defp credential_check_text(:invalid_value),
    do: "Invalid stored credential format (invalid_value)."

  defp credential_check_text(:changed), do: "Connection changed. Check again."
  defp credential_check_text(_), do: "Keychain unavailable (unavailable)."

  attr :workspace, :map, default: nil
  attr :workspace_options, :list, default: []
  attr :account, :map, default: nil
  attr :busy, :boolean, default: false
  attr :busy_description, :string, default: nil

  defp connect(assigns) do
    assigns =
      assign(
        assigns,
        :form,
        to_form(
          %{
            "workspace_id" => if(assigns.workspace, do: assigns.workspace.id, else: ""),
            "expected_account_id" => if(assigns.account, do: assigns.account.id, else: "")
          },
          as: nil
        )
      )

    ~H"""
    <.form
      for={@form}
      id={"mail-connect-#{if @account, do: @account.id, else: "new"}"}
      action="/oauth/google/start"
      method="post"
      class="mail-oauth"
    >
      <p :if={!@account} class="mail-muted">
        First, save your shared client settings in <.link
          patch="/connections/google"
          class="workspace-action-link"
        >Google connections</.link>.
        Connecting here requests read-only Gmail access for the selected account.
      </p>
      <.input
        :if={@workspace}
        field={@form[:workspace_id]}
        id={"mail-workspace-#{if @account, do: @account.id, else: "new"}"}
        type="hidden"
      />
      <.input
        :if={!@workspace}
        field={@form[:workspace_id]}
        id={"mail-workspace-#{if @account, do: @account.id, else: "new"}"}
        type="select"
        label={if @account, do: "Reconnect and add to", else: "Connect and add to"}
        options={@workspace_options}
        prompt="Choose workspace"
        class="connection-workspace-select"
        required
        disabled={@busy}
        aria-describedby={@busy_description}
      />
      <.input
        :if={@account}
        field={@form[:expected_account_id]}
        id={"mail-expected-#{@account.id}"}
        type="hidden"
      />
      <button
        type="submit"
        class={["workspace-action", !@account && "workspace-action-primary"]}
        disabled={@busy}
        aria-describedby={@busy_description}
      >{if @account, do: "Reconnect Google", else: "Connect Google account"}</button>
    </.form>
    """
  end

  attr :account, :map, required: true
  attr :busy, :boolean, required: true
  attr :busy_description, :string, default: nil

  defp disconnect(assigns) do
    ~H"""
    <button
      type="button"
      class="workspace-action workspace-action-danger"
      phx-click="mail:disconnect"
      phx-value-id={@account.id}
      disabled={@busy}
      aria-describedby={@busy_description}
      data-confirm={"Disconnect #{@account.email} everywhere? This removes all its local cached mail, stored credentials, and connections from EVERY workspace, and attempts to revoke Google access. Your Gmail mailbox is not changed."}
    >Disconnect everywhere</button>
    """
  end

  attr :id, :string, required: true
  attr :value, :string, default: nil

  defp mail_date(assigns) do
    ~H"""
    <time id={@id} phx-hook="MailDate" phx-update="ignore" data-mail-date={@value} title={@value}>
      {present(@value, "Date unavailable")}
    </time>
    """
  end

  defp conversation_subject(data) do
    case Map.get(data || %{}, "messages", []) do
      [message | _] -> present(message["subject"], "(No subject)")
      _ -> "(No subject)"
    end
  end

  attr :id, :string, required: true
  attr :account, :map, required: true
  attr :embedded, :boolean, default: false

  defp account_signal(assigns) do
    ~H"""
    <.status_signal
      id={@id}
      state={account_signal_state(@account)}
      label={account_status(@account)}
      embedded={@embedded}
    />
    """
  end

  defp account_signal_state(%{status: :disconnected}), do: :offline
  defp account_signal_state(%{status: :reconnect}), do: :warning
  defp account_signal_state(%{last_error: error}) when not is_nil(error), do: :warning
  defp account_signal_state(%{last_success_at: %DateTime{}}), do: :ready
  defp account_signal_state(_), do: :unknown

  defp needs_attention?(account), do: account.status != :ready || not is_nil(account.last_error)

  defp present(value, fallback) when value in [nil, ""], do: fallback
  defp present(value, _), do: value

  defp previewable_image?(type),
    do: type in ["image/jpeg", "image/png", "image/gif", "image/webp"]

  defp attachment_size(size) when is_integer(size) and size >= 0 do
    if size < 1024, do: "#{size} B", else: "#{Float.round(size / 1024, 1)} KB"
  end

  defp attachment_size(_), do: "Size unavailable"

  defp downloadable_attachment?(size),
    do: is_integer(size) and size >= 0 and (size == 0 or size <= 5 * 1024 * 1024)

  defp attachment_path(account, thread, message, attachment, opts \\ []) do
    path =
      "/accounts/#{account}/mail/threads/#{thread}/messages/#{message}/attachments/#{attachment}"

    if Keyword.get(opts, :download, false), do: path <> "?download=1", else: path
  end

  defp account_status(%{status: :disconnected, last_error: :keychain}),
    do: "Disconnected locally. Credential removal needs retrying."

  defp account_status(%{status: :disconnected}), do: "Disconnected locally."

  defp account_status(%{status: :reconnect}), do: "Google access needs reconnecting."

  defp account_status(%{last_error: :keychain}),
    do: "Local Keychain access unavailable. Check credentials in Connections."

  defp account_status(%{last_error: :rate_limited}),
    do: "Google rate limit reached. Background checks will wait."

  defp account_status(%{last_error: error}) when not is_nil(error),
    do: "Last check could not reach Gmail."

  defp account_status(%{last_success_at: %DateTime{} = time}),
    do: "Last successful check · " <> Calendar.strftime(time, "%Y-%m-%d %H:%M UTC")

  defp account_status(_), do: "Connected · no successful Gmail check yet. Mail loads when opened."

  defp error_text(:reconnect),
    do: "Google access expired or was removed. Reconnect this account to continue."

  defp error_text(:rate_limited),
    do: "Google rate limit reached. Wait before trying Refresh again."

  defp error_text(:keychain),
    do:
      "Local credentials are unavailable. Check Keychain access in Connections; an unlocked keychain can still deny access."

  defp error_text(:provider), do: "Gmail is temporarily unavailable. Try Refresh later."

  defp error_text(_),
    do: "Offline or Gmail unavailable. No new mail could be loaded. Try Refresh when connected."
end
