defmodule MyApp.BackgroundTasks do
  @moduledoc """
  A tick-based background task scheduler.

  Fires once per second, aligned to the wall clock. On each tick, calls named
  interval functions (`every_five_seconds/1`, `every_five_minutes/1`, etc.)
  based on the current UTC time.

  Tasks are spawned under `MyApp.TaskSupervisor` so they run asynchronously
  and do not block the scheduler.

  Two tasks are wired up out of the box:

  - `MyApp.ShutdownWatcher` every 5 seconds — the deploy mechanism.
  - `MyApp.VmStatsLogger` every 5 minutes — a VM health breadcrumb trail.

  Add your own intervals as needed; the commented example shows the pattern.

  ## Setup

  Add to your supervision tree in `application.ex`:

      children = [
        # ... your other children
        {Task.Supervisor, name: MyApp.TaskSupervisor},
        MyApp.BackgroundTasks
      ]

  ## Design

  The interval functions receive the current UTC `DateTime` so they can make
  time-based decisions. Intervals which divide evenly into each other fire on
  the same tick; this is fine because the tasks run asynchronously.
  """

  use GenServer

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    schedule_next_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()
    unix = DateTime.to_unix(now)

    if rem(unix, 5) == 0, do: every_five_seconds(now)
    if rem(unix, 300) == 0, do: every_five_minutes(now)
    if rem(unix, 3600) == 0, do: every_hour(now)

    schedule_next_tick()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Interval functions
  # ---------------------------------------------------------------------------

  defp every_five_seconds(_now) do
    spawn_task(&MyApp.ShutdownWatcher.run/0)
  end

  defp every_five_minutes(_now) do
    spawn_task(&MyApp.VmStatsLogger.run/0)
  end

  defp every_hour(now) do
    # Replace :ok with your task. This example runs only at 10am UTC.
    if now.hour == 10 do
      # spawn_task(&MyApp.SomeDaily.run/0)
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp spawn_task(fun) do
    Task.Supervisor.start_child(MyApp.TaskSupervisor, fun)
  end

  defp schedule_next_tick do
    now = System.system_time(:millisecond)
    ms_until_next_second = 1000 - rem(now, 1000)
    Process.send_after(self(), :tick, ms_until_next_second)
  end
end
