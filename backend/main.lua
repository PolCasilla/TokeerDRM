-- TokeerDRM Millennium Plugin Backend (v3, Lua)
-- Handles HTTP calls to the code server and writes Steam tickets to the Windows registry.

local logger     = require("logger")
local millennium = require("millennium")
local http       = require("http")
local json       = require("json")
local ffi        = require("ffi")
local os         = require("os")

-- Server URL is read from backend\server.txt (gitignored — never in the public repo).
local function load_server_url()
    local cands = {}
    local ok, p = pcall(function() return millennium.steam_path end)
    if ok and type(p) == "string" and #p > 0 then
        cands[#cands + 1] = p .. "\\millennium\\plugins\\TokeerDRM\\backend\\server.txt"
    end
    local pf = os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
    cands[#cands + 1] = pf .. "\\Steam\\millennium\\plugins\\TokeerDRM\\backend\\server.txt"
    for _, path in ipairs(cands) do
        local f = io.open(path, "r")
        if f then
            local url = (f:read("*l") or ""):gsub("%s+$", "")
            f:close()
            if #url > 0 then return url end
        end
    end
    return "http://your-server:8091"
end

local SERVER_URL = load_server_url()
local PLUGIN_VERSION = "1.0.1"               -- bump on every release
local UPDATE_REPO    = "Tesla697/TokeerDRM"  -- latest release here force-gates the plugin

-- ── FFI: Windows Registry (advapi32) ─────────────────────────────────────────

ffi.cdef[[
typedef long           LONG;
typedef unsigned long  DWORD;
typedef void*          HKEY;
typedef const char*    LPCSTR;

LONG __stdcall RegCreateKeyExA(HKEY hKey, LPCSTR lpSubKey, DWORD Reserved,
                                LPCSTR lpClass, DWORD dwOptions, DWORD samDesired,
                                void* lpSecurityAttributes, HKEY* phkResult,
                                DWORD* lpdwDisposition);
LONG __stdcall RegSetValueExA (HKEY hKey, LPCSTR lpValueName, DWORD Reserved,
                                DWORD dwType, const unsigned char* lpData,
                                DWORD cbData);
LONG __stdcall RegOpenKeyExA  (HKEY hKey, LPCSTR lpSubKey, DWORD ulOptions,
                                DWORD samDesired, HKEY* phkResult);
LONG __stdcall RegQueryValueExA(HKEY hKey, LPCSTR lpValueName, DWORD* lpReserved,
                                DWORD* lpType, unsigned char* lpData,
                                DWORD* lpcbData);
LONG __stdcall RegCloseKey    (HKEY hKey);
]]

local advapi32 = ffi.load("advapi32")

-- HKEY_CURRENT_USER = (HKEY)(LONG_PTR)(LONG)0x80000001 = sign-extended to 64-bit
local HKCU              = ffi.cast("void*", -2147483647LL)
local REG_BINARY        = 3
local REG_OPTION_NON_VOLATILE = 0
local KEY_WRITE         = 0x20006   -- KEY_SET_VALUE | KEY_CREATE_SUB_KEY | STANDARD_RIGHTS_WRITE
local KEY_READ          = 0x20019   -- STANDARD_RIGHTS_READ | KEY_QUERY_VALUE | KEY_ENUMERATE_SUB_KEYS | KEY_NOTIFY

-- ── FFI: Clipboard (user32 + kernel32) ───────────────────────────────────────

ffi.cdef[[
typedef void* HANDLE;

int    __stdcall OpenClipboard   (void* hWndNewOwner);
int    __stdcall CloseClipboard  (void);
HANDLE __stdcall GetClipboardData(unsigned int uFormat);
void*  __stdcall GlobalLock      (HANDLE hMem);
int    __stdcall GlobalUnlock    (HANDLE hMem);
]]

local user32   = ffi.load("user32")
local kernel32 = ffi.load("kernel32")

local CF_UNICODETEXT = 13

-- ── FFI: ShellExecute (launch the OpenSteamTool installer, elevated) ─────────
ffi.cdef[[
void* __stdcall ShellExecuteA(void* hwnd, const char* op, const char* file,
                              const char* params, const char* dir, int nShow);
]]
local shell32 = ffi.load("shell32")

-- ── FFI: launch extract_tickets.exe and capture its stdout ───────────────────

ffi.cdef[[
typedef struct {
  unsigned long  cb;
  char*          lpReserved;
  char*          lpDesktop;
  char*          lpTitle;
  unsigned long  dwX;
  unsigned long  dwY;
  unsigned long  dwXSize;
  unsigned long  dwYSize;
  unsigned long  dwXCountChars;
  unsigned long  dwYCountChars;
  unsigned long  dwFillAttribute;
  unsigned long  dwFlags;
  unsigned short wShowWindow;
  unsigned short cbReserved2;
  unsigned char* lpReserved2;
  void*          hStdInput;
  void*          hStdOutput;
  void*          hStdError;
} TKR_STARTUPINFOA;
typedef struct { void* hProcess; void* hThread; unsigned long dwProcessId; unsigned long dwThreadId; } TKR_PROCESS_INFORMATION;
typedef struct { unsigned long nLength; void* lpSecurityDescriptor; int bInheritHandle; } TKR_SECURITY_ATTRIBUTES;

void*         CreateFileA(const char* name, unsigned long access, unsigned long share, TKR_SECURITY_ATTRIBUTES* sa, unsigned long disp, unsigned long flags, void* tmpl);
int           CreateProcessA(const char* app, char* cmd, void* pa, void* ta, int inherit, unsigned long flags, void* env, const char* dir, TKR_STARTUPINFOA* si, TKR_PROCESS_INFORMATION* pi);
unsigned long WaitForSingleObject(void* h, unsigned long ms);
int           ReadFile(void* h, void* buf, unsigned long n, unsigned long* nread, void* ov);
int           CloseHandle(void* h);
]]

local INVALID_HANDLE = ffi.cast("void*", -1)

-- ── FFI: Steam client attach (steamclient64.dll) ─────────────────────────────
-- Mint an encrypted app ticket from the *currently logged-in* Steam session by
-- attaching to the running client — same technique as Steam Achievement Manager.
-- No re-login, no game launch: ConnectToGlobalUser rides the live session.

ffi.cdef[[
void          Sleep(unsigned long dwMilliseconds);
int           SetEnvironmentVariableA(const char* lpName, const char* lpValue);

/* steamclient64.dll C export */
void* CreateInterface(const char* pName, int* pReturnCode);

/* Flat C++ interface method signatures (called via vtable index). On Win64
   there is a single calling convention, so `this` is just the first arg. */
typedef int                (*ISteamClient_CreateSteamPipe)(void* self);
typedef bool               (*ISteamClient_BReleaseSteamPipe)(void* self, int hSteamPipe);
typedef int                (*ISteamClient_ConnectToGlobalUser)(void* self, int hSteamPipe);
typedef void*              (*ISteamClient_GetISteamUser)(void* self, int hSteamUser, int hSteamPipe, const char* version);
typedef void*              (*ISteamClient_GetISteamApps)(void* self, int hSteamUser, int hSteamPipe, const char* version);
typedef int                (*ISteamUser_BLoggedOn)(void* self);
typedef unsigned long long (*ISteamUser_GetSteamID)(void* self);
typedef unsigned long long (*ISteamUser_RequestEncryptedAppTicket)(void* self, void* pData, int cbData);
typedef bool               (*ISteamUser_GetEncryptedAppTicket)(void* self, void* pTicket, int cbMax, unsigned int* pcb);
typedef bool               (*ISteamApps_BIsSubscribedApp)(void* self, unsigned int appID);
]]

-- Vtable indices (kept as named constants — these are the knobs to tweak if a
-- Steam update shifts the interface layout).
local VT = {
    -- ISteamClient
    CreateSteamPipe     = 0,
    BReleaseSteamPipe   = 1,
    ConnectToGlobalUser = 2,
    GetISteamUser       = 5,
    GetISteamApps       = 15,
    -- ISteamUser
    BLoggedOn               = 1,
    GetSteamID              = 2,
    RequestEncryptedAppTicket = 21,
    GetEncryptedAppTicket     = 22,
    -- ISteamApps
    BIsSubscribedApp        = 6,
}

-- Interface version strings to try (newest first).
local STEAMCLIENT_VERSIONS = { "SteamClient021", "SteamClient020", "SteamClient019", "SteamClient022" }
local STEAMUSER_VERSIONS   = { "SteamUser023", "SteamUser022", "SteamUser021", "SteamUser024" }
local STEAMAPPS_VERSIONS   = { "STEAMAPPS_INTERFACE_VERSION008", "STEAMAPPS_INTERFACE_VERSION007" }

local function steam_dll_path()
    -- Prefer Millennium's known Steam path, fall back to common install dirs.
    local candidates = {}
    local ok, p = pcall(function() return millennium.steam_path end)
    if ok and type(p) == "string" and #p > 0 then
        candidates[#candidates + 1] = p .. "\\steamclient64.dll"
    end
    local pf = os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
    candidates[#candidates + 1] = pf .. "\\Steam\\steamclient64.dll"
    candidates[#candidates + 1] = "C:\\Program Files (x86)\\Steam\\steamclient64.dll"
    return candidates
end

local _steamclient_lib = nil
local function load_steamclient()
    if _steamclient_lib then return _steamclient_lib end
    for _, path in ipairs(steam_dll_path()) do
        local ok, lib = pcall(ffi.load, path)
        if ok and lib then
            _steamclient_lib = lib
            logger:info("TokeerDRM: loaded steamclient64 from " .. path)
            return lib
        end
    end
    -- Last resort: rely on it already being in the process / search path.
    local ok, lib = pcall(ffi.load, "steamclient64")
    if ok then _steamclient_lib = lib end
    return _steamclient_lib
end

-- Resolve a vtable method as a callable of the given cdef function-pointer type.
local function vmethod(obj, index, fp_type)
    local vtbl = ffi.cast("void***", obj)[0]
    return ffi.cast(fp_type, vtbl[index])
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function trim(s)
    return (tostring(s or "")):match("^%s*(.-)%s*$")
end

local function hex_to_buf(hex_str)
    hex_str = trim(hex_str)
    local n = math.floor(#hex_str / 2)
    if n == 0 then return nil, 0 end
    local buf = ffi.new("unsigned char[?]", n)
    for i = 0, n - 1 do
        buf[i] = tonumber(hex_str:sub(i * 2 + 1, i * 2 + 2), 16) or 0
    end
    return buf, n
end

local HEX = "0123456789abcdef"
local function buf_to_hex(buf, n)
    local out = {}
    for i = 0, n - 1 do
        local b = buf[i]
        out[#out + 1] = HEX:sub(math.floor(b / 16) + 1, math.floor(b / 16) + 1)
        out[#out + 1] = HEX:sub((b % 16) + 1, (b % 16) + 1)
    end
    return table.concat(out)
end

-- Read a REG_BINARY value from a key under HKCU. Returns hex string or nil, err.
local function read_registry_binary(subkey, value_name)
    local hkey = ffi.new("void*[1]")
    if advapi32.RegOpenKeyExA(HKCU, subkey, 0, KEY_READ, hkey) ~= 0 then
        return nil, "key not found"
    end

    local size = ffi.new("DWORD[1]")
    -- First call: query required buffer size
    if advapi32.RegQueryValueExA(hkey[0], value_name, nil, nil, nil, size) ~= 0
       or size[0] == 0 then
        advapi32.RegCloseKey(hkey[0])
        return nil, "value not found"
    end

    local buf = ffi.new("unsigned char[?]", size[0])
    local r   = advapi32.RegQueryValueExA(hkey[0], value_name, nil, nil, buf, size)
    advapi32.RegCloseKey(hkey[0])
    if r ~= 0 then
        return nil, "read failed: " .. tostring(r)
    end

    return buf_to_hex(buf, size[0]), nil
end

-- Read the active user's SteamID64 from the registry.
-- HKCU\Software\Valve\Steam\ActiveProcess\ActiveUser holds the 32-bit account ID.
-- SteamID64 = 0x0110000100000000 + accountID.
local function read_active_steamid()
    local hkey = ffi.new("void*[1]")
    if advapi32.RegOpenKeyExA(HKCU, "Software\\Valve\\Steam\\ActiveProcess", 0, KEY_READ, hkey) ~= 0 then
        return nil
    end
    local data = ffi.new("DWORD[1]")
    local size = ffi.new("DWORD[1]", ffi.sizeof("DWORD"))
    local r = advapi32.RegQueryValueExA(hkey[0], "ActiveUser", nil, nil,
                                        ffi.cast("unsigned char*", data), size)
    advapi32.RegCloseKey(hkey[0])
    if r ~= 0 or data[0] == 0 then
        return nil
    end
    -- 76561197960265728 = 0x0110000100000000
    -- tostring() on a LuaJIT uint64 cdata appends "ULL" — strip it.
    local id = 76561197960265728ULL + data[0]
    return (tostring(id):gsub("ULL$", ""))
end

-- Write the AppTicket (ownership ticket) and ETicket (encrypted ticket) — they
-- are DIFFERENT blobs and must each go in their own registry value.
local function write_registry(app_id, appticket_hex, eticket_hex)
    local key_path = "Software\\Valve\\Steam\\Apps\\" .. app_id
    local hkey     = ffi.new("void*[1]")

    local ret = advapi32.RegCreateKeyExA(
        HKCU, key_path, 0, nil,
        REG_OPTION_NON_VOLATILE, KEY_WRITE, nil, hkey, nil
    )
    if ret ~= 0 then
        return false, "RegCreateKeyExA failed: " .. tostring(ret)
    end

    local function set_value(name, hex)
        local buf, n = hex_to_buf(hex)
        if not buf or n == 0 then return false, name .. " is empty" end
        local r = advapi32.RegSetValueExA(hkey[0], name, 0, REG_BINARY, buf, n)
        if r ~= 0 then return false, "RegSetValueExA(" .. name .. ") failed: " .. tostring(r) end
        return true
    end

    local ok1, e1 = set_value("AppTicket", appticket_hex)
    if not ok1 then advapi32.RegCloseKey(hkey[0]); return false, e1 end
    local ok2, e2 = set_value("ETicket", eticket_hex)
    if not ok2 then advapi32.RegCloseKey(hkey[0]); return false, e2 end

    advapi32.RegCloseKey(hkey[0])
    return true, nil
end

-- ── extract_tickets.exe runner ────────────────────────────────────────────────

local function file_exists(path)
    local h = kernel32.CreateFileA(path, 0x80000000, 1, nil, 3, 0x80, nil)  -- GENERIC_READ, OPEN_EXISTING
    if h == INVALID_HANDLE then return false end
    kernel32.CloseHandle(h)
    return true
end

local function find_extract_exe()
    local cands = {}
    local ok, p = pcall(function() return millennium.steam_path end)
    if ok and type(p) == "string" and #p > 0 then
        cands[#cands + 1] = p .. "\\millennium\\plugins\\TokeerDRM\\backend\\extract_tickets.exe"
    end
    local pf = os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
    cands[#cands + 1] = pf .. "\\Steam\\millennium\\plugins\\TokeerDRM\\backend\\extract_tickets.exe"
    cands[#cands + 1] = "C:\\Program Files (x86)\\Steam\\millennium\\plugins\\TokeerDRM\\backend\\extract_tickets.exe"
    for _, c in ipairs(cands) do
        if file_exists(c) then return c end
    end
    return nil
end

-- ── OpenSteamTool engine detection + installer ───────────────────────────────
-- A Denuvo-capable engine (official OpenSteamTool, or its mktl fork) must be
-- active or the registry ticket we write is ignored → Denuvo 88500000.
local function steam_dir()
    local ok, p = pcall(function() return millennium.steam_path end)
    if ok and type(p) == "string" and #p > 0 then return p end
    local pf = os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
    return pf .. "\\Steam"
end

local function engine_present()
    local dir = steam_dir()
    for _, core in ipairs({ "OpenSteamTool.dll", "mktl.dll" }) do
        if file_exists(dir .. "\\" .. core) then return true, core end
    end
    return false, nil
end

-- Official OpenSteamTool needs the toml to read config\stplug-in; the mktl fork
-- reads it natively. Returns whether the lua-library config is good for `core`.
local function config_ok(core)
    if core == "mktl.dll" then return true end
    local dir = steam_dir()
    local ok, f = pcall(io.open, dir .. "\\opensteamtool.toml", "r")
    if not ok or not f then return false end
    local content = f:read("*a") or ""
    f:close()
    return content:find("stplug-in", 1, true) ~= nil
end

local function find_install_script()
    local cands = {}
    local ok, p = pcall(function() return millennium.steam_path end)
    if ok and type(p) == "string" and #p > 0 then
        cands[#cands + 1] = p .. "\\millennium\\plugins\\TokeerDRM\\backend\\install_ost.ps1"
    end
    local pf = os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
    cands[#cands + 1] = pf .. "\\Steam\\millennium\\plugins\\TokeerDRM\\backend\\install_ost.ps1"
    for _, c in ipairs(cands) do
        if file_exists(c) then return c end
    end
    return nil
end

-- ── OST version tracking + auto-heal classification ──────────────────────────
-- Steam updates can wipe the OST hijack DLLs → redeemed tickets are ignored
-- (Denuvo 88500000). We tag each install (shared marker the TokeerDRM app also
-- writes) so we can tell a clobbered install (repair, auto-fix) from a never-set-up
-- one (install, manual) and from an outdated build (update, auto-fix).
local OST_REPO       = "OpenSteam001/OpenSteamTool"
local OST_MARKER     = ".tokeer_ost_version"
local _ost_latest    = { tag = nil, at = 0 }
local _engine_healed = false  -- fire the elevated repair/update at most once per load

local function hijack_present()
    local dir = steam_dir()
    return file_exists(dir .. "\\dwmapi.dll") and file_exists(dir .. "\\xinput1_4.dll")
end

local function read_ost_marker()
    local f = io.open(steam_dir() .. "\\" .. OST_MARKER, "r")
    if not f then return nil end
    local t = trim(f:read("*l") or ""); f:close()
    if #t == 0 then return nil end
    return t
end

local function latest_ost_tag()
    local now = os.time()
    if _ost_latest.tag and (now - _ost_latest.at) < 21600 then return _ost_latest.tag end  -- cache 6h
    local ok, resp = pcall(http.request, "https://api.github.com/repos/" .. OST_REPO .. "/releases/latest", {
        method = "GET", headers = { ["User-Agent"] = "TokeerDRM", ["Accept"] = "application/vnd.github+json" }, timeout = 8,
    })
    if ok and resp and resp.status == 200 then
        local pok, parsed = pcall(json.decode, resp.body or "")
        if pok and type(parsed) == "table" and parsed.tag_name then
            _ost_latest.tag = tostring(parsed.tag_name); _ost_latest.at = now
            return _ost_latest.tag
        end
    end
    return nil
end

-- "install" (first-time → manual) | "repair" (we set it up, now broken → auto) |
-- "update" (newer OST release → auto) | "none"
local function ost_action()
    local has_core, core = engine_present()
    local ready  = has_core and hijack_present() and config_ok(core)
    local marker = read_ost_marker()
    if not ready then return (marker and "repair" or "install") end
    local latest = latest_ost_tag()
    if latest and marker and latest ~= marker then return "update" end
    return "none"
end

-- Launch install_ost.ps1 elevated; -Force re-downloads the engine (used for updates).
local function launch_install(force)
    local script = find_install_script()
    if not script then return false, "OpenSteamTool installer not found in the plugin folder" end
    local params = '-NoProfile -ExecutionPolicy Bypass -File "' .. script .. '"'
    if force then params = params .. " -Force" end
    shell32.ShellExecuteA(nil, "runas", "powershell.exe", params, nil, 1)  -- SW_SHOWNORMAL
    return true, nil
end

-- Run extract_tickets.exe --pipe <appid> as a fresh process, capturing its
-- stdout ("<appid>|<AppTicket>|<ETicket>|<SteamID>"). Returns
-- appticket, eticket, steam_id (or nil + error).
local function run_extract_tickets(app_id)
    local exe = find_extract_exe()
    if not exe then return nil, nil, nil, "extract_tickets.exe not found in plugin folder" end
    local dir = exe:match("^(.*)[\\/]") or "."
    local out_path = dir .. "\\_tickets_" .. app_id .. ".out"

    local sa = ffi.new("TKR_SECURITY_ATTRIBUTES")
    sa.nLength = ffi.sizeof("TKR_SECURITY_ATTRIBUTES")
    sa.lpSecurityDescriptor = nil
    sa.bInheritHandle = 1

    -- stdout → temp file (inheritable); stdin/stderr → NUL (no prompt hang, no log noise)
    local h_out = kernel32.CreateFileA(out_path, 0x40000000, 1, sa, 2, 0x80, nil)        -- GENERIC_WRITE, CREATE_ALWAYS
    if h_out == INVALID_HANDLE then return nil, nil, nil, "cannot create temp output file" end
    local h_nul = kernel32.CreateFileA("NUL", 0xC0000000, 3, sa, 3, 0, nil)              -- RW, OPEN_EXISTING

    local si = ffi.new("TKR_STARTUPINFOA")
    si.cb        = ffi.sizeof("TKR_STARTUPINFOA")
    si.dwFlags   = 0x100                                                                 -- STARTF_USESTDHANDLES
    si.hStdInput = h_nul
    si.hStdOutput = h_out
    si.hStdError = h_nul

    local pi      = ffi.new("TKR_PROCESS_INFORMATION")
    local cmdstr  = '"' .. exe .. '" --pipe ' .. app_id
    local cmdbuf  = ffi.new("char[?]", #cmdstr + 1)
    ffi.copy(cmdbuf, cmdstr)

    local started = kernel32.CreateProcessA(nil, cmdbuf, nil, nil, 1, 0x08000000, nil, dir, si, pi)  -- CREATE_NO_WINDOW
    if started == 0 then
        kernel32.CloseHandle(h_out)
        if h_nul ~= INVALID_HANDLE then kernel32.CloseHandle(h_nul) end
        return nil, nil, nil, "could not start extract_tickets.exe"
    end
    kernel32.WaitForSingleObject(pi.hProcess, 30000)
    kernel32.CloseHandle(pi.hProcess)
    kernel32.CloseHandle(pi.hThread)
    kernel32.CloseHandle(h_out)
    if h_nul ~= INVALID_HANDLE then kernel32.CloseHandle(h_nul) end

    -- read the captured stdout
    local hr = kernel32.CreateFileA(out_path, 0x80000000, 1, nil, 3, 0x80, nil)          -- GENERIC_READ, OPEN_EXISTING
    if hr == INVALID_HANDLE then return nil, nil, nil, "no output from extract_tickets" end
    local buf   = ffi.new("unsigned char[?]", 131072)
    local nread = ffi.new("unsigned long[1]")
    kernel32.ReadFile(hr, buf, 131071, nread, nil)
    kernel32.CloseHandle(hr)
    local out = trim(ffi.string(buf, nread[0]))

    -- parse the pipe line: appid|appticket|eticket|steamid
    local line = out:match("[^\r\n]*|[^\r\n]*|[^\r\n]*|[^\r\n]*$") or out
    local parts = {}
    for seg in (line .. "|"):gmatch("([^|]*)|") do parts[#parts + 1] = seg end
    if #parts < 4 then
        return nil, nil, nil, "this Steam account doesn't own app " .. app_id
    end
    local appticket = trim(parts[2])
    local eticket   = trim(parts[3])
    local steamid   = trim(parts[4])
    if appticket == "" or eticket == "" then
        return nil, nil, nil, "this Steam account doesn't own app " .. app_id
    end
    return appticket, eticket, steamid, nil
end

local function http_post(path, body_table)
    local body_str = json.encode(body_table)
    -- Use http.request with explicit method — http.post takes the body as a
    -- positional string, not a table, so the table form silently sent no body.
    local resp, err = http.request(SERVER_URL .. path, {
        method  = "POST",
        data    = body_str,
        headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json" },
        timeout = 10,
    })
    if not resp then
        return nil, tostring(err or "Network error")
    end
    if resp.status ~= 200 then
        local ok, parsed = pcall(json.decode, resp.body or "")
        local reason = (ok and type(parsed) == "table" and (parsed.reason or parsed.error))
                       or ("HTTP " .. tostring(resp.status))
        return nil, reason
    end
    local ok, parsed = pcall(json.decode, resp.body or "")
    if not ok then return nil, "JSON parse error" end
    return parsed, nil
end

local function read_clipboard_utf16(wptr)
    local chars = {}
    local i     = 0
    while wptr[i] ~= 0 do
        local c = wptr[i]
        if c < 0x80 then
            chars[#chars + 1] = string.char(c)
        elseif c < 0x800 then
            chars[#chars + 1] = string.char(
                0xC0 + math.floor(c / 64),
                0x80 + (c % 64)
            )
        else
            chars[#chars + 1] = string.char(
                0xE0 + math.floor(c / 4096),
                0x80 + math.floor((c % 4096) / 64),
                0x80 + (c % 64)
            )
        end
        i = i + 1
    end
    return table.concat(chars)
end

-- ── Callable functions ────────────────────────────────────────────────────────
-- NOTE: arg order must match alphabetical key order from the JS-side object.
-- JS sends {app_id, code} → nlohmann iterates: app_id first, code second.
-- So Lua signature is: RedeemCode(app_id, code)

-- Numeric dotted-version compare: true if a > b.
local function version_gt(a, b)
    local function parts(v)
        local t = {}
        for n in tostring(v or "0"):gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

-- Compare this build to the latest GitHub release; update_required force-gates UI.
function VersionInfo()
    local info = {
        current = PLUGIN_VERSION, latest = PLUGIN_VERSION, update_required = false,
        url = "https://github.com/" .. UPDATE_REPO .. "/releases/latest",
    }
    local ok, resp = pcall(http.request, "https://api.github.com/repos/" .. UPDATE_REPO .. "/releases/latest", {
        method  = "GET",
        headers = { ["User-Agent"] = "TokeerDRM", ["Accept"] = "application/vnd.github+json" },
        timeout = 8,
    })
    if ok and resp and resp.status == 200 then
        local pok, parsed = pcall(json.decode, resp.body or "")
        if pok and type(parsed) == "table" and parsed.tag_name then
            local tag = tostring(parsed.tag_name):gsub("^[vV]", "")
            info.latest = tag
            info.update_required = version_gt(tag, PLUGIN_VERSION)
            if parsed.html_url then info.url = parsed.html_url end
        end
    end
    return json.encode(info)
end

-- Open a URL in the system browser (for the "Download latest" button).
function OpenUrl(url)
    if type(url) == "string" and #url > 0 then
        shell32.ShellExecuteA(nil, "open", url, nil, nil, 1)
    end
    return json.encode({ success = true })
end

-- Is a Denuvo-capable engine (OpenSteamTool / mktl) active AND configured?
-- Auto-heals once per load: if OST was set up here before but a Steam update
-- clobbered it ('repair'), or a newer OST release exists ('update'), the elevated
-- installer is launched automatically. First-time setup ('install') stays manual
-- (the Set-it-up button) so a brand-new user isn't surprised by a UAC prompt.
function EngineStatus()
    local action = ost_action()
    if (action == "repair" or action == "update") and not _engine_healed then
        _engine_healed = true
        logger:info("TokeerDRM: auto-" .. action .. " OpenSteamTool")
        launch_install(action == "update")
    end
    local ok, core = engine_present()
    local ready = ok and hijack_present() and config_ok(core)
    return json.encode({ installed = ok, ready = ready, engine = core or nil, action = action })
end

-- Launch the OpenSteamTool installer (elevated). Steam restarts afterward,
-- which reloads this plugin with the engine active.
function InstallEngine()
    local ok, err = launch_install(false)
    if not ok then
        return json.encode({ success = false, error = err })
    end
    logger:info("TokeerDRM: launched OpenSteamTool installer")
    return json.encode({
        success = true,
        message = "OpenSteamTool setup launched — approve the prompt. Steam will restart, then redeem.",
    })
end

function RedeemCode(app_id, code)
    app_id = trim(app_id)
    code   = trim(code):upper()

    if #code ~= 6 then
        return json.encode({ success = false, error = "Code must be 6 characters" })
    end
    if app_id == "" then
        return json.encode({ success = false, error = "Missing app_id" })
    end

    -- Note: the engine (OpenSteamTool) is checked once when the panel opens,
    -- not on every redeem.

    local result, err = http_post("/drm/redeem", { code = code, app_id = app_id })
    if not result then
        return json.encode({ success = false, error = err or "Server error" })
    end

    local appticket = trim(result.appticket or "")
    local eticket   = trim(result.eticket or "")
    if appticket == "" or eticket == "" then
        return json.encode({ success = false, error = "Server returned an incomplete ticket" })
    end

    local ok, write_err = write_registry(app_id, appticket, eticket)
    if not ok then
        logger:error("TokeerDRM registry write failed: " .. tostring(write_err))
        return json.encode({ success = false, error = "Registry write failed: " .. tostring(write_err) })
    end

    logger:info("TokeerDRM: redeemed " .. code .. " for app " .. app_id)
    return json.encode({
        success        = true,
        message        = "Ticket applied. Launch the game from Steam within 30 min.",
        uses_remaining = result.uses_remaining,
    })
end

-- Extract the AppTicket (ownership) + ETicket (encrypted) for a game the
-- signed-in account owns, by running extract_tickets.exe (a fresh process —
-- no play status, no game launch). Returns both tickets + the SteamID.
function MintTicket(app_id)
    app_id = trim(app_id)
    if app_id == "" then
        return json.encode({ success = false, error = "Missing app_id" })
    end

    local appticket, eticket, steamid, err = run_extract_tickets(app_id)
    if not appticket then
        logger:warn("TokeerDRM MintTicket: " .. tostring(err))
        return json.encode({ success = false, error = err or "Failed to extract ticket" })
    end

    logger:info(string.format(
        "TokeerDRM: extracted tickets for app %s (AppTicket %d / ETicket %d hex, SteamID %s)",
        app_id, #appticket, #eticket, steamid
    ))
    return json.encode({
        success   = true,
        appticket = appticket,
        eticket   = eticket,
        steam_id  = steamid,
    })
end

-- JS sends {app_id, appticket, eticket, max_uses, steam_id} → alphabetical:
-- app_id, appticket, eticket, max_uses, steam_id

function GenerateCode(app_id, appticket, eticket, max_uses, steam_id)
    app_id    = trim(app_id)
    appticket = trim(appticket)
    eticket   = trim(eticket)
    max_uses  = tonumber(max_uses) or 5
    steam_id  = trim(steam_id)

    if steam_id == "" then steam_id = "0" end
    if app_id    == "" then return json.encode({ success = false, error = "Missing app_id" }) end
    if appticket == "" or eticket == "" then
        return json.encode({ success = false, error = "Missing ticket" })
    end

    local result, err = http_post("/drm/generate", {
        appticket = appticket,
        eticket   = eticket,
        steam_id  = steam_id,
        app_id    = app_id,
        max_uses  = max_uses,
    })
    if not result then
        return json.encode({ success = false, error = err or "Server error" })
    end

    logger:info("TokeerDRM: generated code " .. tostring(result.code or "?") .. " for app " .. app_id)
    return json.encode({
        success    = true,
        code       = result.code,
        max_uses   = result.max_uses or max_uses,
        expires_in = result.expires_in or 86400,
    })
end

function GetClipboard()
    if user32.OpenClipboard(nil) == 0 then
        return json.encode({ success = false, error = "Cannot open clipboard" })
    end

    local handle = user32.GetClipboardData(CF_UNICODETEXT)
    if handle == nil then
        user32.CloseClipboard()
        return json.encode({ success = true, text = "" })
    end

    local ptr  = kernel32.GlobalLock(handle)
    local text = ""
    if ptr ~= nil then
        text = trim(read_clipboard_utf16(ffi.cast("uint16_t*", ptr)))
        kernel32.GlobalUnlock(handle)
    end

    user32.CloseClipboard()
    return json.encode({ success = true, text = text })
end

function GetStatus()
    local resp, _ = http.get(SERVER_URL .. "/health", { timeout = 5 })
    if not resp then
        return json.encode({ success = false, server = SERVER_URL, status = "unreachable" })
    end
    local ok, parsed = pcall(json.decode, resp.body or "")
    return json.encode({
        success = ok and type(parsed) == "table" and parsed.success or false,
        server  = SERVER_URL,
        status  = ok and type(parsed) == "table" and parsed.status or "ok",
    })
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

local function on_load()
    logger:info("TokeerDRM backend loaded")
    millennium.ready()
end

local function on_frontend_loaded()
    logger:info("TokeerDRM frontend loaded")
end

local function on_unload()
    logger:info("TokeerDRM backend unloaded")
end

return {
    on_load            = on_load,
    on_frontend_loaded = on_frontend_loaded,
    on_unload          = on_unload,
    RedeemCode         = RedeemCode,
    GenerateCode       = GenerateCode,
    MintTicket         = MintTicket,
    GetClipboard       = GetClipboard,
    GetStatus          = GetStatus,
    EngineStatus       = EngineStatus,
    InstallEngine      = InstallEngine,
    VersionInfo        = VersionInfo,
    OpenUrl            = OpenUrl,
}
