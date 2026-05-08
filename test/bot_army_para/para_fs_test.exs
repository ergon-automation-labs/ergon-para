defmodule BotArmyPara.ParaFsTest do
  use ExUnit.Case
  @moduletag :core

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "bot_army_para_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    previous_root = System.get_env("PARA_FS_ROOT")
    previous_token = System.get_env("PARA_FS_WRITE_TOKEN")

    System.put_env("PARA_FS_ROOT", tmp_dir)
    System.delete_env("PARA_FS_WRITE_TOKEN")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      restore_env("PARA_FS_ROOT", previous_root)
      restore_env("PARA_FS_WRITE_TOKEN", previous_token)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "writes content under allowed prefix", %{tmp_dir: tmp_dir} do
    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "inbox/bots/note.md",
      "content" => "hello"
    }

    assert {:ok, data} = BotArmyPara.ParaFs.handle_write(payload)
    assert data["bytes_written"] == 5
    assert File.read!(Path.join(tmp_dir, "inbox/bots/note.md")) == "hello"
  end

  test "rejects traversal escapes" do
    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "../etc/passwd",
      "content" => "bad"
    }

    assert {:error, _message, :validation_error} = BotArmyPara.ParaFs.handle_write(payload)
  end

  test "requires auth token when configured" do
    System.put_env("PARA_FS_WRITE_TOKEN", "top-secret")

    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "inbox/bots/secure.md",
      "content" => "hello"
    }

    assert {:error, _message, :forbidden} = BotArmyPara.ParaFs.handle_write(payload)

    payload_with_token = Map.put(payload, "auth_token", "top-secret")
    assert {:ok, _data} = BotArmyPara.ParaFs.handle_write(payload_with_token)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
