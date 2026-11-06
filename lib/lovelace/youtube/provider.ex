defmodule Lovelace.YouTube.Provider do
  @moduledoc "Read-only bounded YouTube pages. Domain owns pagination, selection and publication."
  @type failure :: {:error, atom()}
  @callback subscriptions(binary(), binary() | nil) ::
              {:ok, %{channels: [map()], next_page: binary() | nil}} | failure()
  @callback uploads_playlists(binary(), [binary()]) :: {:ok, %{binary() => binary()}} | failure()
  @callback uploads(binary(), binary()) ::
              {:ok, %{videos: [map()], truncated: boolean()}} | failure()
end
