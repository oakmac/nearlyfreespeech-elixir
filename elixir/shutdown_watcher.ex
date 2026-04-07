defmodule MyApp.ShutdownWatcher do
  @moduledoc """
  Watches for a shutdown sentinel file on disk.

  When the file is detected, it is deleted and the application is gracefully
  stopped via `System.stop(0)`. NearlyFreeSpeech's daemon manager will
  automatically restart the process.

  This is used during deploys: the push script creates the sentinel file,
  this module detects it, and the app shuts down so NFS can restart it with
  the new release.

  ## Usage

  Call `MyApp.ShutdownWatcher.check/0` periodically from a background task
  (eg every 5-10 seconds). See `MyApp.BackgroundTasks` for an example.

  ## Configuration

  Set the shutdown file path to match what your deploy script creates.
  The default matches the `SHUTDOWN_FILE` in `push.sh`.
  """

  require Logger

  @shutdown_file "/tmp/MY_APP_SHUTDOWN"

  @doc """
  Checks for the shutdown sentinel file. If found, deletes it and stops the app.
  """
  def check do
    if File.exists?(@shutdown_file) do
      Logger.info("[ShutdownWatcher] Shutdown file detected. Stopping...")
      File.rm(@shutdown_file)
      System.stop(0)
    end
  end
end