---@type LibreFmPlugin
---@diagnostic disable-next-line: missing-fields
local M = {}

---@param tbl table
---@return string urlencoded string
local function urlencode_table(tbl)
    local function urlencode(str)
        if str == nil then return "" end
        str = tostring(str)
        str = str:gsub("\n", "\r\n")
        str = str:gsub("([^%w%-._~])", function(c) return string.format("%%%02X", string.byte(c)) end)
        return str
    end
    
    local parts = {}
    for k, v in pairs(tbl) do
        table.insert(parts, urlencode(k) .. "=" .. urlencode(v))
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

local function librefm_api_sig(params, shared_secret)
    local keys = {}
    for k, _ in pairs(params) do
        if k ~= "format" and k ~= "callback" then
            table.insert(keys, k)
        end
    end
    table.sort(keys)

    local base = ""
    for _, k in ipairs(keys) do
        base = base .. k .. params[k]
    end
    base = base .. shared_secret

    return util.md5(base)
end

---@param api_key string
---@param shared_secret string
---@param session_key string
---@param song Song
---@param duration_seconds? number
local function librefm_update_now_playing(api_key, shared_secret, session_key, song, duration_seconds)
    local params = {
        method = "track.updateNowPlaying",
        api_key = api_key,
        sk = session_key,
        format = "json",
    }

    if song.title ~= nil then
        params.track = song.title:first()
    end

    if song.artist ~= nil then
        params.artist = song.artist:first()
    end

    if song.album ~= nil then
        params.album = song.album:first()
    end

    if duration_seconds and duration_seconds > 0 then
        params.duration = tostring(duration_seconds)
    end

    if song.album_artist ~= nil then
        params.albumArtist = song.album_artist:first()
    end

    if song.musicbrainz_track_id ~= nil then
        params.mbid = song.musicbrainz_track_id:first()
    end

    params.api_sig = librefm_api_sig(params, shared_secret)

    local body_string = urlencode_table(params)
    local resp = http.post("https://libre.fm/2.0/", {
        headers = {["Content-Type"] = "application/x-www-form-urlencoded"},
        body = body_string,
    })

    local body = resp:json()
    if tostring(resp.code) ~= "200" then
        log.error("Libre.fm updateNowPlaying failed: HTTP " .. tostring(resp.code))
    elseif body and body.error ~= nil then
        log.error("Libre.fm updateNowPlaying failed: HTTP " .. tostring(resp.code) .. ", error code " .. tostring(body.error))
    end
end

---@param api_key string
---@param shared_secret string
---@param token string
---@return string|nil session_key
local function get_session_key(api_key, shared_secret, token)
    log.info("Waiting for browser auth...")
    local params = {
        api_key = api_key,
        method = "auth.getSession",
        token = token,
        format = "json",
    }

    params.api_sig = librefm_api_sig(params, shared_secret)

    local session_response = http.get("https://libre.fm/2.0/", { params = params })
    util.dump_table(session_response)

    if session_response.code == 200 and session_response:json()["error"] == nil then
        return session_response:json().session.key
    end

    return nil
end

---@class Deque<T>
---@field first integer
---@field last integer
---@field [integer] T
local Deque = {}
Deque.__index = Deque

---@generic T
---@return Deque<T>
function Deque.new()
    return setmetatable({ first = 0, last = -1 }, Deque)
end

---@generic T
---@param value T
function Deque:push_right(value)
    local last = self.last + 1
    self.last = last
    self[last] = value
end

---@generic T
---@return T
function Deque:pop_left()
    local first = self.first
    if first > self.last then
        return nil
    end
    local value = self[first]
    self[first] = nil
    self.first = first + 1
    return value
end

---@generic T
---@return T
function Deque:peek_right()
    local last = self.last
    if self.first > last then
        return nil
    end
    return self[last]
end

---@generic T
---@return T
function Deque:peek_left()
    local first = self.first
    if first > self.last then
        return nil
    end
    return self[first]
end

---@param api_key string
---@param session_key string
---@param shared_secret string
---@param old_song Song
---@param song_start integer
---@return boolean
local function scrobble(api_key, session_key, shared_secret, old_song, song_start)
    local params = {
        ["method"] = "track.scrobble",
        ["api_key"] = api_key,
        ["sk"] = session_key,
        ["timestamp[0]"] = tostring(song_start),
        ["format"] = "json",
    }

    if old_song.artist ~= nil then
        params["artist[0]"] = old_song.artist:first()
    end

    if old_song.album ~= nil then
        params["album[0]"] = old_song.album:first()
    end

    if old_song.title ~= nil then
        params["track[0]"] = old_song.title:first()
    end

    if old_song.album_artist ~= nil then
        params["albumArtist[0]"] = old_song.album_artist:first()
    end

    if old_song.musicbrainz_track_id ~= nil then
        params["mbid[0]"] = old_song.musicbrainz_track_id:first()
    end

    params.api_sig = librefm_api_sig(params, shared_secret)

    local body_string = urlencode_table(params)
    local resp = http.post("https://libre.fm/2.0/", {
        headers = {["Content-Type"] = "application/x-www-form-urlencoded"},
        body = body_string,
    })

    local body = resp:json()
    if tostring(resp.code) ~= "200" then
        log.error("Libre.fm scrobble failed: HTTP " .. tostring(resp.code))
        return false
    elseif body and body.error ~= nil then
        log.error("Libre.fm scrobble failed: HTTP " .. tostring(resp.code) .. ", error code " .. tostring(body.error))
        return false
    else
        log.info("Scrobbled: " .. old_song.file)
        return true
    end
end

---@param api_key string
---@param session_key string
---@param shared_secret string
---@param scrobble_queue Deque<{ song: Song, timestamp: integer }>
local function process_scrobble_queue(api_key, session_key, shared_secret, scrobble_queue)
    log.info("Processing scrobble queue with " .. (scrobble_queue.last - scrobble_queue.first + 1) .. " items")
    while true do
        local item = scrobble_queue:peek_left()
        if item == nil then
            break
        end

        local scrobbled = scrobble(api_key, session_key, shared_secret, item.song, item.timestamp)
        if scrobbled then
            scrobble_queue:pop_left()
        else
            log.error("Failed to scrobble, sopping processing of scrobble queue for now")
            break
        end
    end
    log.info("Finished processing scrobble queue")
end

---@param song_start integer
---@param current_time integer
---@param song Song
---@return boolean
local function should_scrobble(song_start, current_time, song)
    local min_scrobble_duration = 30
    local min_scrobble_time_secs = 4 * 60 -- 4 minutes as specified by last.fm

    if song_start == nil then
        return false
    end

    if song.duration == nil or song.duration < min_scrobble_duration then
        return false
    end

    local elapsed_secs = current_time - song_start
    local song_duration_secs = math.floor(song.duration / 1000)

    if elapsed_secs >= min_scrobble_time_secs then
        return true
    end

    if elapsed_secs >= song_duration_secs / 2 then
        return true
    end

    return false
end

M.setup = function(self, args)
    self.api_key = args.api_key
    self.shared_secret = args.shared_secret
    self.update_now_playing = (args.update_now_playing ~= nil) and args.update_now_playing or false
    self.enabled = (args.update_now_playing ~= nil) and args.enabled or true

    local xdg_open = util.which("xdg-open")
    if not xdg_open then
        log.error("xdg-open not found in PATH, disabling librefm plugin")
        self.enabled = false
    end

    self.scrobble_queue = Deque.new()

    local cached_session_key, err = fs.read_str("/tmp/rmpcd-librefm-session-key")
    if cached_session_key ~= nil and err == nil then
        log.info("Using cached Libre.fm session key")
        self.session_key = cached_session_key
        return
    else
        log.info("No cached Libre.fm session key found, starting auth flow")
    end

    local response = http.get("https://libre.fm/2.0", {
        params = {
            method = "auth.getToken",
            api_key = args.api_key,
            format = "json",
        },
    })


    local body = resp:json()
    if tostring(resp.code) ~= "200" then
        log.error("Failed to get Libre.fm auth token: HTTP " .. tostring(resp.code))
        return
    elseif body and body.error ~= nil then
        log.error("Failed to get Libre.fm auth token: HTTP " .. tostring(resp.code) .. ", error code " .. tostring(body.error))
        return
    end

    local token = response:json().token

    process.spawn({ "xdg-open", "https://libre.fm/api/auth/?api_key=" .. args.api_key .. "&token=" .. token })

    local session_key = get_session_key(args.api_key, args.shared_secret, token)
    if session_key == nil then
        sync.set_interval(10000, function(handle)
            session_key = get_session_key(args.api_key, args.shared_secret, token)

            if session_key ~= nil then
                handle.cancel()
                local _, sk_write_err = fs.write_str("/tmp/rmpcd-librefm-session-key", session_key)
                if sk_write_err ~= nil then
                    log.error("Failed to write Libre.fm session key to file: " .. sk_write_err)
                end

                self.session_key = session_key
            end
        end)
    end
end

M.song_change = function(self, old, new)
    if new ~= nil and (self.update_now_playing or false) then
        librefm_update_now_playing(self.api_key, self.shared_secret, self.session_key, new, new.duration)
    end

    local current_time = os.time()

    if old ~= nil and self.song_start ~= nil and should_scrobble(self.song_start, current_time, old) then
        local last = self.scrobble_queue:peek_right()
        if last == nil or (last ~= nil and last.timestamp < self.song_start) then
            self.scrobble_queue:push_right({ song = old, timestamp = self.song_start })
        end
    end

    self.song_start = current_time
    self.current_song = new

    process_scrobble_queue(self.api_key, self.session_key, self.shared_secret, self.scrobble_queue)
end

M.state_change = function(self, old, new)
    if new ~= "play" and old == "play" then
        local current_time = os.time()

        if
            self.current_song ~= nil
            and self.song_start ~= nil
            and should_scrobble(self.song_start, current_time, self.current_song)
        then
            local last = self.scrobble_queue:peek_right()
            if last == nil or (last ~= nil and last.timestamp < self.song_start) then
                self.scrobble_queue:push_right({ song = self.current_song, timestamp = self.song_start })
            end
        end

        self.song_start = nil
        self.current_song = nil
    end

    process_scrobble_queue(self.api_key, self.session_key, self.shared_secret, self.scrobble_queue)
end

M.subscribed_channels = { "rmpcd.librefm" }
M.message = function(self, _channel, message)
    if message == "enable" then
        log.info("Enabling librefm plugin")
        self.enabled = true
    elseif message == "disable" then
        log.info("Disabling librefm plugin")
        self.enabled = false
    elseif message == "toggle" then
        log.info("Toggling librefm plugin to: " .. tostring(not self.enabled))
        self.enabled = not self.enabled
    end

    if not self.enabled then
        self.current_song = nil
        self.song_start = nil
        return
    end
end

return M
