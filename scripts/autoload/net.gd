extends Node
## Session transport + clock sync.
##
## Same game code runs in every mode: single-player is a local host (OfflineMultiplayerPeer),
## LAN/direct uses ENet, and Steam uses GodotSteam's SteamMultiplayerPeer over Steam Datagram
## Relay (GDD 10.3). Moving to dedicated servers later is a transport change, not a rewrite.
##
## GodotSteam is optional at compile time: every Steam call goes through Engine.get_singleton
## and ClassDB so this script parses without the addon installed.

signal session_started(mode: String)
signal session_failed(reason: String)
signal session_ended(reason: String)
signal steam_lobby_changed(lobby_id: int)

const DEFAULT_PORT := 24680
const PING_INTERVAL_S := 0.5
const STEAM_LOBBY_FRIENDS_ONLY := 1
const STEAM_RESULT_OK := 1

var mode := "offline"   # offline | solo | enet_host | enet_client | steam_host | steam_client
var steam: Object = null
var steam_ready := false
var steam_status := "GodotSteam not installed"
var lobby_id := 0

# Client view of the host clock: server_ms ~= now_ms() + server_offset_ms.
var server_offset_ms := 0.0
var rtt_ms := 0.0
var _clock_synced := false
# Host view of each client: client_ms ~= server_ms + peers[id].offset_ms.
var peer_clock: Dictionary = {}
var _ping_accum := 0.0


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(func(): _fail("Could not reach host."))
	multiplayer.server_disconnected.connect(func(): _end("Host left the session."))
	_init_steam()


func now_ms() -> float:
	return Time.get_ticks_usec() / 1000.0


## Host clock estimate, used to align roast timing across peers (GDD 8.6).
func server_now_ms() -> float:
	if is_host():
		return now_ms()
	return now_ms() + server_offset_ms


func is_host() -> bool:
	return multiplayer.is_server()


func is_online() -> bool:
	return mode in ["enet_host", "enet_client", "steam_host", "steam_client"]


## Converts a client's local timestamp into host time (host-side).
func client_to_server_ms(peer_id: int, client_ms: float) -> float:
	if peer_id == 1 or peer_id == 0:
		return client_ms
	return client_ms - float(peer_clock.get(peer_id, {}).get("offset_ms", 0.0))


func peer_rtt_ms(peer_id: int) -> float:
	if peer_id == 1 or peer_id == 0:
		return 0.0
	return float(peer_clock.get(peer_id, {}).get("rtt_ms", 0.0))


# --- sessions --------------------------------------------------------------------------

func start_solo() -> void:
	_reset_peer()
	mode = "solo"
	session_started.emit(mode)


func host_enet(port: int = DEFAULT_PORT) -> void:
	_reset_peer()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, max_players() - 1)
	if err != OK:
		_fail("Could not host on port %d (error %d)." % [port, err])
		return
	multiplayer.multiplayer_peer = peer
	mode = "enet_host"
	session_started.emit(mode)


func join_enet(address: String) -> void:
	_reset_peer()
	var host := address
	var port := DEFAULT_PORT
	if address.contains(":"):
		host = address.get_slice(":", 0)
		port = int(address.get_slice(":", 1))
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(host, port)
	if err != OK:
		_fail("Could not connect to %s (error %d)." % [address, err])
		return
	multiplayer.multiplayer_peer = peer
	mode = "enet_client"


func host_steam() -> void:
	if not steam_ready:
		_fail("Steam is not available: " + steam_status)
		return
	_reset_peer()
	steam.call("createLobby", STEAM_LOBBY_FRIENDS_ONLY, max_players())


func join_steam_lobby(id: int) -> void:
	if not steam_ready:
		_fail("Steam is not available: " + steam_status)
		return
	_reset_peer()
	steam.call("joinLobby", id)


func invite_steam_friends() -> void:
	if steam_ready and lobby_id != 0:
		steam.call("activateGameOverlayInviteDialog", lobby_id)


func leave() -> void:
	if steam_ready and lobby_id != 0:
		steam.call("leaveLobby", lobby_id)
		lobby_id = 0
	_reset_peer()
	mode = "offline"


func max_players() -> int:
	return int(Data.slice.get("max_players", 4))


func _reset_peer() -> void:
	if multiplayer.multiplayer_peer and not (multiplayer.multiplayer_peer is OfflineMultiplayerPeer):
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	peer_clock.clear()
	server_offset_ms = 0.0
	rtt_ms = 0.0
	_clock_synced = false


func _fail(reason: String) -> void:
	push_warning(reason)
	mode = "offline"
	session_failed.emit(reason)


func _end(reason: String) -> void:
	leave()
	session_ended.emit(reason)


func _on_connected() -> void:
	session_started.emit(mode)


func _on_peer_connected(id: int) -> void:
	if is_host():
		peer_clock[id] = {"offset_ms": 0.0, "rtt_ms": 0.0}


func _on_peer_disconnected(id: int) -> void:
	peer_clock.erase(id)


# --- clock sync ------------------------------------------------------------------------

func _process(delta: float) -> void:
	if steam_ready:
		steam.call("run_callbacks")
	if not is_online() or multiplayer.multiplayer_peer == null:
		return
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_ping_accum += delta
	if _ping_accum < PING_INTERVAL_S:
		return
	_ping_accum = 0.0
	if is_host():
		for id in multiplayer.get_peers():
			_host_ping.rpc_id(id, now_ms())
	else:
		_client_ping.rpc_id(1, now_ms())


@rpc("any_peer", "unreliable")
func _client_ping(client_ms: float) -> void:
	_client_pong.rpc_id(multiplayer.get_remote_sender_id(), client_ms, now_ms())


@rpc("authority", "unreliable")
func _client_pong(client_ms: float, host_ms: float) -> void:
	var rtt := now_ms() - client_ms
	var offset := host_ms + rtt * 0.5 - now_ms()
	if not _clock_synced:
		server_offset_ms = offset
		rtt_ms = rtt
		_clock_synced = true
	else:
		server_offset_ms = lerpf(server_offset_ms, offset, 0.2)
		rtt_ms = lerpf(rtt_ms, rtt, 0.2)


@rpc("authority", "unreliable")
func _host_ping(host_ms: float) -> void:
	_host_pong.rpc_id(1, host_ms, now_ms())


@rpc("any_peer", "unreliable")
func _host_pong(host_ms: float, client_ms: float) -> void:
	var id := multiplayer.get_remote_sender_id()
	var rtt := now_ms() - host_ms
	var offset := client_ms - (host_ms + rtt * 0.5)
	var e: Dictionary = peer_clock.get(id, {})
	if e.is_empty() or not e.has("synced"):
		peer_clock[id] = {"offset_ms": offset, "rtt_ms": rtt, "synced": true}
	else:
		e.offset_ms = lerpf(e.offset_ms, offset, 0.2)
		e.rtt_ms = lerpf(e.rtt_ms, rtt, 0.2)


# --- Steam (GodotSteam, optional) --------------------------------------------------------

func _init_steam() -> void:
	if not Engine.has_singleton("Steam"):
		return
	steam = Engine.get_singleton("Steam")
	var app_id := int(Data.slice.get("steam_app_id", 480))
	var result: Variant = null
	# GodotSteam changed steamInitEx's signature across 4.x releases; pick by arity.
	for m in steam.get_method_list():
		if m.name == "steamInitEx":
			if m.args.size() >= 3:
				result = steam.call("steamInitEx", false, app_id, false)
			else:
				result = steam.call("steamInitEx", app_id, false)
			break
	if result == null:
		steam_status = "GodotSteam found but steamInitEx is missing"
		return
	if result is Dictionary and int(result.get("status", -1)) != 0:
		steam_status = "Steam init failed: %s" % result.get("verbal", "unknown")
		return
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		steam_status = "GodotSteam found but SteamMultiplayerPeer is missing"
		return
	steam_ready = true
	steam_status = "Steam ready as %s" % steam.call("getPersonaName")
	steam.connect("lobby_created", _on_lobby_created)
	steam.connect("lobby_joined", _on_lobby_joined)
	steam.connect("join_requested", _on_join_requested)


func steam_persona_name() -> String:
	return str(steam.call("getPersonaName")) if steam_ready else ""


func _on_lobby_created(result: int, new_lobby_id: int) -> void:
	if result != STEAM_RESULT_OK:
		_fail("Steam lobby creation failed (%d)." % result)
		return
	lobby_id = new_lobby_id
	steam.call("setLobbyJoinable", lobby_id, true)
	steam.call("setLobbyData", lobby_id, "name", "%s's Day One Patch" % steam_persona_name())
	steam.call("setLobbyData", lobby_id, "content_hash", Data.content_hash())
	var peer: Object = ClassDB.instantiate("SteamMultiplayerPeer")
	var err: int = peer.call("create_host", 0)
	if err != OK:
		_fail("Steam host failed (error %d)." % err)
		return
	multiplayer.multiplayer_peer = peer
	mode = "steam_host"
	steam_lobby_changed.emit(lobby_id)
	session_started.emit(mode)


func _on_lobby_joined(joined_lobby: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != STEAM_RESULT_OK:
		_fail("Could not join Steam lobby (%d)." % response)
		return
	lobby_id = joined_lobby
	steam_lobby_changed.emit(lobby_id)
	var owner_id: int = steam.call("getLobbyOwner", lobby_id)
	if owner_id == steam.call("getSteamID"):
		return  # we created it; host path already running
	var peer: Object = ClassDB.instantiate("SteamMultiplayerPeer")
	var err: int = peer.call("create_client", owner_id, 0)
	if err != OK:
		_fail("Steam connect failed (error %d)." % err)
		return
	multiplayer.multiplayer_peer = peer
	mode = "steam_client"


func _on_join_requested(requested_lobby: int, _friend_id: int) -> void:
	join_steam_lobby(requested_lobby)
