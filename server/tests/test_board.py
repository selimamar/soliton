"""The board: the app's to-do cards, kept on the server."""

from __future__ import annotations

from conftest import TOKEN

CARD = {
    "title": "Sweep modes 12 to 32",
    "project": "FNO paper",
    "column": "todo",
    "position": 1.5,
    "notes": "Plateau near 40k.",
    "checklist": [{"text": "Copy settings", "done": True}, {"text": "Submit sweep"}],
    "links": [{"kind": "run", "id": "fno-ns-hires"},
              {"kind": "dataset", "id": "ns2d", "server": "https://lab.example.org"}],
    "tag": "sweep-modes",
    "due": "2026-11-18",
}


def test_an_empty_server_has_an_empty_board(client):
    assert client.get("/api/board").json() == []


def test_cards_are_added_replaced_and_removed(client, clock):
    response = client.put("/api/board/c1", json=CARD)
    assert response.status_code == 200, response.text
    card = response.json()
    assert card["id"] == "c1"
    assert card["checklist"][1] == {"text": "Submit sweep", "done": False}
    assert card["links"][0] == {"kind": "run", "id": "fno-ns-hires", "server": ""}
    assert (card["tag"], card["due"], card["position"]) == ("sweep-modes", "2026-11-18", 1.5)
    assert card["createdAt"] == card["updatedAt"]

    clock.advance(minutes=5)
    moved = client.put("/api/board/c1", json={**CARD, "column": "running", "tag": None}).json()
    assert (moved["column"], moved["tag"]) == ("running", None)
    assert moved["createdAt"] == card["createdAt"] != moved["updatedAt"]
    assert [c["column"] for c in client.get("/api/board").json()] == ["running"]

    assert client.delete("/api/board/c1").status_code == 204
    assert client.delete("/api/board/c1").status_code == 204, "already gone is done"
    assert client.get("/api/board").json() == []


def test_cards_come_in_board_order(client):
    for card_id, project, column, position in [
        ("a", "B", "todo", 0), ("b", "A", "todo", 2), ("c", "A", "todo", 1), ("d", "A", "done", 0),
    ]:
        client.put(f"/api/board/{card_id}",
                   json={"title": card_id, "project": project, "column": column, "position": position})
    assert [c["id"] for c in client.get("/api/board").json()] == ["d", "c", "b", "a"]


def test_bad_cards_are_rejected(client):
    for body in ({"title": ""}, {"title": "x" * 201}, {"title": "x", "column": "later"},
                 {"title": "x", "due": "18 Nov"}, {"title": "x", "notes": "x" * 10_001},
                 {"title": "x", "links": [{"kind": "paper", "id": "a"}]},
                 {"title": "x", "links": [{"kind": "run", "id": "../etc"}]},
                 {"title": "x", "checklist": [{"text": ""}]}):
        assert client.put("/api/board/c1", json=body).status_code == 422, body
    assert client.put("/api/board/bad~id", json={"title": "x"}).status_code == 422


def test_the_board_needs_the_main_token(client):
    assert client.get("/api/board", headers={"Authorization": ""}).status_code == 401
    job = client.post("/api/job-token").json()["token"]
    headers = {"Authorization": f"Bearer {job}"}
    assert client.get("/api/board", headers=headers).status_code == 403
    assert client.put("/api/board/c1", json=CARD, headers=headers).status_code == 403


def test_board_changes_are_announced_live(client):
    with client.websocket_connect("/api/live") as ws:
        ws.send_json({"type": "auth", "token": TOKEN})
        assert ws.receive_json()["type"] == "ready"
        client.put("/api/board/c1", json=CARD)
        assert ws.receive_json() == {"type": "board", "event": "updated", "cardId": "c1"}
        client.delete("/api/board/c1")
        assert ws.receive_json() == {"type": "board", "event": "deleted", "cardId": "c1"}
