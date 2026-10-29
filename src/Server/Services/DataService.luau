--!strict
--[[
	DataService (owner: data agent)

	Loads, migrates, holds and saves player profiles with ProfileStore (session locking).
	The ONLY module that touches the profiles DataStore.

	Lifecycle of one player's profile:
	  join   StartSessionAsync takes the session lock. ProfileStore retries DataStore errors with
	         exponential backoff (1 s doubling to 20 s); we give up after LOAD_TIMEOUT_SECONDS.
	         Profile.prepare runs on a copy, so a save we cannot trust is never modified.
	  play   Services mutate the table from getProfile(). ProfileStore autosaves every 300 s.
	  leave  EndSession: onProfileReleasing listeners run, then the final save, then the lock is
	         released.
	  close  ProfileStore's own BindToClose saves and releases every session (reason "Shutdown")
	         and holds the server open until those saves finish. Listeners run first, as on leave.
	If a profile cannot load, or the lock is lost mid-session, the player is kicked with a clear
	message. The game never runs on a default profile.

	Public API (everything else is private):
	  getProfile(userId)      the live profile for a player in THIS server, or nil
	  onProfileLoaded(fn)     fn(player, profile) after a load; also runs for already-loaded ones
	  onProfileReleasing(fn)  fn(userId, profile) right before the final save; must not yield
	  saveNow(userId, confirm)  saves now and yields until a save whose written data passes
	                          confirm(savedData) lands: (true) or (false, reason). Bounded: 3 tries
	                          of up to 10 s, 2 s then 4 s backoff (about 36 s worst case). false is
	                          not a rollback: the change stays in the live profile and still saves
	                          on the next autosave or on leave, unless the server dies first.
	  persistence()           "DataStore", "Memory" (Studio without API access) or nil (checking)
	  sendMessage             Phase 1, errors until then

	TODO (Phase 1, async core):
	  [ ] Message handler: apply incoming escrow debits (Escrow.debitDefender) inside this session
	  [ ] sendMessage via ProfileStore:MessageAsync. It retries forever internally, so call it from
	      a background thread; the escrow record and recovery sweep stay the source of truth.
	      The queue keeps at most 1000 messages per profile and drops the oldest.
	  [ ] withOfflineProfile(userId, fn): load an offline profile, run fn, save, release
	      (used by EscrowService when the defender is not online anywhere)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

local MESSAGE_LOAD_FAILED = "We couldn't load your save, so we stopped before anything changed. "
	.. "Nothing was lost. Please rejoin in a minute."
local MESSAGE_UNSAFE_SAVE = "Your save needs a newer server or could not be read safely. "
	.. "It was not changed. Please rejoin."
local MESSAGE_SESSION_LOST = "Your save was opened in another server. Please rejoin to keep playing."

local DataService = {}

local store: any = nil
local sessions: { [number]: Session } = {}
local loadedListeners: { (Player, PlayerProfile) -> () } = {}
local releasingListeners: { (number, PlayerProfile) -> () } = {}
local leaving: { [Player]: true } = setmetatable({}, { __mode = "k" }) :: any -- weak: no leak
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

local function onPlayerAdded(player: Player)
	local userId = player.UserId
	local started = os.clock()
	local ok, session = pcall(store.StartSessionAsync, store, keyFor(userId), {
		-- Stop retrying when the player leaves or the deadline passes: bounded, never a tight loop.
		Cancel = function(): boolean
			return isGone(player) or os.clock() - started > LOAD_TIMEOUT_SECONDS
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
		if sessions[userId] ~= session then
			return
		end
		sessions[userId] = nil
		if not closing and not ProfileStore.IsClosing then
			warn(`[DataService] session lock lost for {userId}; kicking`)
			kick(player, MESSAGE_SESSION_LOST)
		end
	end)

	sessions[userId] = session
	print(`[DataService] loaded {userId} (schema {profile.schemaVersion}, glow {profile.glow})`)
	for _, fn in table.clone(loadedListeners) do
		task.spawn(fn, player, profile)
	end
end

local function onPlayerRemoving(player: Player)
	leaving[player] = true
	local session = sessions[player.UserId]
	if session then
		sessions[player.UserId] = nil
		session:EndSession() -- runs onProfileReleasing listeners, then saves and releases
	end
end

function DataService.start()
	store = ProfileStore.New(STORE_NAME, Profile.new(0, 0))

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
-- calling getProfile again: the session can end while you wait.
function DataService.getProfile(userId: number): PlayerProfile?
	local session = sessions[userId]
	if session and session:IsActive() then
		return session.Data
	end
	return nil
end

-- Calls fn(player, profile) after each successful load, and right away for profiles already
-- loaded. Each call runs on its own thread. Returns a function that disconnects.
function DataService.onProfileLoaded(fn: (Player, PlayerProfile) -> ()): () -> ()
	table.insert(loadedListeners, fn)
	for userId, session in sessions do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			task.spawn(fn, player, session.Data)
		end
	end
	return function()
		local index = table.find(loadedListeners, fn)
		if index then
			table.remove(loadedListeners, index)
		end
	end
end

-- Calls fn(userId, profile) right before a profile's final save (leave, shutdown, or another
-- server taking the lock). Last chance to write, e.g. a final accrue. Must not yield: anything
-- after a yield misses the save. Returns a function that disconnects.
function DataService.onProfileReleasing(fn: (number, PlayerProfile) -> ()): () -> ()
	table.insert(releasingListeners, fn)
	return function()
		local index = table.find(releasingListeners, fn)
		if index then
			table.remove(releasingListeners, index)
		end
	end
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
-- passes confirm(savedData). `confirm` must check for the specific change that has to be durable
-- (escrow checks appliedTransfers[raidId]). Never call this on a player's join path.
function DataService.saveNow(userId: number, confirm: (savedData: any) -> boolean): (boolean, string?)
	local backoff = SAVE_NOW_FIRST_BACKOFF_SECONDS
	for attempt = 1, SAVE_NOW_ATTEMPTS do
		local session = sessions[userId]
		if not session or not session:IsActive() then
			return false, `profile {userId} is not loaded in this server`
		end
		local ok, already = pcall(confirm, session.LastSavedData)
		if ok and already then
			return true, nil -- an earlier save (autosave) already wrote it
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

-- Where saves go: "DataStore", "Memory" (Studio without API access; ProfileStore keeps profiles
-- in memory for this session only), or nil while ProfileStore is still checking access.
-- Services that keep their own records next to profiles must use the same mode.
function DataService.persistence(): ("DataStore" | "Memory")?
	local state = ProfileStore.DataStoreState
	if state == "Access" then
		return "DataStore"
	elseif state == "NotReady" then
		return nil
	end
	return "Memory"
end

-- Phase 1: sends a message to a player's profile wherever it is loaded (ProfileStore message
-- queue). Errors until implemented so no caller mistakes a no-op for a delivered transfer.
function DataService.sendMessage(_userId: number, _message: { [string]: any })
	error("DataService.sendMessage is not implemented until Phase 1 (async raids)")
end

return DataService
