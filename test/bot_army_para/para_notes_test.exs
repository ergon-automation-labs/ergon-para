defmodule BotArmyPara.ParaNotesTest do
  use ExUnit.Case
  @moduletag :core

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "bot_army_para_notes_test_#{System.unique_integer([:positive])}"
      )

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

  test "capture_append writes inbox bot log", %{tmp_dir: tmp_dir} do
    payload = %{
      "schema_version" => "1.0",
      "source_bot" => "rpg",
      "summary" => "session joined",
      "details" => "character entered tavern",
      "topic" => "bridge.rpg.session.join"
    }

    assert {:ok, data} = BotArmyPara.ParaNotes.capture_append(payload)
    assert data["relative_path"] == "inbox/bots/rpg.md"

    body = File.read!(Path.join(tmp_dir, "inbox/bots/rpg.md"))
    assert body =~ "session joined"
    assert body =~ "character entered tavern"
  end

  test "capture_append respects custom path field", %{tmp_dir: tmp_dir} do
    payload = %{
      "schema_version" => "1.0",
      "source_bot" => "test",
      "path" => "projects/test_project/DAILY_LOG.md",
      "summary" => "custom path test"
    }

    assert {:ok, data} = BotArmyPara.ParaNotes.capture_append(payload)
    assert data["relative_path"] == "projects/test_project/DAILY_LOG.md"

    body = File.read!(Path.join(tmp_dir, "projects/test_project/DAILY_LOG.md"))
    assert body =~ "custom path test"
  end

  test "capture_append respects relative_path field", %{tmp_dir: tmp_dir} do
    payload = %{
      "schema_version" => "1.0",
      "source_bot" => "test",
      "relative_path" => "areas/work/LOG.md",
      "summary" => "relative path test"
    }

    assert {:ok, data} = BotArmyPara.ParaNotes.capture_append(payload)
    assert data["relative_path"] == "areas/work/LOG.md"

    body = File.read!(Path.join(tmp_dir, "areas/work/LOG.md"))
    assert body =~ "relative path test"
  end

  test "route_note prefers project weekly log", %{tmp_dir: tmp_dir} do
    payload = %{
      "schema_version" => "1.0",
      "source_bot" => "synapse",
      "summary" => "deployed para bot",
      "project_ref" => "Dark Software Factory"
    }

    assert {:ok, data} = BotArmyPara.ParaNotes.route_note(payload)
    assert data["route"] == "projects/dark_software_factory/WEEKLY_LOG.md"
    assert File.read!(Path.join(tmp_dir, data["route"])) =~ "deployed para bot"
  end

  test "digest_generate writes digest from provided sources", %{tmp_dir: tmp_dir} do
    source_path = Path.join(tmp_dir, "inbox/bots/rpg.md")
    File.mkdir_p!(Path.dirname(source_path))
    File.write!(source_path, "hello from rpg")

    payload = %{
      "schema_version" => "1.0",
      "source_paths" => ["inbox/bots/rpg.md"],
      "target_path" => "inbox/review_digest.md",
      "title" => "Daily Digest"
    }

    assert {:ok, data} = BotArmyPara.ParaNotes.digest_generate(payload)
    assert data["relative_path"] == "inbox/review_digest.md"

    digest = File.read!(Path.join(tmp_dir, "inbox/review_digest.md"))
    assert digest =~ "Daily Digest"
    assert digest =~ "hello from rpg"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
