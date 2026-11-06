defmodule Lovelace.YouTube.Snapshot do
  @moduledoc false
  alias Lovelace.Google.Access
  alias Lovelace.Repo

  def enabled?(%{youtube_enabled: true, status: :ready}), do: true
  def enabled?(_), do: false

  def current?(account, state),
    do: enabled?(account) && state && state.generation == account.generation

  def recent?(%DateTime{} = at), do: DateTime.diff(DateTime.utc_now(), at) in 0..86_399
  def recent?(_), do: false

  def build(account, prior, failure \\ nil) do
    enabled = enabled?(account)
    state = current_state(account, prior)
    catalog = recent_field?(state, :catalog_at)
    feed = recent_field?(state, :fetched_at)
    pending = !!(state && pending?(state))
    loading = loading?(state, pending)
    error = snapshot_error(account, state, failure, enabled, pending)
    videos = if feed, do: state.videos, else: []

    %{
      available: is_nil(failure),
      enabled: enabled,
      status: if(failure, do: :error, else: status(enabled, state, feed, videos, loading, error)),
      channels: cached(state, :channels, catalog, []),
      selected_ids: cached(state, :selected_ids, state, []),
      videos: videos,
      fetched_at: cached(state, :fetched_at, feed, nil),
      error: error,
      truncated: truncated?(state, feed),
      loading: loading,
      generation: if(enabled, do: account.generation),
      revision: cached(state, :revision, state, nil),
      cooldown_until: cached(state, :cooldown_until, state, nil)
    }
  end

  defp current_state(account, prior), do: if(current?(account, prior), do: prior)
  defp recent_field?(nil, _), do: nil
  defp recent_field?(state, field), do: recent?(Map.fetch!(state, field))
  defp loading?(nil, _), do: false
  defp loading?(state, pending), do: state.loading && pending

  defp cached(state, field, present, default),
    do: if(present, do: Map.fetch!(state, field), else: default)

  defp truncated?(nil, _), do: false
  defp truncated?(state, feed), do: !!(state.catalog_truncated || (feed && state.truncated))

  defp snapshot_error(_, _, failure, _, _) when not is_nil(failure), do: failure

  defp snapshot_error(%{youtube_enabled: true, status: :reconnect}, _, _, _, _),
    do: :reconnect

  defp snapshot_error(account, state, _, enabled, pending) do
    cond do
      enabled && Access.cooldown?(account) -> :rate_limited
      state && state.loading && !pending -> :unavailable
      state -> state.error
      true -> nil
    end
  end

  # Queue delay is not execution time: only a claimed read has a two-minute lease.
  def pending?(%{loading: true, job_id: id} = state) when is_integer(id) do
    valid = is_nil(state.started_at) || executing?(state)

    valid &&
      match?(
        %Oban.Job{state: status}
        when status in ["available", "scheduled", "executing", "retryable"],
        Repo.get(Oban.Job, id)
      )
  end

  def pending?(_), do: false

  def executing?(%{started_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at) in 0..119

  def executing?(_), do: false

  defp status(false, _, _, _, _, _), do: :disabled
  defp status(true, _, _, _, true, _), do: :loading
  defp status(true, _, false, _, _, error) when not is_nil(error), do: :error
  defp status(true, nil, _, _, _, _), do: :loading
  defp status(true, _, false, _, _, _), do: :loading

  defp status(true, state, _, videos, _, error) do
    cond do
      error != nil or DateTime.diff(DateTime.utc_now(), state.fetched_at) >= 900 -> :stale
      videos == [] -> :empty
      true -> :ready
    end
  end
end
