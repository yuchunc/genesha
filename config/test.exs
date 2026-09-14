import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ganesha, Ganesha.Repo,
  database: Path.expand("../ganesha_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :ganesha, Oban, testing: :manual, queues: false, plugins: false

config :ganesha, :line,
  channel_secret: "test_channel_secret",
  channel_access_token: "test_channel_access_token",
  teacher_line_user_id: "Uteacher0000000000000000000000"

config :ganesha, :assistant, provider: Ganesha.Assistant.Provider.Mock

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ganesha, GaneshaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ZIfPtOMIRoZ1k3wkDjsraisjHb8zZur3FTv+nVJxcuoSghkU2/h0fUMhr1b61/ua",
  server: false

# In test we don't send emails
config :ganesha, Ganesha.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :ganesha, :line_client, Ganesha.Line.Client.Mock
