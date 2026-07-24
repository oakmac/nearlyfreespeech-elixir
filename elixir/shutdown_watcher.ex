defmodule MyApp.ShutdownWatcher do
  @moduledoc """
  Checks for the existence of a shutdown sentinel file.

  If the file exists, it is deleted and the application is gracefully stopped.
  NearlyFreeSpeech's daemon manager will automatically restart the process,
  and run.sh will exec into the new release.

  Runs every 5 seconds (scheduled by `MyApp.BackgroundTasks`). This is the
  deploy mechanism: push.sh touches the sentinel file after building, this
  module notices, and the app restarts into the new release.

  Update `@shutdown_file` to match `SHUTDOWN_FILE` in push.sh.
  """

  require Logger

  @shutdown_file "/tmp/MY_APP_SHUTDOWN"

  def run do
    case File.rm(@shutdown_file) do
      :ok ->
        Logger.info("[ShutdownWatcher] Shutdown file removed — stopping gracefully")
        System.stop(0)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[ShutdownWatcher] Could not remove shutdown file: #{inspect(reason)}"
        )
    end
  end
end
