defmodule MyApp.VmStatsLogger do
  @moduledoc """
  Logs a small snapshot of BEAM VM health every five minutes.

  The last `[VmStats]` line before an unexpected restart gives you a useful
  breadcrumb: BEAM allocator memory, process and port counts, and VM uptime.
  These memory values come from `:erlang.memory/0`; they are not the operating
  system's complete resident-set-size measurement.

  A sustained climb across many samples may indicate growing memory pressure.
  `uptime_min` resetting to a small number reveals that the VM restarted.
  """

  require Logger

  def run do
    mem = :erlang.memory()
    {uptime_ms, _since_last} = :erlang.statistics(:wall_clock)

    Logger.info(
      "[VmStats] " <>
        "beam_mem_total=#{mb(mem[:total])}MB " <>
        "beam_mem_procs=#{mb(mem[:processes])}MB " <>
        "beam_mem_binary=#{mb(mem[:binary])}MB " <>
        "beam_mem_ets=#{mb(mem[:ets])}MB " <>
        "procs=#{:erlang.system_info(:process_count)} " <>
        "ports=#{:erlang.system_info(:port_count)} " <>
        "uptime_min=#{div(uptime_ms, 60_000)}"
    )
  end

  defp mb(bytes), do: Float.round(bytes / 1_048_576, 1)
end
