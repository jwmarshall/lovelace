defmodule MonolithWeb.StatusComponents do
  @moduledoc "Canonical decorative signals paired with explicit observed-state text."
  use Phoenix.Component

  attr :id, :string, required: true

  attr :state, :atom,
    required: true,
    values: [:active, :ready, :unknown, :waiting, :warning, :offline]

  attr :label, :string, required: true
  attr :embedded, :boolean, default: false
  attr :tone, :atom, default: :auto, values: [:auto, :error]

  # Canonical signal geometry lives here; status.css owns motion and styling.
  # A signal never becomes a keyboard stop or loader logo.
  def status_signal(assigns) do
    ~H"""
    <span
      id={@id}
      class={["status-signal", @embedded && "status-signal-embedded"]}
      data-state={@state}
      data-tone={if @tone != :auto, do: @tone}
    >
      <svg
        class={["status-glyph", "monolith-#{signal_name(@state)}"]}
        viewBox="0 0 24 24"
        fill="none"
        aria-hidden="true"
        focusable="false"
      >
        <%= case @state do %>
          <% :ready -> %>
            <g class="check"><path d="M5 12L10 17" /><path d="M10 17L19 8" /></g>
          <% :active -> %>
            <rect class="northwest" x="5" y="5" width="5" height="5" />
            <rect class="northeast" x="14" y="5" width="5" height="5" />
            <rect class="southeast" x="14" y="14" width="5" height="5" />
            <rect class="southwest" x="5" y="14" width="5" height="5" />
          <% :unknown -> %>
            <path class="hook" d="M7 8V5H17V11H12V14" /><rect
              class="dot"
              x="11"
              y="18"
              width="2"
              height="2"
            />
          <% :waiting -> %>
            <rect x="5" y="4" width="14" height="2" /><rect
              class="upper"
              x="8"
              y="8"
              width="8"
              height="2"
            />
            <rect class="waist" x="11" y="11" width="2" height="2" /><rect
              class="lower"
              x="8"
              y="14"
              width="8"
              height="2"
            />
            <rect x="5" y="18" width="14" height="2" />
          <% :offline -> %>
            <path class="left" d="M9 6H4V18H9M7 12H10" /><path
              class="right"
              d="M15 6H20V18H15M14 12H17"
            />
          <% :warning -> %>
            <path class="triangle" pathLength="1" d="M11 3H13L22 19L21 21H3L2 19Z" />
            <path class="exclamation" d="M12 9V14M12 18V18.01" />
        <% end %>
      </svg>
      <span class="status-label">{@label}</span>
    </span>
    """
  end

  defp signal_name(:ready), do: "healthy"
  defp signal_name(:active), do: "loading"
  defp signal_name(:unknown), do: "unknown"
  defp signal_name(:waiting), do: "waiting"
  defp signal_name(:offline), do: "disconnected"
  defp signal_name(:warning), do: "attention"
end
