defmodule Kernel.ParallelRequire do
  @moduledoc """
  A module responsible for requiring files in parallel.
  """

  @doc """
  Requires the given files.

  A callback that is invoked every time a file is required
  can be optionally given as argument.

  Returns the modules generated by each required file.
  """
  def files(files, callback \\ fn x -> x end) do
    compiler_pid = self()
    :elixir_code_server.cast({:reset_warnings, compiler_pid})
    schedulers = max(:erlang.system_info(:schedulers_online), 2)
    result = spawn_requires(files, [], callback, schedulers, [])

    # In case --warning-as-errors is enabled and there was a warning,
    # compilation status will be set to error.
    case :elixir_code_server.call({:compilation_status, compiler_pid}) do
      :ok ->
        result
      :error ->
        IO.puts :stderr, "Compilation failed due to warnings while using the --warnings-as-errors option"
        exit({:shutdown, 1})
    end
  end

  defp spawn_requires([], [], _callback, _schedulers, result), do: result

  defp spawn_requires([], waiting, callback, schedulers, result) do
    wait_for_messages([], waiting, callback, schedulers, result)
  end

  defp spawn_requires(files, waiting, callback, schedulers, result) when length(waiting) >= schedulers do
    wait_for_messages(files, waiting, callback, schedulers, result)
  end

  defp spawn_requires([h|t], waiting, callback, schedulers, result) do
    parent = self()
    {pid, ref} = :erlang.spawn_monitor fn ->
      :erlang.put(:elixir_compiler_pid, parent)

      exit(try do
        new = Code.require_file(h) || []
        {:required, Enum.map(new, &elem(&1, 0)), h}
      catch
        kind, reason ->
          {:failure, kind, reason, System.stacktrace}
      end)
    end

    spawn_requires(t, [{pid, ref}|waiting], callback, schedulers, result)
  end

  defp wait_for_messages(files, waiting, callback, schedulers, result) do
    receive do
      {:DOWN, ref, :process, pid, status} ->
        tuple = {pid, ref}
        if tuple in waiting do
          case status do
            {:required, mods, file} ->
              callback.(file)
              result  = mods ++ result
              waiting = List.delete(waiting, tuple)
            {:failure, kind, reason, stacktrace} ->
              :erlang.raise(kind, reason, stacktrace)
            other ->
              :erlang.raise(:exit, other, [])
          end
        end
        spawn_requires(files, waiting, callback, schedulers, result)
      {:module_available, child, ref, _, _, _} ->
        send(child, {ref, :ack})
        spawn_requires(files, waiting, callback, schedulers, result)
      {:struct_available, _} ->
        spawn_requires(files, waiting, callback, schedulers, result)
      {:waiting, :struct, child, ref, _} ->
        send(child, {ref, :release})
        spawn_requires(files, waiting, callback, schedulers, result)
    end
  end
end
