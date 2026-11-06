defmodule Lovelace.Google.OAuthProvider do
  @moduledoc """
  Application-owned Google authorization, identity and grant-lifecycle contract.

  This is separate from replay-safe `Lovelace.Mail.Provider` reads and from native
  credential storage/HTTP transport contracts. The concrete Google adapter may
  read the shared Desktop client credentials at the wire boundary; it must not
  discover application policy or callback configuration through orchestration.
  Each provider operation is bounded by one deadline, at most 30 seconds.

  Authorization uses the approved loopback callback, PKCE and Gmail-only consent
  unless Calendar or YouTube is explicitly requested. Previously enabled optional
  capabilities may be retained in `:capabilities`; they must never include a newly
  unrequested optional capability. The caller owns state/session binding,
  one-use authorization codes, durable exchange claims and generation fencing.
  Token maps are private transient results: expiry is seconds, omitted refresh
  tokens are absent rather than nil, and scope lists are consent evidence rather
  than permission to silently widen access. Preserve an existing refresh token
  only after matching the same immutable Google subject, never an email address.

  An exchange error after a durable claim does not prove the code was unconsumed;
  an uncertain exchange requires fresh authorization, not automatic replay.
  Refresh does not promise refresh-token rotation and is distinct from a rotating
  token provider's one-shot contract. The application coordinates shared refresh.

  `revoke/1` returns `:ok` only after provider acknowledgement. Any error leaves
  remote revocation unverified; timeout, transport failure or an invalid response
  may follow a successful remote effect. Missing local credentials are not proof
  of revocation. Local credential removal and confirmed remote revocation must be
  tracked separately, with account-settings recovery for uncertain outcomes.

  Only the finite safe error categories below cross this boundary. Never include
  credentials, authorization codes, requests, provider responses or exceptions in
  errors, logs, telemetry, job arguments or persisted operation metadata.
  """

  @type error ::
          :timeout
          | :response_too_large
          | :transport_error
          | :invalid_configuration
          | :invalid_request
          | :invalid_response
          | :invalid_grant
          | :unauthorized
          | :forbidden
          | :not_found
          | :rate_limited
          | :provider_error
          | :locked
          | :unavailable
  @type failure :: {:error, error()}
  @type tokens :: %{
          required(:access_token) => binary(),
          required(:expires_in) => pos_integer(),
          optional(:refresh_token) => binary(),
          optional(:scopes) => [binary()]
        }
  @type authorization :: %{
          required(:state) => binary(),
          required(:verifier) => binary(),
          required(:redirect_uri) => binary(),
          optional(:capability) => :gmail | :calendar | :youtube,
          optional(:capabilities) => [:calendar | :youtube]
        }
  @type identity :: %{subject: binary(), email: binary()}

  @callback authorization_url(authorization()) :: {:ok, binary()} | failure()
  @callback exchange_code(binary(), binary(), binary()) :: {:ok, tokens()} | failure()
  @callback refresh(binary()) :: {:ok, tokens()} | failure()
  @callback identity(binary()) :: {:ok, identity()} | failure()
  @callback revoke(binary()) :: :ok | failure()
end
