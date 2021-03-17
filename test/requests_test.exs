defmodule RequestsTest do
  use ExUnit.Case, async: true

  test "it works" do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    Bypass.expect(bypass, "GET", "/200", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    Bypass.expect(bypass, "GET", "/json", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json; charset=utf-8")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"x" => 1}))
    end)

    Bypass.expect(bypass, "GET", "/csv", fn conn ->
      body = NimbleCSV.RFC4180.dump_to_iodata([~w(x y), ~w(1 1), ~w(2 2)])

      conn
      |> Plug.Conn.put_resp_content_type("text/csv; charset=utf-8")
      |> Plug.Conn.send_resp(200, body)
    end)

    Bypass.expect(bypass, "GET", "/404", fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end)

    assert Requests.get!(base_url <> "/200").status == 200
    assert Requests.get!(base_url <> "/200", headers: [{"user-agent", "requests"}]).status == 200
    assert Requests.get!(base_url <> "/200", headers: [user_agent: "requests"]).status == 200
    assert Requests.get!(base_url <> "/404").status == 404

    assert Requests.get!(base_url <> "/json").body == %{"x" => 1}

    assert Requests.get!(base_url <> "/csv").body == [
             ~w(x y),
             ~w(1 1),
             ~w(2 2)
           ]

    Bypass.expect(bypass, "GET", "/gzip", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-encoding", "gzip")
      |> Plug.Conn.send_resp(200, :zlib.gzip("foo"))
    end)

    assert Requests.get!(base_url <> "/gzip").body == "foo"

    :ok = Bypass.down(bypass)

    assert_raise Mint.TransportError, ~r/connection refused/, fn ->
      Requests.get!(base_url <> "/200")
    end
  end
end
