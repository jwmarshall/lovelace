defmodule LovelaceWeb.Router do
  use LovelaceWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LovelaceWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; frame-src https://www.youtube-nocookie.com; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
    }
  end

  pipeline :owner do
    plug LovelaceWeb.Plugs.RequireOwner
    plug LovelaceWeb.WorkspaceReturn, :consume
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :stage_image do
    plug :accepts, ["png", "jpg"]

    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'"
    }
  end

  scope "/stage", LovelaceWeb do
    pipe_through :stage_image
    get "/background/:filename", StageBackgroundController, :show
  end

  scope "/", LovelaceWeb do
    pipe_through :browser

    get "/setup", SetupController, :show
    get "/unlock", OwnerController, :new
    post "/unlock", OwnerController, :create
    post "/lock", OwnerController, :delete
  end

  scope "/", LovelaceWeb do
    pipe_through [:browser, :owner]

    get "/onboarding", OnboardingController, :index
    get "/onboarding/:step", OnboardingController, :show
    post "/onboarding/:step", OnboardingController, :update

    post "/oauth/google/start", GoogleOAuthController, :create

    get "/accounts/:account_id/mail/threads/:thread_id/messages/:message_id/attachments/:attachment_id",
        MailAttachmentController,
        :show

    live_session :owner,
      on_mount: [{LovelaceWeb.OwnerAuth, :require_owner}],
      session: {LovelaceWeb.WorkspaceReturn, :live_session, []} do
      live "/", HomeLive, :index
      live "/workspaces", HomeLive, :workspaces
      live "/workspaces/:workspace_id", HomeLive, :workspace
      live "/workspaces/:workspace_id/integrations", HomeLive, :integration_add
      live "/workspaces/:workspace_id/accounts/:account_id/mail", HomeLive, :workspace_inbox

      live "/workspaces/:workspace_id/accounts/:account_id/mail/threads/:thread_id",
           HomeLive,
           :workspace_thread

      live "/accounts/:account_id/mail", HomeLive, :inbox
      live "/accounts/:account_id/mail/threads/:thread_id", HomeLive, :thread
      live "/accounts/:account_id/youtube", HomeLive, :youtube
      live "/accounts/:account_id/youtube/videos/:video_id", HomeLive, :youtube_video
      live "/connections", HomeLive, :connections
      live "/connections/:provider", HomeLive, :connection
      live "/scenes", HomeLive, :scenes
      live "/settings", HomeLive, :settings
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", LovelaceWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:lovelace, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser, :owner]

      live_dashboard "/dashboard", metrics: LovelaceWeb.Telemetry
    end
  end
end
