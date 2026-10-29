--!strict
--[[
	DataService (owner: data agent)

	Loads, migrates, holds and saves player profiles with ProfileStore (session locking).
	The ONLY module that touches the profiles DataStore.

	Lifecycle of one player's profile:
	  join   StartSessionAsync takes the session lock (once per Player object). ProfileStore
	         retries DataStore errors with exponential backoff (1 s doubling to 20 s); we give up
	         after LOAD_TIMEOUT_SECONDS. Profile.prepare runs on a copy, so a save we cannot trust
	         is never modified.
	  play   Services mutate the table from getProfile(). ProfileStore autosaves every 300 s.
	  leave  EndSession, only for the session that leaving Player owns: onProfileReleasing
	         listeners run, then the final save, then the lock is released.
	If another server takes the lock outright (its release request unanswered for ~40 s, or no
	save for 630 s), changes since the last save are dropped (decision 0003). OnLastSave never
	fires if our next save is an autosave; if it is the release on leave, listeners run but their
	write is dropped too. Anything that must be durable confirms a save with saveNow first.
	  close  ProfileStore's own BindToClose saves and releases every session (reason "Shutdown")
	         and holds the server open until those saves finish. Listeners run first, as on leave.
	If a profile cannot load, or the lock is lost mid-session, the player is kicked with a clear
	message. The game never runs on a default profile.

	Public API (everything else is private):
	  getProfile(userId)      the live profile for a player in THIS server, or nil
	  onProfileLoaded(fn)     fn(player, profile) after a load; also runs for already-loaded ones
	  onProfileReleasing(fn)  fn(userId, profile) right before the final save; must not yield
	  markRaidLogSeen(userId, now)  sets the loaded profile's raidLogSeenAt to the server's now
	                          (Profile.markRaidLogSeen: forward only). No-op if not loaded here
	  saveNow(userId, confirm)  saves now and yields until a save whose written data passes
	                          confirm(savedData) lands: (true) or (false, reason). Bounded: 3 tries
	                          of up to 10 s, 2 s then 4 s backoff (about 36 s worst case). false is
	                          not a rollback: the change stays in the live profile and still saves
	                          on the next autosave or on leave, unless the server dies first.
	                          Never call it from code a player's load waits on.
	  persistence()          "DataStore", "Memory" (Studio without API access, or the Studio memory
	                          switch below) or nil (start() has not run yet, or ProfileStore is
	                          still checking access). nil means "not decided": never pick a mode
	                          from it, ask again later
	  sendMessage(userId, topic, data)  queues { topic, data } on the user's profile (ProfileStore
	                          message), loaded anywhere or not. Yields up to 15 s: (true) once
	                          written, else (false, reason); a write still pending may land later,
	                          so every message must be safe to receive twice
	  onMessage(topic, fn)    fn(userId, data) for each message of that topic to a profile loaded
	                          here (on load for queued ones, then on its saves). It must not yield;
	                          once it returns the message is processed, and it leaves the queue in
	                          the same save as whatever fn changed. An error, or no listener, keeps
	                          it queued for the profile's next load. Register in start()
	  updateOffline(userId, fn)  fn(profile) on the saved profile of a player NO server holds, in
	                          one atomic write that lands only while no session lock is held (see
	                          the section near the end). For EscrowService's async debits
	  peekOffline(userId)     Studio-only, read-only copy of a saved profile (playtests)
	  loadTestProfile(userId, profile), releaseTestProfile(userId), guardTestRelease(guard)
	                          Studio-only fake profiles for RaidService's single-client test hook
	                          (decision D-019), memory persistence only. See the section at the end.

	Studio memory switch (D-019). To play in Studio with API access on but save NOTHING, set a
	boolean attribute on ServerStorage before pressing Play (Properties, or the command bar in
	Edit mode):
	    game:GetService("ServerStorage"):SetAttribute("StudioMemoryProfiles", true)
	start() reads it once. When true, every profile loads from ProfileStore's mock store
	(store.Mock, in memory, a fresh template each Play), persistence() is "Memory", and so
	EscrowService keeps its records in memory too. Nothing is read from or written to the profiles
	DataStore. Missing or false: normal behavior. Outside Studio it is never read. Set it back to
	false (or delete it) to test real saves again.

	Messages (P1.1) ride ProfileStore's queue in the profile's own key: it keeps at most 1000 per
	profile and drops the oldest, and MessageAsync retries forever, so sendMessage runs it on its
	own thread and waits a bounded time. Messages are wake-ups, never the only record of anything:
	EscrowService's records and recovery stay the source of truth.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local ProfileStore = require(script.Parent.Parent.Packages.ProfileStore) :: any
local Profile = require(ReplicatedStorage.Shared.Profile)
local Types = require(ReplicatedStorage.Shared.Types)

type PlayerProfile = Types.PlayerProfile
type Session = any -- a ProfileStore profile; the vendored module is not strictly typed

local STORE_NAME = "PlayerProfiles"
-- Must cover ProfileStore's session-conflict wait (~45 s before it steals a dead server's lock).
local LOAD_TIMEOUT_SECONDS = 60

-- saveNow: Profile:Save() makes ONE UpdateAsync attempt and fires nothing if it fails, so we
-- wait a bounded time per attempt and back off before asking again.
local SAVE_NOW_ATTEMPTS = 3
local SAVE_NOW_WAIT_SECONDS = 10
local SAVE_NOW_FIRST_BACKOFF_SECONDS = 2
local MESSAGE_SEND_WAIT_SECONDS = 15
local OFFLINE_RETRY_DELAYS = { 1, 2, 4 } -- seconds between offline-write attempts

local MESSAGE_LOAD_FAILED = "We couldn't load your save, so we stopped before anything changed. "
	.. "Nothing was lost. Please rejoin in a minute."
local MESSAGE_UNSAFE_SAVE = "Your save needs a newer server or could not be read safely. "
	.. "It was not changed. Please rejoin."
local MESSAGE_SESSION_LOST = "Your save was opened in another server. Please rejoin to keep playing."

-- Studio-only memory switch (decision D-019). Read once, in start(), and only in Studio.
local MEMORY_SWITCH = "StudioMemoryProfiles"

local DataService = {}

-- A loaded session and the Player object it was loaded for. Removal ends a session only if it
-- belongs to the leaving Player, never a newer session of the same user.
type Entry = { session: Session, player: Player }

local store: any = nil
local sessions: { [number]: Entry } = {}
local loadedListeners: { (Player, PlayerProfile) -> () } = {}
local releasingListeners: { (number, PlayerProfile) -> () } = {}
local leaving: { [Player]: true } = setmetatable({}, { __mode = "k" }) :: any -- weak: no leak
local handled: { [Player]: true } = setmetatable({}, { __mode = "k" }) :: any -- loading or loaded
local testProfiles: { [number]: PlayerProfile } = {} -- Studio only (D-019); never saved
local testReleaseGuard: ((userId: number) -> string?)? = nil -- set by EscrowService
local messageListeners: { [string]: (number, any) -> () } = {}
local rawProfiles: DataStore? = nil -- the profiles DataStore itself, for updateOffline only
local memoryOnly = false -- Studio memory switch on: every profile is in ProfileStore's mock store
-- Set once by start(), after the switch is read. Until then persistence() is nil, so nothing
-- (EscrowService above all) can choose a storage mode the switch would contradict.
local started = false
local closing = false

local function keyFor(userId: number): string
	return `Player_{userId}`
end

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[deepCopy(k)] = deepCopy(v)
	end
	return copy
end

local function isGone(player: Player): boolean
	return leaving[player] == true or player.Parent ~= Players
end

local function kick(player: Player, message: string)
	if not isGone(player) then
		player:Kick(message)
	end
end

local function runReleasing(userId: number, profile: PlayerProfile)
	for _, fn in table.clone(releasingListeners) do
		local ok, err = pcall(fn, userId, profile)
		if not ok then
			warn(`[DataService] onProfileReleasing listener failed for {userId}: {err}`)
		end
	end
end

-- One ProfileStore message { topic, data } for a profile loaded here (onMessage). The listener
-- runs on this thread; processed() only once it returns, so the message leaves the queue in the
-- same save that writes whatever the listener changed. Malformed messages are dropped.
local function handleMessage(userId: number, message: any, processed: () -> ())
	if type(message) ~= "table" or type(message.topic) ~= "string" then
		warn(`[DataService] dropping a malformed message for {userId}`)
		processed()
		return
	end
	local listener = messageListeners[message.topic]
	if listener == nil then
		warn(`[DataService] no listener for message topic {message.topic}; kept for {userId}'s next load`)
		return
	end
	local ok, err = pcall(listener, userId, message.data)
	if not ok then
		warn(`[DataService] {message.topic} message for {userId} failed; kept for their next load: {err}`)
		return
	end
	processed()
end

local function onPlayerAdded(player: Player)
	-- PlayerAdded and the startup loop in start() can both deliver one player: load it once.
	if handled[player] then
		return
	end
	handled[player] = true
	local userId = player.UserId
	local loadBegan = os.clock()
	local ok, session = pcall(store.StartSessionAsync, store, keyFor(userId), {
		-- Stop retrying when the player leaves or the deadline passes: bounded, never a tight loop.
		Cancel = function(): boolean
			return isGone(player) or os.clock() - loadBegan > LOAD_TIMEOUT_SECONDS
		end,
	})
	if not ok or session == nil then
		if not ok then
			warn(`[DataService] StartSessionAsync errored for {userId}: {session}`)
		end
		if not closing then
			warn(`[DataService] could not load profile for {userId}; kicking`)
			kick(player, MESSAGE_LOAD_FAILED)
		end
		return
	end
	if isGone(player) then
		session:EndSession() -- left in the last moment of loading
		return
	end

	local prepared, result = pcall(Profile.prepare, deepCopy(session.Data), userId, os.time())
	if not prepared then
		warn(`[DataService] refusing save for {userId}: {result}`)
		session:EndSession() -- saves the untouched original back and releases the lock
		kick(player, MESSAGE_UNSAFE_SAVE)
		return
	end
	local profile: PlayerProfile = result
	session.Data = profile
	session:AddUserId(userId) -- GDPR: associates the key with the user

	session.OnLastSave:Connect(function(reason: string)
		runReleasing(userId, session.Data)
		print(`[DataService] releasing {userId} ({reason})`)
	end)
	session.OnSessionEnd:Connect(function()
		-- PlayerRemoving clears the entry before ending the session, so a match here means the
		-- lock was lost while the player is still in this server.
		local entry = sessions[userId]
		if entry == nil or entry.session ~= session then
			return
		end
		sessions[userId] = nil
		if not closing and not ProfileStore.IsClosing then
			warn(`[DataService] session lock lost for {userId}; kicking`)
			kick(player, MESSAGE_SESSION_LOST)
		end
	end)

	sessions[userId] = { session = session, player = player }
	print(`[DataService] loaded {userId} (schema {profile.schemaVersion}, glow {profile.glow})`)
	-- Queued messages are handed over now, later ones after each save; only while active.
	session:MessageHandler(function(message: any, processed: () -> ())
		handleMessage(userId, message, processed)
	end)
	for _, fn in table.clone(loadedListeners) do
		task.spawn(fn, player, profile)
	end
end

local function onPlayerRemoving(player: Player)
	leaving[player] = true
	local entry = sessions[player.UserId]
	-- A late removal of an older Player object for this user must not end their newer session.
	if entry and entry.player == player then
		sessions[player.UserId] = nil
		entry.session:EndSession() -- runs onProfileReleasing listeners, then saves and releases
	end
end

function DataService.start()
	-- Once only: a second start() could re-read the switch and change the mode under EscrowService.
	if started then
		error("DataService.start() was called twice")
	end
	-- `IsStudio() and`: a live server never reads the switch, whatever the place file holds.
	memoryOnly = RunService:IsStudio() and ServerStorage:GetAttribute(MEMORY_SWITCH) == true
	local profileStore = ProfileStore.New(STORE_NAME, Profile.new(0, 0))
	-- The mock drops StartSessionAsync's params (Cancel); its loads never wait on another server.
	store = if memoryOnly then profileStore.Mock else profileStore
	started = true -- only now may persistence() answer: the switch is read and the store chosen
	if memoryOnly then
		warn(`[DataService] Studio memory switch ({MEMORY_SWITCH}) is on: profiles are mock, nothing saves`)
	end

	ProfileStore.OnError:Connect(function(message: string, storeName: string, key: string)
		warn(`[DataService] ProfileStore error ({storeName}/{key}): {message}`)
	end)
	ProfileStore.OnCriticalToggle:Connect(function(isCritical: boolean)
		warn(`[DataService] ProfileStore critical state: {isCritical}`)
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	game:BindToClose(function()
		closing = true
		local count = 0
		for _ in sessions do
			count += 1
		end
		print(`[DataService] shutting down; ProfileStore is saving and releasing {count} profile(s)`)
	end)
end

-- Returns the live profile for an online player in THIS server, or nil (not loaded yet, failed,
-- or left). Mutations to the returned table are saved. Never cache it across a yield without
-- calling getProfile again: the session can end while you wait. Also returns a Studio test
-- profile (loadTestProfile), which is never saved.
function DataService.getProfile(userId: number): PlayerProfile?
	local test = testProfiles[userId]
	if test then
		return test
	end
	local entry = sessions[userId]
	if entry and entry.session:IsActive() then
		return entry.session.Data
	end
	return nil
end

-- Calls fn(player, profile) after each successful load, and right away for profiles already
-- loaded. Each call runs on its own thread. Returns a function that disconnects.
function DataService.onProfileLoaded(fn: (Player, PlayerProfile) -> ()): () -> ()
	table.insert(loadedListeners, fn)
	for _, entry in sessions do
		if not isGone(entry.player) then
			task.spawn(fn, entry.player, entry.session.Data)
		end
	end
	return function()
		local index = table.find(loadedListeners, fn)
		if index then
			table.remove(loadedListeners, index)
		end
	end
end

-- Calls fn(userId, profile) right before a profile's final save (leave or shutdown; also when a
-- Studio test profile is released). Last chance to write, e.g. a final accrue. Must not yield:
-- anything after a yield misses the save. Not called when another server took the lock and our
-- next save is an autosave (decision 0003). Returns a function that disconnects.
function DataService.onProfileReleasing(fn: (number, PlayerProfile) -> ()): () -> ()
	table.insert(releasingListeners, fn)
	return function()
		local index = table.find(releasingListeners, fn)
		if index then
			table.remove(releasingListeners, index)
		end
	end
end

-- RaidService's GetRaidLog: marks the player's raid log seen at `now`, which must be the
-- server's os.time(), never a client value (Profile.markRaidLogSeen ignores a non-finite or
-- earlier time). Does nothing when the profile is not loaded in this server. Never yields and
-- never forces a save: a display-only time can wait for the next autosave or the leave. It leaves
-- the RaidLogSeenAt attribute alone, since that keeps its load-time value all session
-- (docs/contracts.md). Returns whether it wrote.
function DataService.markRaidLogSeen(userId: number, now: number): boolean
	local profile = DataService.getProfile(userId)
	if profile == nil then
		return false
	end
	return Profile.markRaidLogSeen(profile, now)
end

-- One save request. "saved": a save landed whose written data passes `confirm`. "lost": the
-- session ended without such a save. "timeout": nothing confirmed within the wait.
local function saveOnce(session: Session, confirm: (any) -> boolean): "saved" | "lost" | "timeout"
	local thread = coroutine.running()
	local result: ("saved" | "lost" | "timeout")? = nil
	local waiting = false
	local connection: any = nil
	local timer: thread? = nil
	local function finish(value: "saved" | "lost" | "timeout")
		if result then
			return
		end
		result = value
		connection:Disconnect()
		if timer and value ~= "timeout" then
			task.cancel(timer)
		end
		if waiting then
			task.spawn(thread)
		end
	end
	-- Judge each save by the data it actually wrote, not by timing: an autosave that started
	-- before the change can finish after this call, and must not count.
	connection = session.OnAfterSave:Connect(function(saved: any)
		local ok, passed = pcall(confirm, saved)
		if ok and passed then
			finish("saved")
		elseif not session:IsActive() then
			finish("lost")
		end
	end)
	timer = task.delay(SAVE_NOW_WAIT_SECONDS, finish, "timeout")
	session:Save()
	if not result then
		waiting = true
		coroutine.yield()
	end
	return result :: any
end

-- Saves a loaded profile now and yields until ProfileStore confirms a save whose written data
-- passes confirm(savedData). `confirm` must match the exact change that has to be durable (escrow
-- matches its appliedTransfers entry by raidId, role and time). Always issues a fresh save: a
-- previous save's data is never trusted as confirmation.
-- Yields up to about 36 s, so call it only from a thread nobody waits on to load a player (for
-- example an onProfileLoaded listener, which runs on its own thread) and never from the loading
-- code itself.
function DataService.saveNow(userId: number, confirm: (savedData: any) -> boolean): (boolean, string?)
	local test = testProfiles[userId]
	if test then
		-- A test profile has nowhere to save: its live table is all there is, and no other server
		-- can hold it. So it counts as saved once the live data passes confirm, decided at once.
		local ok, passed = pcall(confirm, deepCopy(test))
		if ok and passed then
			return true, nil
		end
		return false, `test profile {userId}: confirm failed`
	end
	local backoff = SAVE_NOW_FIRST_BACKOFF_SECONDS
	for attempt = 1, SAVE_NOW_ATTEMPTS do
		local entry = sessions[userId]
		local session = if entry then entry.session else nil
		if not session or not session:IsActive() then
			return false, `profile {userId} is not loaded in this server`
		end
		local result = saveOnce(session, confirm)
		if result == "saved" then
			return true, nil
		elseif result == "lost" then
			return false, `session for {userId} ended before the save was confirmed`
		end
		if attempt < SAVE_NOW_ATTEMPTS then
			task.wait(backoff)
			backoff *= 2
		end
	end
	return false, `no confirmed save for {userId} after {SAVE_NOW_ATTEMPTS} attempts`
end

-- Where saves go: "DataStore", "Memory" (Studio without API access, or the Studio memory switch;
-- profiles live in memory for this session only), or nil: start() has not run (the switch is not
-- read yet), or ProfileStore is still checking access. Services that keep their own records next
-- to profiles must use the same mode, so they must treat nil as "not decided" (refuse and ask
-- again later), never as a default. Once non-nil, the answer never changes for this server.
function DataService.persistence(): ("DataStore" | "Memory")?
	if not started then
		return nil
	end
	if memoryOnly then
		return "Memory"
	end
	local state = ProfileStore.DataStoreState
	if state == "Access" then
		return "DataStore"
	elseif state == "NotReady" then
		return nil
	end
	return "Memory"
end

-- Queues { topic = topic, data = data } on a user's profile, loaded anywhere or nowhere
-- (ProfileStore:MessageAsync; it pings a holding server to save, and so receive it, sooner).
-- MessageAsync retries forever, so it runs on its own thread: true once written, false when
-- refused or unconfirmed within MESSAGE_SEND_WAIT_SECONDS. A false may still land later, and
-- DataStore can repeat a write, so receivers must treat every message as possibly repeated.
function DataService.sendMessage(userId: number, topic: string, data: any): (boolean, string?)
	if store == nil then
		return false, "DataService not started"
	end
	local outcome: boolean? = nil
	task.spawn(function()
		local ok, sent = pcall(store.MessageAsync, store, keyFor(userId), { topic = topic, data = data })
		if not ok then
			warn(`[DataService] message {topic} to {userId} errored: {sent}`)
		end
		outcome = ok and sent == true
	end)
	local deadline = os.clock() + MESSAGE_SEND_WAIT_SECONDS
	while outcome == nil and os.clock() < deadline do
		task.wait(0.25)
	end
	if outcome then
		return true, nil
	elseif outcome == false then
		return false, "message refused (the server is closing, or MessageAsync errored)"
	end
	return false, `message not confirmed within {MESSAGE_SEND_WAIT_SECONDS} s; it may still land`
end

-- Calls fn(userId, data) for each message of `topic` (sendMessage) to a profile loaded here.
-- One listener per topic; fn must not yield. Returns a function that disconnects.
function DataService.onMessage(topic: string, fn: (userId: number, data: any) -> ()): () -> ()
	assert(messageListeners[topic] == nil, `DataService.onMessage: {topic} already has a listener`)
	messageListeners[topic] = fn
	return function()
		if messageListeners[topic] == fn then
			messageListeners[topic] = nil
		end
	end
end

--[[
	Offline profiles (P1.1). updateOffline(userId, fn) runs fn on the latest saved profile of a
	player whom NO server holds, in one UpdateAsync on the profile's own key. It lands only while
	ProfileStore's MetaData.ActiveSession is empty, so a held profile is never written behind its
	server's back, and it keeps ProfileStore's metadata, message queue, UserIds and RobloxMetaData.
	It takes no session lock, so it never makes a server release (and kick) its player. The data
	goes through Profile.prepare first, as on a load. fn(profile) must not yield and must be safe
	to run again on a fresh copy (UpdateAsync may retry); it returns (write: boolean, result).
	Returns:
	  "done", result  fn ran on the latest saved data, and its write (if any) landed
	  "held"          a server holds the profile (here too; always in Memory mode): message it
	  "missing"       no save, or only ProfileStore's template (never played)
	  "refused", why  the save cannot be trusted here (newer schema, wrong owner)
	Errors when the DataStore keeps failing (4 attempts, 1/2/4 s apart) or DataService has not
	started. Never call it from code a player's load waits on.
]]
local function isTemplate(data: any): boolean
	return type(data) ~= "table" or (data.createdAt == 0 and data.userId == 0)
end

local function offlineWrite(userId: number, fn: (PlayerProfile) -> (boolean, any)): (string, any)
	local raw = rawProfiles or DataStoreService:GetDataStore(STORE_NAME)
	rawProfiles = raw
	local outcome, result = "missing", nil
	local lastError: any = nil
	for attempt = 1, #OFFLINE_RETRY_DELAYS + 1 do
		local ok, err = pcall(function()
			raw:UpdateAsync(keyFor(userId), function(latest: any)
				outcome, result = "missing", nil
				if type(latest) ~= "table" or type(latest.MetaData) ~= "table" or isTemplate(latest.Data) then
					return nil
				end
				if latest.MetaData.ActiveSession ~= nil then
					outcome = "held"
					return nil
				end
				local prepared, profile = pcall(Profile.prepare, deepCopy(latest.Data), userId, os.time())
				if not prepared then
					outcome, result = "refused", profile
					return nil
				end
				local write, value = fn(profile)
				outcome, result = "done", value
				if not write then
					return nil
				end
				latest.Data = profile
				return latest, latest.UserIds, latest.RobloxMetaData
			end)
		end)
		if ok then
			return outcome, result
		end
		lastError = err
		if attempt <= #OFFLINE_RETRY_DELAYS then
			task.wait(OFFLINE_RETRY_DELAYS[attempt])
		end
	end
	error(`offline write for {userId} failed after {#OFFLINE_RETRY_DELAYS + 1} attempts: {lastError}`, 0)
end

function DataService.updateOffline(userId: number, fn: (profile: PlayerProfile) -> (boolean, any)): (string, any)
	local mode = DataService.persistence()
	if mode == nil then
		error("DataService not started (or still checking DataStore access)", 0)
	end
	-- Memory mode: the mock store is ProfileStore's own; a message reaches it (on its next load).
	if mode == "Memory" or sessions[userId] or testProfiles[userId] then
		return "held", nil
	end
	return offlineWrite(userId, fn)
end

-- Studio only: a read-only copy of a user's saved profile, or nil (playtest checks).
function DataService.peekOffline(userId: number): PlayerProfile?
	if not RunService:IsStudio() then
		error("DataService.peekOffline is Studio-only")
	end
	assert(store, "DataService not started")
	local view = store:GetAsync(keyFor(userId))
	return if view then deepCopy(view.Data) else nil
end

--[[
	Studio test profiles (decision D-019), for RaidService's single-client test hook (D-010).

	Allowed ONLY in Studio with memory persistence (the memory switch above, or no API access):
	then every profile and escrow record in the server lives in memory, so a test profile can
	never be mixed with a saved one (a real profile credited by an escrow that only memory knew).

	loadTestProfile(userId, profile) adopts `profile` BY REFERENCE: Profile.prepare runs on it in
	place, and getProfile(userId) returns that same table. Errors outside Studio, unless
	persistence() is "Memory", and for an id outside Profile.isTestUserId (<= -1,000,000), so a
	real player or a Local Server test player can never be faked. Returns false (and why) if the
	id is in use by a player, a session or another test profile. Fires no onProfileLoaded
	listeners (there is no Player). Kept in its own table, so no leave or session end touches it.
	saveNow on it is decided at once (above): there is nowhere to save and no other server.
	If Profile.prepare refuses the table (false, "test profile <id> refused: ..."), nothing is
	held, but because prepare works in place the caller's table may already be partly migrated
	or stamped (schema, userId, daily counters). Throw it away and build a fresh one; never
	retry with the same table.

	releaseTestProfile(userId) is a leave: getProfile returns nil, then onProfileReleasing
	listeners run. Fails closed: returns false (and why) while an escrow for that id is still
	open here (EscrowService's guard), when no guard was ever registered (EscrowService.start has
	not run, so nobody can say no escrow is open), or when the guard errors. So no raid is ever
	left needing a profile that is gone.
]]
function DataService.loadTestProfile(userId: number, profile: PlayerProfile): (boolean, string?)
	if not RunService:IsStudio() then
		error("DataService.loadTestProfile is Studio-only")
	end
	if DataService.persistence() ~= "Memory" then
		error(`DataService.loadTestProfile needs memory persistence: set ServerStorage.{MEMORY_SWITCH} before Play`)
	end
	if not Profile.isTestUserId(userId) then
		error(`DataService.loadTestProfile: test ids are whole numbers <= {Profile.TEST_USER_ID_MAX}, not {userId}`)
	end
	local current = testProfiles[userId]
	if current then
		return current == profile, if current == profile then nil else `{userId} already has a test profile`
	end
	if sessions[userId] or Players:GetPlayerByUserId(userId) then
		return false, `{userId} is a player in this server`
	end
	local ok, err = pcall(Profile.prepare, profile, userId, os.time())
	if not ok then
		return false, `test profile {userId} refused: {err}`
	end
	testProfiles[userId] = profile
	print(`[DataService] loaded test profile {userId} (memory only, never saved)`)
	return true, nil
end

function DataService.releaseTestProfile(userId: number): (boolean, string?)
	local profile = testProfiles[userId]
	if profile == nil then
		return true, nil -- nothing held
	end
	-- Fail closed: only EscrowService's guard can say no escrow is open for this id.
	local guard = testReleaseGuard
	if guard == nil then
		local why = "no escrow guard registered (EscrowService.start has not run)"
		warn(`[DataService] test profile {userId} kept: {why}`)
		return false, why
	end
	local checked, why = pcall(guard, userId)
	if not checked or why ~= nil then
		local reason = if checked then why else `escrow guard failed: {why}`
		warn(`[DataService] test profile {userId} kept: {reason}`)
		return false, reason
	end
	testProfiles[userId] = nil
	runReleasing(userId, profile)
	print(`[DataService] released test profile {userId}`)
	return true, nil
end

-- EscrowService only: guard(userId) returns why a test profile must stay (an escrow for it is
-- still open here), or nil. DataService cannot require EscrowService (it requires DataService).
-- Until a guard is registered, releaseTestProfile refuses every release.
function DataService.guardTestRelease(guard: (userId: number) -> string?)
	testReleaseGuard = guard
end

return DataService
