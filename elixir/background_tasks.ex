defmodule MyApp.BackgroundTasks do
  @moduledoc """
  A tick-based background task scheduler.

  Fires once per second, aligned to the wall clock. On each tick, runs
  scheduled tasks based on the current time.

  ## Setup

  Add this module and a `Task.Supervisor` to your application's supervision tree:

      children = [
        # ... your other children (Repo, Endpoint, etc.)
        {Task.Supervisor, name: MyApp.TaskSupervisor},
        MyApp.BackgroundTasks
      ]

  ## Adding tasks

  To run something every N seconds, add a clause to `handle_info/2`:

      if rem(unix, 60) == 0, do: spawn_task(&MyApp.SomeModule.some_function/0)

  Tasks are spawned under `MyApp.TaskSupervisor` so they run asynchronously
  and don't block the scheduler.
  """

  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    schedule_next_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = DateTime.utc_now()
    unix = DateTime.to_unix(now)

    # Check for shutdown file every 5 seconds
    if rem(unix, 5) == 0 do
      spawn_task(&MyApp.ShutdownWatcher.check/0)
    end

    # Add your own periodic tasks here. Examples:
    #
    #   if rem(unix, 30) == 0, do: spawn_task(&MyApp.SomeTask.run/0)
    #   if rem(unix, 3600) == 0, do: spawn_task(&MyApp.HourlyTask.run/0)

    schedule_next_tick()
    {:noreply, state}
  end

  defp spawn_task(fun) do
    Task.Supervisor.start_child(MyApp.TaskSupervisor, fun)
  end

  defp schedule_next_tick do
    now = System.system_time(:millisecond)
    ms_until_next_second = 1000 - rem(now, 1000)
    Process.send_after(self(), :tick, ms_until_next_second)
  end
end