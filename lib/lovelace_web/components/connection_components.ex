defmodule LovelaceWeb.ConnectionComponents do
  @moduledoc "Global connection directory; provider health belongs to each management page."
  use LovelaceWeb, :html

  def overview(assigns) do
    ~H"""
    <nav id="connections-overview" class="connections-overview" aria-label="Connections">
      <.link id="open-connection-google" patch="/connections/google" class="connection-provider">
        <.icon name="hero-key" class="size-6" />
        <span class="connection-provider-copy">
          <span class="connection-provider-name">Google</span>
          <span class="mail-muted">Shared Gmail, Calendar &amp; YouTube client settings</span>
        </span>
        <.icon name="hero-arrow-up-right" class="size-5" />
      </.link>
      <.link id="open-connection-gmail" patch="/connections/gmail" class="connection-provider">
        <.icon name="hero-envelope" class="size-6" />
        <span class="connection-provider-copy">
          <span class="connection-provider-name">Gmail</span>
          <span class="mail-muted">Read-only mail</span>
        </span>
        <.icon name="hero-arrow-up-right" class="size-5" />
      </.link>
      <.link id="open-connection-calendar" patch="/connections/calendar" class="connection-provider">
        <.icon name="hero-calendar-days" class="size-6" />
        <span class="connection-provider-copy">
          <span class="connection-provider-name">Calendar</span>
          <span class="mail-muted">Read-only agendas</span>
        </span>
        <.icon name="hero-arrow-up-right" class="size-5" />
      </.link>
      <.link id="open-connection-youtube" patch="/connections/youtube" class="connection-provider">
        <.icon name="hero-play-circle" class="size-6" />
        <span class="connection-provider-copy">
          <span class="connection-provider-name">YouTube</span>
          <span class="mail-muted">Selected subscriptions · read-only</span>
        </span>
        <.icon name="hero-arrow-up-right" class="size-5" />
      </.link>
      <.link id="open-connection-github" patch="/connections/github" class="connection-provider">
        <.icon name="hero-code-bracket" class="size-6" />
        <span class="connection-provider-copy">
          <span class="connection-provider-name">GitHub</span>
          <span class="mail-muted">Pull requests, issues &amp; Actions</span>
        </span>
        <.icon name="hero-arrow-up-right" class="size-5" />
      </.link>
      <.link id="open-connection-gemini" patch="/connections/gemini" class="connection-provider">
        <.icon name="hero-sparkles" class="size-6" />
        <span class="connection-provider-copy">
          <span class="connection-provider-name">Gemini</span>
          <span class="mail-muted">Scenery API key</span>
        </span>
        <.icon name="hero-arrow-up-right" class="size-5" />
      </.link>
    </nav>
    """
  end
end
